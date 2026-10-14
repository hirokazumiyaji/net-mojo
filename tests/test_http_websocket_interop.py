#!/usr/bin/env python3
"""Independent RFC 6455 checks against the repository's own loopback fixture."""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import http.client
import os
from pathlib import Path
import selectors
import socket
import ssl
import subprocess

from websockets.asyncio.client import connect

ROOT = Path(__file__).resolve().parents[1]


def client_context(tls: bool) -> ssl.SSLContext | None:
    if not tls:
        return None
    context = ssl.create_default_context(cafile=str(ROOT / "build/tls/test-cert.pem"))
    context.set_alpn_protocols(["http/1.1"])
    return context


@contextlib.contextmanager
def fixture(*, tls: bool = False, conformance: bool = False, binary: str = "build/websocket_fixture"):
    env = os.environ | {
        "WEBSOCKET_TRANSPORT": "tls" if tls else "plain",
        "WEBSOCKET_CONFORMANCE": "1" if conformance else "0",
    }
    process = subprocess.Popen(
        [str(ROOT / binary)], cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        if not selector.select(timeout=30):
            raise RuntimeError("fixture did not become ready within 30 seconds")
        line = process.stdout.readline().strip()
        if not line.startswith("READY "):
            raise RuntimeError(f"fixture failed before readiness: {line}")
        port = int(line.split()[1])
        yield port
        context = client_context(tls)
        connection = (
            http.client.HTTPSConnection("localhost", port, context=context, timeout=5)
            if tls else http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        )
        try:
            connection.request("GET", "/shutdown")
            response = connection.getresponse()
            assert response.status == 200
            assert response.read() == b"bye"
        finally:
            connection.close()
        process.wait(timeout=10)
        if process.returncode != 0:
            raise RuntimeError(f"fixture exited {process.returncode}: {process.stdout.read()}")
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        process.stdout.close()


def coalesced_upgrade(port: int, tls: bool) -> None:
    stream = socket.create_connection(("localhost", port), timeout=5)
    if tls:
        stream = client_context(True).wrap_socket(stream, server_hostname="localhost")
    with stream:
        request = (b"GET /echo HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
                   b"Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
                   b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
        stream.sendall(request + b"\x81\x83\x01\x02\x03\x04" + bytes([ord("o") ^ 1, ord("w") ^ 2, ord("n") ^ 3]))
        head = bytearray()
        while not head.endswith(b"\r\n\r\n"):
            chunk = stream.recv(1)
            assert chunk, "EOF before switching response"
            head.extend(chunk)
            assert len(head) <= 4096
        assert head.startswith(b"HTTP/1.1 101")
        assert b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".lower() in head.lower()
        reply = bytearray()
        while len(reply) < 5:
            chunk = stream.recv(5 - len(reply))
            assert chunk, "EOF before coalesced echo"
            reply.extend(chunk)
        assert reply == b"\x81\x03own"
        stream.sendall(b"\x88\x82\x01\x02\x03\x04\x02\xea")
        close = bytearray()
        while len(close) < 4:
            chunk = stream.recv(4 - len(close))
            assert chunk, "EOF before Close reply"
            close.extend(chunk)
        assert close == b"\x88\x02\x03\xe8"


async def run(tls: bool, binary: str) -> None:
    context = client_context(tls)
    scheme = "wss" if tls else "ws"
    with fixture(tls=tls, binary=binary) as port:
        coalesced_upgrade(port, tls)
        uri = f"{scheme}://localhost:{port}/echo"
        options = dict(ssl=context, subprotocols=["other", "chat"], compression=None,
                       open_timeout=10, close_timeout=10, max_size=2 * 1024 * 1024, proxy=None)
        async with connect(uri, **options) as ws:
            assert ws.subprotocol == "chat"
            assert "Sec-WebSocket-Extensions" not in ws.response.headers
            for text in ["", "hello", "日本語 😀", "x" * 1_048_576]:
                await ws.send(text)
                assert await asyncio.wait_for(ws.recv(), timeout=10) == text
            for payload in [b"", bytes(range(256)), b"\x00\xff" * 524_288]:
                await ws.send(payload)
                assert await asyncio.wait_for(ws.recv(), timeout=10) == payload
            await ws.send(["fragment ", "日本語", " 😀"])
            assert await asyncio.wait_for(ws.recv(), timeout=5) == "fragment 日本語 😀"
            await ws.send([b"\x00", b"\xff", b"binary"])
            assert await asyncio.wait_for(ws.recv(), timeout=5) == b"\x00\xffbinary"
            pong = await ws.ping(b"control-payload")
            await asyncio.wait_for(pong, timeout=5)
            sibling_options = options | {"subprotocols": None}
            async with connect(uri, **sibling_options) as sibling:
                await sibling.send("sibling")
                assert await asyncio.wait_for(sibling.recv(), timeout=5) == "sibling"
            await ws.send("after sibling closes")
            assert await asyncio.wait_for(ws.recv(), timeout=5) == "after sibling closes"
            await ws.close(code=1000, reason="done 😀")
            assert ws.close_code == 1000
            assert ws.close_reason == "done 😀"
        async with connect(uri, **(options | {"compression": "deflate"})) as ws:
            assert "Sec-WebSocket-Extensions" not in ws.response.headers
            await ws.send("without compression")
            assert await asyncio.wait_for(ws.recv(), timeout=5) == "without compression"
    print(f"PASS {scheme}: text/binary, 1 MiB payloads, fragmentation, Ping/Pong, siblings, Close, extension omission")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--binary", default="build/websocket_fixture")
    args = parser.parse_args()
    asyncio.run(run(args.tls, args.binary))


if __name__ == "__main__":
    main()
