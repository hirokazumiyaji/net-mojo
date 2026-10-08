#!/usr/bin/env python3
"""HTTP/3 load generator for Issue #42 PR 10 (aioquic client, pinned 1.3.0).

Homebrew h2load bottles typically lack ngtcp2/nghttp3, so this client is the
documented H3 load tool. It opens CLIENTS QUIC connections and keeps up to
STREAMS concurrent GET /fixed requests in flight per connection.

Usage:
  pixi run -e tls-http3 python benchmarks/http3_load.py \\
    --url https://127.0.0.1:18453/fixed \\
    --clients 64 --streams 1 \\
    --warmup 10 --duration 30
"""

from __future__ import annotations

import argparse
import asyncio
import ssl
import statistics
import sys
import time
from typing import List, Optional
from urllib.parse import urlparse

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated
from aioquic.quic.packet import QuicProtocolVersion


class LoadProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.http: Optional[H3Connection] = None
        self.alpn: Optional[str] = None
        self._inflight: dict[int, dict] = {}

    def quic_event_received(self, event) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.alpn = event.alpn_protocol
            if event.alpn_protocol in H3_ALPN:
                self.http = H3Connection(self._quic)
        if self.http is None:
            return
        for http_event in self.http.handle_event(event):
            pending = self._inflight.get(http_event.stream_id)
            if pending is None:
                continue
            if isinstance(http_event, HeadersReceived):
                pending["status"] = dict(http_event.headers).get(b":status")
            elif isinstance(http_event, DataReceived):
                pending["body"].extend(http_event.data)
            if getattr(http_event, "stream_ended", False):
                pending["done_at"] = time.perf_counter()
                pending["future"].set_result(pending)

    async def get(self, path: bytes, authority: bytes) -> dict:
        assert self.http is not None
        stream_id = self._quic.get_next_available_stream_id()
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        pending = {
            "future": future,
            "body": bytearray(),
            "status": None,
            "start": time.perf_counter(),
            "done_at": None,
            "stream_id": stream_id,
        }
        self._inflight[stream_id] = pending
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
            return await future
        finally:
            self._inflight.pop(stream_id, None)


def _client_configuration() -> QuicConfiguration:
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        server_name="localhost",
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE
    return configuration


async def _wait_alpn(client: "LoadProtocol") -> None:
    for _ in range(50):
        if client.alpn is not None:
            break
        await asyncio.sleep(0.01)
    if client.alpn not in H3_ALPN and client.alpn != "h3":
        raise RuntimeError(f"unexpected ALPN: {client.alpn!r}")


async def _one_connection(
    host: str,
    port: int,
    path: bytes,
    authority: bytes,
    streams: int,
    stop_at: float,
    warmup_until: float,
    latencies: List[float],
    counters: dict,
) -> None:
    configuration = _client_configuration()

    async with connect(
        host,
        port,
        configuration=configuration,
        create_protocol=LoadProtocol,
    ) as client:
        assert isinstance(client, LoadProtocol)
        await _wait_alpn(client)

        sem = asyncio.Semaphore(streams)
        # Per-connection tally so a connection whose handshake completed
        # only after stop_at (short duration, out-of-band loss) is counted
        # as failed instead of silently contributing zero samples.
        local = {"ok": 0, "warmup_ok": 0, "failed": 0}

        async def one_request() -> None:
            async with sem:
                try:
                    result = await asyncio.wait_for(
                        client.get(path, authority), timeout=30.0
                    )
                except Exception:
                    counters["failed"] += 1
                    local["failed"] += 1
                    return
                # Classify by when the stream actually ended (done_at), not by
                # the later timestamp at which this task is rescheduled.
                done_at = result["done_at"] or time.perf_counter()
                elapsed = done_at - result["start"]
                if result["status"] == b"200":
                    if done_at > stop_at:
                        counters["late"] = counters.get("late", 0) + 1
                        return
                    # Validate the fixed response body: truncated/empty/wrong
                    # bodies must not count as success for the /fixed workload.
                    if path == b"/fixed" and bytes(result["body"]) != b"a" * 64:
                        counters["failed"] += 1
                        local["failed"] += 1
                        return
                    if done_at >= warmup_until:
                        counters["ok"] += 1
                        local["ok"] += 1
                        latencies.append(elapsed * 1_000_000.0)  # µs
                    else:
                        counters["warmup_ok"] += 1
                        local["warmup_ok"] += 1
                else:
                    counters["failed"] += 1
                    local["failed"] += 1

        workers = []

        async def worker() -> None:
            while time.perf_counter() < stop_at:
                await one_request()

        for _ in range(streams):
            workers.append(asyncio.create_task(worker()))
        await asyncio.gather(*workers)

        if local["ok"] == 0:
            # No completion inside the measurement window: either the
            # handshake finished after stop_at (short duration) or every
            # response arrived late (out-of-band loss). Warmup-only
            # successes do not make this a usable measurement.
            counters["failed"] += 1


