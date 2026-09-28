import socket
import ssl
import subprocess
import sys


def read_h2_frame(client):
    header = bytearray()
    while len(header) < 9:
        chunk = client.recv(9 - len(header))
        if not chunk:
            raise RuntimeError("connection closed before HTTP/2 response")
        header.extend(chunk)
    length = int.from_bytes(header[:3], "big")
    payload = bytearray()
    while len(payload) < length:
        chunk = client.recv(length - len(payload))
        if not chunk:
            raise RuntimeError("incomplete HTTP/2 response frame")
        payload.extend(chunk)
    return (
        header[3],
        header[4],
        int.from_bytes(header[5:9], "big"),
        bytes(payload),
    )


process = subprocess.Popen(
    ["mojo", "run", "--Werror", "-I", ".", "tests/https_server_fixture.mojo"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

try:
    ready = process.stdout.readline().strip()
    if not ready.startswith("READY "):
        raise RuntimeError(f"HTTPS fixture did not start: {ready}")
    port = int(ready.split()[1])

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])

    http2_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    http2_context.check_hostname = False
    http2_context.verify_mode = ssl.CERT_NONE
    http2_context.set_alpn_protocols(["h2"])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with http2_context.wrap_socket(raw, server_hostname="localhost") as client:
            if client.selected_alpn_protocol() != "h2":
                raise RuntimeError("server did not negotiate HTTP/2")
            client.sendall(
                b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
            )
            response = bytearray()
            while len(response) < 24:
                chunk = client.recv(24 - len(response))
                if not chunk:
                    break
                response.extend(chunk)
            if len(response) != 24:
                raise RuntimeError(
                    f"incomplete HTTP/2 bootstrap response: {bytes(response)!r}"
                )
            if (
                response[3] != 4
                or response[10] != 3
                or response[14] != 100
                or response[18] != 4
                or response[19] != 1
            ):
                raise RuntimeError(
                    f"unexpected HTTP/2 bootstrap frames: {bytes(response)!r}"
                )

            compressed_headers = b"\x82\x86\x84\x41\x0fwww.example.com"
            headers_frame = (
                len(compressed_headers).to_bytes(3, "big")
                + b"\x01\x04\x00\x00\x00\x01"
                + compressed_headers
            )
            request_body = b"from h2"
            data_frame = (
                len(request_body).to_bytes(3, "big")
                + b"\x00\x01\x00\x00\x00\x01"
                + request_body
            )
            second_headers_frame = (
                len(compressed_headers).to_bytes(3, "big")
                + b"\x01\x05\x00\x00\x00\x03"
                + compressed_headers
            )
            client.sendall(headers_frame + data_frame + second_headers_frame)

            connection_credit = read_h2_frame(client)
            stream_credit = read_h2_frame(client)
            if (
                connection_credit[0] != 8
                or connection_credit[2] != 0
                or connection_credit[3][-1] != len(request_body)
                or stream_credit[0] != 8
                or stream_credit[2] != 1
                or stream_credit[3][-1] != len(request_body)
            ):
                raise RuntimeError(
                    "unexpected HTTP/2 receive credit: "
                    f"{connection_credit!r}, {stream_credit!r}"
                )

            response_bodies = {}
            for _ in range(4):
                frame = read_h2_frame(client)
                if frame[0] == 1:
                    if frame[3][0] != 0x88:
                        raise RuntimeError(
                            f"unexpected HTTP/2 headers: {frame!r}"
                        )
                    response_bodies[frame[2]] = bytearray()
                elif frame[0] == 0 and frame[2] in response_bodies:
                    response_bodies[frame[2]].extend(frame[3])
            if response_bodies != {
                1: b"hello over httpsfrom h2",
                3: b"hello over https",
            }:
                raise RuntimeError(
                    f"unexpected multiplexed HTTP/2 bodies: {response_bodies!r}"
                )

    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with http2_context.wrap_socket(raw, server_hostname="localhost") as client:
            client.sendall(
                b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                b"\x00\x00\x06\x04\x00\x00\x00\x00\x00"
                b"\x00\x04\x00\x00\x00\x00"
            )
            bootstrap = bytearray()
            while len(bootstrap) < 24:
                chunk = client.recv(24 - len(bootstrap))
                if not chunk:
                    break
                bootstrap.extend(chunk)
            if len(bootstrap) != 24:
                raise RuntimeError("incomplete HTTP/2 SETTINGS response")
            compressed_headers = b"\x82\x86\x84\x41\x0fwww.example.com"
            client.sendall(
                len(compressed_headers).to_bytes(3, "big")
                + b"\x01\x05\x00\x00\x00\x01"
                + compressed_headers
            )
            limited_headers = read_h2_frame(client)
            if (
                limited_headers[0] != 1
                or limited_headers[2] != 1
                or (limited_headers[1] & 1) != 0
                or limited_headers[3][0] != 0x88
            ):
                raise RuntimeError(
                    f"server exceeded a zero HTTP/2 send window: {limited_headers!r}"
                )
            stream_increment = b"\x00\x00\x00\x20"
            client.sendall(
                b"\x00\x00\x04\x08\x00\x00\x00\x00\x01"
                + stream_increment
            )
            response_data = read_h2_frame(client)
            if (
                response_data[0] != 0
                or response_data[1] & 1 == 0
                or response_data[2] != 1
                or response_data[3] != b"hello over https"
            ):
                raise RuntimeError(
                    f"server did not resume HTTP/2 body after credit: {response_data!r}"
                )

    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as client:
            if client.selected_alpn_protocol() != "http/1.1":
                raise RuntimeError("server did not negotiate HTTP/1.1")
            client.sendall(
                b"GET /hello HTTP/1.1\r\nHost: localhost\r\n"
                b"Connection: close\r\n\r\n"
            )
            response = bytearray()
            while chunk := client.recv(4096):
                response.extend(chunk)

    wire = bytes(response)
    if not wire.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected HTTPS response: {wire!r}")
    if not wire.endswith(b"hello over https"):
        raise RuntimeError(f"unexpected HTTPS response body: {wire!r}")
    if process.wait(timeout=5) != 0:
        raise RuntimeError(process.stderr.read())
    print("HTTP/2 bootstrap and HTTPS roundtrips succeeded")
except Exception:
    process.kill()
    process.wait()
    sys.stderr.write(process.stderr.read())
    raise
