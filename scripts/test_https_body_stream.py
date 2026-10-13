"""Bounded HTTPS request streaming against our own loopback fixture."""

import argparse
import contextlib
import selectors
import socket
import ssl
import subprocess
import time

SIZE = 1024 * 1024
CHUNK = b"a" * 4096


@contextlib.contextmanager
def connect(context, port):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as client:
            client.settimeout(10)
            assert client.selected_alpn_protocol() == "http/1.1"
            yield client


def read_head(client):
    wire = bytearray()
    while b"\r\n\r\n" not in wire:
        chunk = client.recv(4096)
        assert chunk, wire
        wire.extend(chunk)
    return bytes(wire).split(b"\r\n\r\n", 1)


def response(client):
    head, body = read_head(client)
    assert head.startswith(b"HTTP/1.1 200 OK\r\n"), head
    length = next(int(line.split(b":", 1)[1]) for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:"))
    while len(body) < length:
        chunk = client.recv(length - len(body))
        assert chunk, body
        body += chunk
    assert len(body) == length, body
    return body


def control(context, port, path):
    with connect(context, port) as client:
        client.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
        return response(client)


def upload(context, port, number, chunked=False, expect=False, extension=False):
    with connect(context, port) as client:
        framing = "Transfer-Encoding: chunked\r\nTrailer: X-Finish\r\n" if chunked else f"Content-Length: {SIZE}\r\n"
        expectation = "Expect: 100-continue\r\n" if expect else ""
        client.sendall(("POST /upload HTTP/1.1\r\nHost: localhost\r\n" + framing + expectation + "\r\n").encode())
        if expect:
            head, tail = read_head(client)
            assert head == b"HTTP/1.1 100 Continue" and not tail, (head, tail)
        assert control(context, port, "/calls") == str(number).encode()
        if extension:
            client.sendall(b"1000;name=" + b"x" * 8192 + b"\r\n" + CHUNK + b"\r\n")
            deadline = time.monotonic() + 3
            while control(context, port, "/bytes") != b"4096":
                assert time.monotonic() < deadline, "TLS extension framing stranded decrypted payload"
                time.sleep(0.01)
        for _ in range(SIZE // len(CHUNK) - int(extension)):
            client.sendall(b"1000\r\n" + CHUNK + b"\r\n" if chunked else CHUNK)
        if chunked:
            client.sendall(b"0\r\nX-Finish: complete\r\n\r\n")
        assert response(client) == (b"1048576:complete" if chunked else b"1048576:none")


def main(command=None):
    if command is None:
        command = ("mojo", "run", "--Werror", "-I", ".", "tests/https_body_stream_fixture.mojo")
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(90), "HTTPS fixture readiness timed out"
        ready = process.stdout.readline().strip()
        assert ready.startswith("READY "), ready
        port = int(ready.split()[1])
        context = ssl.create_default_context(cafile="build/tls/test-cert.pem")
        context.check_hostname = False
        context.set_alpn_protocols(["http/1.1"])
        upload(context, port, 1)
        upload(context, port, 2, chunked=True)
        upload(context, port, 3, expect=True)
        upload(context, port, 4, chunked=True, extension=True)
        with connect(context, port) as client:
            client.sendall(b"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\naa")
            assert control(context, port, "/calls") == b"5"
        deadline = time.monotonic() + 10
        while control(context, port, "/cancelled") != b"1":
            assert time.monotonic() < deadline, "partial HTTPS body was not cancelled"
            time.sleep(0.01)
        assert control(context, port, "/shutdown") == b"shutdown"
        out, error = process.communicate(timeout=10)
        assert process.returncode == 0 and out.strip() == "DONE", (out, error)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    print("HTTPS bounded body streaming: fixed/chunked 1MiB, trailers, early dispatch, Expect100 and cancellation passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture")
    args = parser.parse_args()
    main((args.fixture,) if args.fixture else None)