async def _churn_worker(
    host: str,
    port: int,
    path: bytes,
    authority: bytes,
    stop_at: float,
    warmup_until: float,
    latencies: List[float],
    counters: dict,
) -> None:
    while time.perf_counter() < stop_at:
        start = time.perf_counter()
        ok = True
        try:
            async with connect(
                host,
                port,
                configuration=_client_configuration(),
                create_protocol=LoadProtocol,
            ) as client:
                assert isinstance(client, LoadProtocol)
                await _wait_alpn(client)
                result = await asyncio.wait_for(
                    client.get(path, authority), timeout=30.0
                )
        except Exception:
            ok = False
            done_at = time.perf_counter()
        else:
            done_at = result["done_at"] or time.perf_counter()
            if result["status"] != b"200":
                ok = False
            elif path == b"/fixed" and bytes(result["body"]) != b"a" * 64:
                ok = False
        elapsed = done_at - start
        if done_at > stop_at:
            if ok:
                counters["late"] = counters.get("late", 0) + 1
            else:
                counters["late_failed"] = counters.get("late_failed", 0) + 1
            continue
        if done_at >= warmup_until:
            if ok:
                counters["ok"] += 1
                latencies.append(elapsed * 1_000_000.0)
            else:
                counters["failed"] += 1
        else:
            if ok:
                counters["warmup_ok"] += 1
            else:
                counters["warmup_failed"] = counters.get("warmup_failed", 0) + 1


def _percentile(sorted_vals: List[float], p: float) -> float:
    if not sorted_vals:
        return float("nan")
    # nearest-rank style matching h2load-ish reporting
    idx = max(
        0, min(len(sorted_vals) - 1, int(round((p / 100.0) * (len(sorted_vals) - 1))))
    )
    return sorted_vals[idx]


async def run_load(
    url: str,
    clients: int,
    streams: int,
    warmup_s: float,
    duration_s: float,
    churn: bool = False,
) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    path = (parsed.path or "/").encode()
    authority = f"{host}:{port}".encode()

    if clients < 1:
        raise RuntimeError(f"--clients must be >= 1, got {clients}")
    if streams < 1:
        raise RuntimeError(f"--streams must be >= 1, got {streams}")
    if churn and streams != 1:
        raise RuntimeError("--churn requires --streams 1 (one request per connection)")

    latencies: List[float] = []
    counters = {"ok": 0, "failed": 0, "warmup_ok": 0}
    anchor_before = time.perf_counter()
    anchor_unix_s = time.time()
    start = time.perf_counter()
    anchor_span_s = start - anchor_before
    load_start_unix_s = anchor_unix_s + anchor_span_s / 2
    warmup_until = start + warmup_s
    stop_at = warmup_until + duration_s

    if churn:
        tasks = [
            asyncio.create_task(
                _churn_worker(
                    host, port, path, authority,
                    stop_at, warmup_until, latencies, counters,
                )
            )
            for _ in range(clients)
        ]
    else:
        tasks = [
            asyncio.create_task(
                _one_connection(
                    host,
                    port,
                    path,
                    authority,
                    streams,
                    stop_at,
                    warmup_until,
                    latencies,
                    counters,
                )
            )
            for _ in range(clients)
        ]

    results = await asyncio.gather(*tasks, return_exceptions=True)
    measure_s = max(1e-9, duration_s)
    for r in results:
        if isinstance(r, Exception):
            counters["failed"] += 1
            print(f"connection error: {r}", file=sys.stderr)

    latencies.sort()
    req_s = counters["ok"] / measure_s
    return {
        "req_s": req_s,
        "ok": counters["ok"],
        "failed": counters["failed"],
        "warmup_ok": counters["warmup_ok"],
        "warmup_failed": counters.get("warmup_failed", 0),
        "late": counters.get("late", 0),
        "late_failed": counters.get("late_failed", 0),
        "load_start_unix_s": load_start_unix_s,
        "measurement_start_unix_s": load_start_unix_s + warmup_s,
        "measurement_end_unix_s": load_start_unix_s + warmup_s + duration_s,
        "clock_anchor_span_s": anchor_span_s,
        "rate_denominator_s": measure_s,
        "p50_us": _percentile(latencies, 50),
        "p95_us": _percentile(latencies, 95),
        "p99_us": _percentile(latencies, 99),
        "mean_us": statistics.fmean(latencies) if latencies else float("nan"),
        "samples": len(latencies),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--clients", type=int, default=64)
    parser.add_argument("--streams", type=int, default=1)
    parser.add_argument("--warmup", type=float, default=5.0)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument(
        "--churn",
        action="store_true",
        help="open a new QUIC connection per request (full handshake, no resumption)",
    )
    args = parser.parse_args()

    stats = asyncio.run(
        run_load(
            args.url,
            args.clients,
            args.streams,
            args.warmup,
            args.duration,
            churn=args.churn,
        )
    )
    # Machine-readable one-liner for the shell harness.
    print(
        "req_s={req_s:.3f} p50_us={p50_us:.0f} p95_us={p95_us:.0f} "
        "p99_us={p99_us:.0f} ok={ok} failed={failed} samples={samples} "
        "warmup_successes={warmup_ok} late_responses={late} "
        "load_start_unix_s={load_start_unix_s:.6f} "
        "measurement_start_unix_s={measurement_start_unix_s:.6f} "
        "measurement_end_unix_s={measurement_end_unix_s:.6f} "
        "clock_anchor_span_s={clock_anchor_span_s:.9g} "
        "rate_denominator_s={rate_denominator_s:.9g}".format(
            **stats
        )
    )
    if stats["failed"] > 0:
        print(f'{stats["failed"]} request(s) failed', file=sys.stderr)
        raise SystemExit(1)
    if stats["samples"] == 0:
        # No completion inside the measurement window: an empty experiment
        # must never be reported as a valid (zero-throughput) run.
        print("no measurement samples collected", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
