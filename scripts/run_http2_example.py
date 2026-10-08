import os
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


def _wait_ready(process):
    ready = process.stdout.readline().strip()
    if not ready.startswith("READY "):
        raise RuntimeError(
            f"http2_hello example did not start: {ready}\n"
            f"{process.stderr.read()}"
        )
    return int(ready.split()[1])


def _run_request(port):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2"])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as client:
            client.settimeout(5)
            if client.selected_alpn_protocol() != "h2":
                raise RuntimeError("http2_hello did not negotiate h2")
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
            compressed = b"\x82\x86\x84\x41\x0fwww.example.com"
            client.sendall(
                len(compressed).to_bytes(3, "big")
                + b"\x01\x05\x00\x00\x00\x01"
                + compressed
            )
            body = bytearray()
            saw_headers = False
            for _ in range(16):
                frame_type, flags, sid, payload = _read_h2_frame(client)
                if sid != 1:
                    continue
                if frame_type == 1:
                    if not _hpack_starts_with_status_200(payload):
                        raise RuntimeError(
                            f"unexpected http2_hello headers: {payload!r}"
                        )
                    saw_headers = True
                elif frame_type == 0:
                    body.extend(payload)
                    if flags & 1:
                        break
            if not saw_headers or bytes(body) != b"hello over http/2":
                raise RuntimeError(
                    f"unexpected http2_hello body: {bytes(body)!r}"
                )


def main():
    env = dict(os.environ)
    env["HELLO_ADDRESS"] = "127.0.0.1:0"
    process = subprocess.Popen(
        ["mojo", "run", "--Werror", "-I", ".", "examples/http2_hello.mojo"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        port = _wait_ready(process)
        _run_request(port)
        print("http2_hello example roundtrip succeeded")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process.returncode not in (0, -15, 143):
            sys.stderr.write(process.stderr.read())
            raise RuntimeError(
                f"http2_hello exited with {process.returncode}"
            )


main()
