import socket
import ssl
import subprocess
import sys


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
            while len(response) < 18:
                chunk = client.recv(18 - len(response))
                if not chunk:
                    break
                response.extend(chunk)
            if len(response) != 18:
                raise RuntimeError(
                    f"incomplete HTTP/2 bootstrap response: {bytes(response)!r}"
                )
            if response[3] != 4 or response[12] != 4 or response[13] != 1:
                raise RuntimeError(
                    f"unexpected HTTP/2 bootstrap frames: {bytes(response)!r}"
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
