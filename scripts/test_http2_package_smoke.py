import socket
import ssl
import subprocess
import sys


def _read_h2_frame(client):
    header = bytearray()
    while len(header) < 9:
        chunk = client.recv(9 - len(header))
        if not chunk:
            raise RuntimeError("connection closed before HTTP/2 frame header")
        header.extend(chunk)
    length = int.from_bytes(header[:3], "big")
    payload = bytearray()
    while len(payload) < length:
        chunk = client.recv(length - len(payload))
        if not chunk:
            raise RuntimeError("connection closed before HTTP/2 frame payload")
        payload.extend(chunk)
    return (
        header[3],
        header[4],
        int.from_bytes(header[5:9], "big"),
        bytes(payload),
    )


def _hpack_starts_with_status_200(payload):
    i = 0
    while i < len(payload) and (payload[i] & 0xE0) == 0x20:
        prefix = payload[i] & 0x1F
        i += 1
        if prefix == 0x1F:
            while i < len(payload) and (payload[i] & 0x80) != 0:
                i += 1
            if i < len(payload):
                i += 1
    return i < len(payload) and payload[i] == 0x88


def _bootstrap(client):
    client.sendall(
        b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
    )
    bootstrap = bytearray()
    while len(bootstrap) < 24:
        chunk = client.recv(24 - len(bootstrap))
        if not chunk:
            raise RuntimeError("incomplete HTTP/2 bootstrap")
        bootstrap.extend(chunk)


def _request(client, stream_id):
    compressed = b"\x82\x86\x84\x41\x0fwww.example.com"
    client.sendall(
        len(compressed).to_bytes(3, "big")
        + bytes([0x01, 0x05])
        + stream_id.to_bytes(4, "big")
        + compressed
    )


def _collect_response(client, stream_id):
    body = bytearray()
    saw_headers = False
    for _ in range(16):
        frame_type, flags, sid, payload = _read_h2_frame(client)
        if sid != stream_id:
            continue
        if frame_type == 1:
            if not _hpack_starts_with_status_200(payload):
                raise RuntimeError(f"unexpected HTTP/2 headers: {payload!r}")
            saw_headers = True
        elif frame_type == 0:
            body.extend(payload)
            if flags & 1:
                if not saw_headers:
                    raise RuntimeError("DATA before HEADERS")
                return bytes(body)
    raise RuntimeError("timed out waiting for HTTP/2 response body")


def _run_client(port):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2"])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as client:
            client.settimeout(5)
            if client.selected_alpn_protocol() != "h2":
                raise RuntimeError("server did not negotiate HTTP/2")
            _bootstrap(client)
            _request(client, 1)
            body = _collect_response(client, 1)
            if body != b"packaged http/2 ok":
                raise RuntimeError(
                    f"unexpected packaged HTTP/2 body: {body!r}"
                )


def main():
    process = subprocess.Popen(
        [
            "mojo",
            "run",
            "--Werror",
            "-I",
            "build",
            "tests/http2_package_smoke.mojo",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(
                f"packaged HTTP/2 fixture did not start: {ready}\n"
                f"{process.stderr.read()}"
            )
        port = int(ready.split()[1])
        _run_client(port)
        if process.wait(timeout=10) != 0:
            raise RuntimeError(process.stderr.read())
        print("packaged HTTP/2 provider roundtrip succeeded")
    except Exception:
        process.kill()
        process.wait()
        sys.stderr.write(process.stderr.read())
        raise


main()
