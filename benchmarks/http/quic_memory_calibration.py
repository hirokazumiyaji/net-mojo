#!/usr/bin/env python3
"""Measure QUIC server per-connection RSS calibration.

Opens N idle QUIC connections against a running Mojo H3 server, samples the
server RSS before and after, and reports the per-connection delta. The
documented soft estimate in
``net/quic/provider/src/lib.rs`` (ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION)
is 256 KiB; this script produces a measured calibration against that value.

Usage (from an environment that has aioquic available, e.g. tls-http3)::

    python benchmarks/http/quic_memory_calibration.py \\
        --url https://127.0.0.1:18453 --server-pid "$PID" \\
        --connections 100 --hold-seconds 5

The server must be started separately so this script can sample a known PID::

    build/bin/http3_server &
    echo $!

Each row records (count, server RSS bytes before, after idle hold, after one
GET /fixed per connection). Per-connection delta is
``(RSS_after_idle - RSS_before) / N``. Including request work makes the number
upper-biased; the first delta is the pure handshake+idle cost. The script
exits non-zero if the server PID disappears mid-run.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import ssl
import subprocess
import sys
import time
from typing import Optional
from urllib.parse import urlparse

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated


class IdleProtocol(QuicConnectionProtocol):
    """Minimal H3 client: establishes the handshake and can issue one GET."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.http: Optional[H3Connection] = None
        self.alpn: Optional[str] = None
        self._inflight: dict[int, asyncio.Future] = {}
        self._bodies: dict[int, bytearray] = {}

    def quic_event_received(self, event) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.alpn = event.alpn_protocol
            if event.alpn_protocol in H3_ALPN:
                self.http = H3Connection(self._quic)
        if self.http is None:
            return
        for http_event in self.http.handle_event(event):
            fut = self._inflight.get(http_event.stream_id)
            if fut is None:
                continue
            if isinstance(http_event, DataReceived):
                self._bodies.setdefault(http_event.stream_id, bytearray()).extend(
                    http_event.data
                )
            if getattr(http_event, "stream_ended", False):
                if not fut.done():
                    fut.set_result(True)

    async def get(self, path: bytes, authority: bytes) -> int:
        assert self.http is not None
        stream_id = self._quic.get_next_available_stream_id()
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._inflight[stream_id] = fut
        self.http.send_headers(
            stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", authority),
                (b":path", path),
            ],
            end_stream=True,
        )
        self.transmit()
        try:
            await asyncio.wait_for(fut, timeout=10.0)
        finally:
            body = self._bodies.pop(stream_id, bytearray())
            self._inflight.pop(stream_id, None)
        return len(body)


def rss_bytes(pid: int) -> int:
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)])
    kib = int(out.decode().strip())
    return kib * 1024


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


async def open_connections(url: str, count: int, timeout_s: float) -> list:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    authority = f"{host}:{port}".encode()

    config = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN, idle_timeout=120.0
    )
    config.verify_mode = ssl.CERT_NONE

    stack = []
    for _ in range(count):
        cm = connect(host, port, configuration=config, create_protocol=IdleProtocol)
        proto = await asyncio.wait_for(cm.__aenter__(), timeout=timeout_s)
        await asyncio.wait_for(proto.wait_connected(), timeout=timeout_s)
        stack.append((cm, proto, authority))
    return stack


async def close_connections(stack: list) -> None:
    for cm, _, _ in stack:
        try:
            await cm.__aexit__(None, None, None)
        except Exception:
            pass


async def run(args) -> dict:
    pid = args.server_pid
    if not pid_alive(pid):
        raise SystemExit(f"server pid {pid} is not alive at start")

    before_rss = rss_bytes(pid)
    stack = await open_connections(args.url, args.connections, args.timeout)
    after_handshake_rss = rss_bytes(pid)

    await asyncio.sleep(args.hold_seconds)
    after_idle_rss = rss_bytes(pid)

    first_bodies = 0
    if args.one_request:
        for _, proto, authority in stack:
            try:
                first_bodies += await proto.get(b"/fixed", authority)
            except Exception as exc:
                print(f"request error: {exc}", file=sys.stderr)
        await asyncio.sleep(0.5)
    after_request_rss = rss_bytes(pid)

    await close_connections(stack)
    await asyncio.sleep(0.5)
    after_close_rss = rss_bytes(pid)

    if not pid_alive(pid):
        raise SystemExit(f"server pid {pid} died mid-run")

    n = args.connections
    def per_conn(delta: int) -> float:
        return delta / n if n > 0 else 0.0

    result = {
        "connections": n,
        "hold_seconds": args.hold_seconds,
        "server_pid": pid,
        "rss_bytes": {
            "before": before_rss,
            "after_handshake": after_handshake_rss,
            "after_idle_hold": after_idle_rss,
            "after_one_request": after_request_rss,
            "after_close": after_close_rss,
        },
        "per_connection_bytes": {
            "handshake": per_conn(after_handshake_rss - before_rss),
            "idle_hold": per_conn(after_idle_rss - before_rss),
            "post_one_request": per_conn(after_request_rss - before_rss),
        },
        "bytes_received_total": first_bodies,
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://127.0.0.1:18453")
    parser.add_argument("--server-pid", type=int, required=True)
    parser.add_argument("--connections", type=int, required=True)
    parser.add_argument("--hold-seconds", type=float, default=3.0)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--one-request", action="store_true",
                        help="issue GET /fixed on each connection before closing")
    args = parser.parse_args()

    result = asyncio.run(run(args))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
