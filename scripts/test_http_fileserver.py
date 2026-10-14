#!/usr/bin/env python3
"""Validate static files over selected protocols and measure bounded native RSS."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
from pathlib import Path
import platform
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field


@dataclass
class Response:
    status: int = 0
    headers: list[tuple[str, str]] = field(default_factory=list)
    body: bytearray = field(default_factory=bytearray)
    count: int = 0
    digest: object = field(default_factory=hashlib.sha256)

    def add(self, data: bytes) -> None:
        self.count += len(data)
        self.digest.update(data)
        if len(self.body) + len(data) <= 262144:
            self.body.extend(data)

    def values(self, name: str) -> list[str]:
        return [value for key, value in self.headers if key.lower() == name.lower()]


class H1Client:
    def __init__(self, port: int, tls: bool):
        self.port = port
        self.tls = tls

    def _open(self):
        raw = socket.create_connection(("127.0.0.1", self.port), timeout=120)
        if self.tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            context.set_alpn_protocols(["http/1.1"])
            raw = context.wrap_socket(raw, server_hostname="localhost")
            assert raw.selected_alpn_protocol() == "http/1.1"
        return raw

    def request(self, method: str, path: str, headers=(), started=None) -> Response:
        with self._open() as raw:
            fields = "".join(f"{key}: {value}\r\n" for key, value in headers)
            raw.sendall(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{fields}\r\n".encode())
            pending = bytearray()
            while b"\r\n\r\n" not in pending:
                block = raw.recv(65536)
                assert block, "HTTP/1 closed before headers"
                pending.extend(block)
            header, body = bytes(pending).split(b"\r\n\r\n", 1)
            lines = header.decode().split("\r\n")
            response = Response(status=int(lines[0].split()[1]))
            response.headers = [tuple(line.split(": ", 1)) for line in lines[1:]]
            if started is not None:
                started.set()
            assert not response.values("transfer-encoding")
            length = 0 if method == "HEAD" or response.status == 304 else int(response.values("content-length")[0])
            assert len(body) <= length
            response.add(body)
            while response.count < length:
                block = raw.recv(min(65536, length - response.count))
                assert block, "HTTP/1 closed before Content-Length"
                response.add(block)
            assert not raw.recv(1), "HTTP/1 excess body after Content-Length"
            return response


    def slow_cancel(self):
        with self._open() as raw:
            raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            raw.sendall(b"GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n")
            pending = bytearray()
            while b"\r\n\r\n" not in pending:
                block = raw.recv(1024)
                assert block, "HTTP/1 closed before headers"
                pending.extend(block)
            time.sleep(0.1)
            sibling = self.request("GET", "/alive")
            assert sibling.status == 200 and bytes(sibling.body) == b"ok"
        assert self.request("GET", "/alive").status == 200



class H2Client:
    def __init__(self, port: int):
        self.port = port

    def request(self, method: str, path: str, headers=(), started=None) -> Response:
        from h2.config import H2Configuration
        from h2.connection import H2Connection
        from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["h2"])
        with context.wrap_socket(socket.create_connection(("127.0.0.1", self.port), timeout=120), server_hostname="localhost") as sock:
            assert sock.selected_alpn_protocol() == "h2"
            conn = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
            conn.initiate_connection()
            conn.send_headers(1, [(":method", method), (":scheme", "https"), (":authority", "localhost"), (":path", path), *[(key.lower(), value) for key, value in headers]], end_stream=True)
            sock.sendall(conn.data_to_send())
            response = Response()
            ended = False
            while not ended:
                block = sock.recv(65536)
                assert block, "HTTP/2 closed before END_STREAM"
                for event in conn.receive_data(block):
                    if isinstance(event, ResponseReceived):
                        response.headers = [(key, value) for key, value in event.headers if key != ":status"]
                        response.status = int(dict(event.headers)[":status"])
                        if started is not None:
                            started.set()
                    elif isinstance(event, DataReceived):
                        response.add(event.data)
                        conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, StreamEnded):
                        ended = True
                    elif isinstance(event, StreamReset):
                        raise AssertionError(f"HTTP/2 reset {event.error_code}")
                outgoing = conn.data_to_send()
                if outgoing:
                    sock.sendall(outgoing)
            return response


async def h3_request(port: int, method: str, path: str, headers=(), started=None) -> Response:
    from aioquic.asyncio import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from test_http_router_h3 import HeadAwareConnection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
    from aioquic.quic.events import ConnectionTerminated, ProtocolNegotiated, StreamReset

    class Client(QuicConnectionProtocol):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.http = HeadAwareConnection(self._quic)
            self.response = Response()
            self.done = self._loop.create_future()

        def quic_event_received(self, event):
            if isinstance(event, ProtocolNegotiated):
                assert event.alpn_protocol == "h3"
            if isinstance(event, (StreamReset, ConnectionTerminated)) and not self.done.done():
                self.done.set_exception(AssertionError(f"HTTP/3 terminated: {event}"))
            for item in self.http.handle_event(event):
                if isinstance(item, HeadersReceived):
                    decoded = [(key.decode(), value.decode()) for key, value in item.headers]
                    self.response.status = int(dict(decoded)[":status"])
                    if started is not None:
                        started.set()
                    self.response.headers = [(key, value) for key, value in decoded if key != ":status"]
                elif isinstance(item, DataReceived):
                    self.response.add(item.data)
                if item.stream_ended and not self.done.done():
                    self.done.set_result(self.response)

    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    async with connect("127.0.0.1", port, configuration=config, create_protocol=Client) as client:
        stream = client._quic.get_next_available_stream_id()
        if method == "HEAD":
            client.http.head_streams.add(stream)
        client.http.send_headers(stream, [(b":method", method.encode()), (b":scheme", b"https"), (b":authority", b"localhost"), (b":path", path.encode()), *[(key.lower().encode(), value.encode()) for key, value in headers]], end_stream=True)
        client.transmit()
        return await asyncio.wait_for(client.done, 120)


class H3Client:
    def __init__(self, port: int):
        self.port = port

    def request(self, method: str, path: str, headers=(), started=None) -> Response:
        return asyncio.run(h3_request(self.port, method, path, headers, started))


class Fixture:
    def __init__(self, binary: Path, mode: str, root: Path, sanitize: bool):
        environment = os.environ.copy()
        if sanitize:
            environment["ASAN_OPTIONS"] = environment.get("ASAN_OPTIONS", "") + ":quarantine_size_mb=16:thread_local_quarantine_size_kb=64"
        self.process = subprocess.Popen([str(binary.resolve()), mode, str(root)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        self.peak_kib = 0
        self.stop = threading.Event()
        ready = self.process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(f"fixture did not start: {ready}\n{self.process.stderr.read()}")
        self.port = int(ready.split()[1])
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while not self.stop.is_set():
            result = subprocess.run(["ps", "-p", str(self.process.pid), "-o", "rss="], capture_output=True, text=True)
            if result.stdout.strip():
                self.peak_kib = max(self.peak_kib, int(result.stdout.strip()))
            self.stop.wait(0.02)

    def close(self, client):
        try:
            response = client.request("GET", "/shutdown")
            assert response.status == 200
            self.process.wait(timeout=10)
            output = self.process.stdout.read()
            errors = self.process.stderr.read()
            assert self.process.returncode == 0, errors
            assert "DRAINED" in output, output
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.stop.set()
            self.thread.join()


def cases(client, pattern: bytes, large_size: int, large_digest: str):
    checks = 0
    for method, path, headers, status, body in [
        ("GET", "/small.txt", (), 200, b"hello file"),
        ("HEAD", "/small.txt", (), 200, b""),
        ("POST", "/small.txt", (), 405, b""),
        ("GET", "/missing", (), 404, b""),
        ("GET", "/../outside", (), 404, b""),
        ("GET", "/link.txt", (), 404, b""),
        ("GET", "/dir", (), 301, b""),
        ("GET", "/dir/", (), 200, b"<html>index</html>"),
        ("GET", "/empty/", (), 404, b""),
        ("GET", "/small.txt", (("Range", "bytes=2-4"),), 206, b"llo"),
        ("GET", "/small.txt", (("Range", "bytes=-4"),), 206, b"file"),
        ("GET", "/small.txt", (("Range", "bytes=10-"),), 416, b""),
        ("GET", "/pattern.bin", (), 200, pattern),
        ("GET", "/pattern.bin", (("Range", "bytes=500-70000"),), 206, pattern[500:70001]),
    ]:
        response = client.request(method, path, headers)
        assert response.status == status, (method, path, response.status, status)
        assert bytes(response.body) == body, (method, path, response.count, len(body))
        assert response.count == len(body)
        if status in (200, 206) and path != "/dir/":
            expected_length = 10 if method == "HEAD" else len(body)
            assert response.values("content-length") == [str(expected_length)]
            assert response.values("accept-ranges") == ["bytes"]
        checks += 1
    first = client.request("GET", "/small.txt")
    assert first.values("content-type") == ["text/plain; charset=utf-8"]
    assert first.values("last-modified") == ["Sun, 06 Nov 1994 08:49:37 GMT"]
    etag = first.values("etag")[0]
    assert etag.startswith('W/"')
    for headers, status in [((("If-None-Match", etag),), 304), ((("If-Match", etag),), 412), ((("If-Modified-Since", "Sun, 06 Nov 1994 08:49:37 GMT"),), 304), ((("Range", "bytes=2-4"), ("If-Range", "Sun, 06 Nov 1994 08:49:37 GMT")), 206)]:
        response = client.request("GET", "/small.txt", headers)
        assert response.status == status
        checks += 1
    head = client.request("HEAD", "/large.bin")
    assert head.status == 200 and head.values("content-length") == [str(large_size)] and head.count == 0
    started = time.monotonic()
    received_headers = threading.Event()
    outcome = []
    failures = []

    def transfer():
        try:
            outcome.append(client.request("GET", "/large.bin", started=received_headers))
        except BaseException as error:
            failures.append(error)
            received_headers.set()

    transfer_thread = threading.Thread(target=transfer)
    transfer_thread.start()
    try:
        assert received_headers.wait(10), "large response did not start"
        sibling = client.request("GET", "/alive")
        assert sibling.status == 200 and bytes(sibling.body) == b"ok"
    finally:
        transfer_thread.join(timeout=120)
    assert not transfer_thread.is_alive(), "large response stalled"
    if failures:
        raise failures[0]
    large = outcome[0]
    assert large.status == 200
    assert large.values("content-length") == [str(large_size)]
    assert large.count == large_size
    assert large.digest.hexdigest() == large_digest
    alive = client.request("GET", "/alive")
    assert alive.status == 200 and bytes(alive.body) == b"ok"
    print(f"  {checks + 4} checks; {large_size} bytes SHA256={large.digest.hexdigest()} in {time.monotonic() - started:.2f}s", flush=True)


def build(binary: Path, sanitize: bool):
    binary.parent.mkdir(parents=True, exist_ok=True)
    command = ["mojo", "build", "--Werror", "-I", ".", "tests/http_fileserver_fixture.mojo", "-o", str(binary)]
    if platform.system() == "Linux":
        command += ["-Xlinker", "-ldl"]
    if sanitize:
        command += ["--sanitize", "address", "-g1"]
        if platform.system() == "Darwin":
            prefix = Path(os.environ["CONDA_PREFIX"])
            command += ["--external-libasan", str(prefix / "lib/libclang_rt.asan_osx_dynamic.dylib"), "-Xlinker", "-rpath", "-Xlinker", str(prefix / "lib")]
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--protocols", nargs="+", choices=["h1", "h2", "h3"], default=["h1"])
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--sanitize", action="store_true")
    parser.add_argument("--large-size", type=int, default=1073741824)
    args = parser.parse_args()
    assert 65536 < args.large_size <= 1073741824
    binary = Path("build/http_fileserver_fixture_asan" if args.sanitize else "build/http_fileserver_fixture")
    build(binary, args.sanitize)
    with tempfile.TemporaryDirectory(prefix="net-mojo-fileserver-") as directory:
        root = Path(directory)
        (root / "small.txt").write_bytes(b"hello file")
        os.utime(root / "small.txt", ns=(784111777123456789, 784111777123456789))
        (root / "dir").mkdir()
        (root / "dir/index.html").write_bytes(b"<html>index</html>")
        (root / "empty").mkdir()
        (root / "link.txt").symlink_to("small.txt")
        pattern = bytes(range(256)) * 512
        (root / "pattern.bin").write_bytes(pattern)
        with (root / "large.bin").open("wb") as file:
            file.truncate(args.large_size)
        digest = hashlib.sha256()
        zeros = bytes(65536)
        remaining = args.large_size
        while remaining:
            length = min(remaining, len(zeros))
            digest.update(zeros[:length])
            remaining -= length
        for protocol in args.protocols:
            mode = "h3" if protocol == "h3" else "tls" if args.tls or protocol == "h2" else "plain"
            fixture = Fixture(binary, mode, root, args.sanitize)
            client = H3Client(fixture.port) if protocol == "h3" else H2Client(fixture.port) if protocol == "h2" else H1Client(fixture.port, mode == "tls")
            try:
                print(f"FileServer {protocol} {'ASAN' if args.sanitize else 'normal'}", flush=True)
                cases(client, pattern, args.large_size, digest.hexdigest())
                if protocol == "h1":
                    client.slow_cancel()
            finally:
                fixture.close(client)
            assert fixture.peak_kib < 262144, f"unbounded native RSS: {fixture.peak_kib} KiB"
            print(f"  native peak RSS={fixture.peak_kib} KiB; budget drained", flush=True)


if __name__ == "__main__":
    main()
