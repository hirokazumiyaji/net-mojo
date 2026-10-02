#!/usr/bin/env python3
"""HTTP/3 special scenarios for Issue #42 PR 11 multiplex matrix.

Scenarios (qualitative + limited timing; aioquic client):
  slow   — hold one large POST /echo upload open while N GET /fixed siblings
           run on the same connection, then finish the upload (matches H2;
           aioquic cannot withhold QUIC MAX_STREAM_DATA for a slow reader)
  cancel — RST one in-flight stream (H3_REQUEST_CANCELLED) after burning
           the provider request-body budget with incomplete-reset cycles,
           while siblings complete, then GET /fixed on the same connection
  loss   — drop a fraction of outbound UDP datagrams (client-side loss emulation)

Usage:
  pixi run -e tls-http3 python benchmarks/http/http3_scenarios.py \\
    --url https://127.0.0.1:18453/fixed --scenario slow
"""

from __future__ import annotations

import argparse
import asyncio
import random
import ssl
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

# HTTP/3 request cancelled (RFC 9114)
H3_REQUEST_CANCELLED = 0x10C

# Aggregate request-body budget across active streams
# (docs/design/http3-server.md). Cancel burns this with incomplete uploads
# so a server that ignores RESET_STREAM cleanup fails later admission.
H3_REQUEST_BODY_BUDGET = 64 * 1024 * 1024
# Bytes sent before each incomplete reset. Received DATA is what the
# provider charges against the budget before the stream is cancelled.
CANCEL_PARTIAL = 256 * 1024

# Expected /fixed response, shared with the main H3 loader
# (benchmarks/http3_load.py) so every scenario validates payloads alike.
FIXED_PATH = b"/fixed"
FIXED_BODY = b"a" * 64


def _body_ok(path: bytes, result) -> bool:
    """True when a response carries the exact expected body for `path`.

    A 200 with a truncated or corrupted body is not a valid measurement, so
    scenarios count a request only when its payload matches the fixture.
    """
    if not isinstance(result, dict):
        return False
    if path == FIXED_PATH and bytes(result.get("body", b"")) != FIXED_BODY:
        return False
    return True


class ScenarioProtocol(QuicConnectionProtocol):
    def __init__(self, *args, drop_rate: float = 0.0, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.http: Optional[H3Connection] = None
        self.alpn: Optional[str] = None
        self._inflight: dict[int, dict] = {}
        # Streams whose H3 receive processing is withheld (slow-consumer
        # emulation): events are staged, not completed, until released.
        self._held: set[int] = set()
        self._staged: dict[int, list] = {}
        self.drop_rate = drop_rate
        self.dropped = 0
        self.sent = 0

    def transmit(self) -> None:  # type: ignore[override]
        """Send queued datagrams, optionally dropping a fraction (loss scenario)."""
        self._transmit_task = None
        for data, addr in self._quic.datagrams_to_send(now=self._loop.time()):
            self.sent += 1
            if self.drop_rate > 0 and random.random() < self.drop_rate:
                self.dropped += 1
                continue
            self._transport.sendto(data, addr)
        timer_at = self._quic.get_timer()
        if self._timer is not None and self._timer_at != timer_at:
            self._timer.cancel()
            self._timer = None
        if self._timer is None and timer_at is not None:
            self._timer = self._loop.call_at(timer_at, self._handle_timer)
        self._timer_at = timer_at

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
            if http_event.stream_id in self._held:
                # Withhold application-level consumption: stage the event
                # without completing the stream. (Transport still flows;
                # true window backpressure is not exposed by aioquic.)
                self._staged.setdefault(http_event.stream_id, []).append(
                    http_event
                )
                continue
            self._consume(pending, http_event)

    def _consume(self, pending: dict, http_event) -> None:
        if isinstance(http_event, HeadersReceived):
            pending["status"] = dict(http_event.headers).get(b":status")
        elif isinstance(http_event, DataReceived):
            pending["body"].extend(http_event.data)
        if getattr(http_event, "stream_ended", False):
            pending["done_at"] = time.perf_counter()
            if not pending["future"].done():
                pending["future"].set_result(pending)

    def hold_stream(self, stream_id: int) -> None:
        """Start withholding H3 receive processing for a stream."""
        self._held.add(stream_id)

    def held_bytes(self, stream_id: int) -> int:
        """Bytes received at H3 level while consumption is withheld."""
        total = 0
        for ev in self._staged.get(stream_id, []):
            if isinstance(ev, DataReceived):
                total += len(ev.data)
        return total

    def held_ended(self, stream_id: int) -> bool:
        """True when a held stream has already been fully received.

        A held stream's future is deliberately never resolved — the staged
        events are only replayed by release_stream() — so the future cannot
        report transport completion and `future.done()` is always False for
        a held stream. The staged events can: once one of them carries
        stream_ended, the whole response has already arrived, whatever the
        application has done with it. Note that aioquic cannot supply real
        receive-window backpressure here: MAX_STREAM_DATA is extended from
        the receiver's highest offset (bytes that arrived), not from what
        the application has consumed, so withholding consumption alone
        never stalls the sender.
        """
        return any(
            getattr(ev, "stream_ended", False)
            for ev in self._staged.get(stream_id, [])
        )

    def release_stream(self, stream_id: int) -> None:
        """Replay staged events, completing the stream normally."""
        self._held.discard(stream_id)
        pending = self._inflight.get(stream_id)
        staged = self._staged.pop(stream_id, [])
        if pending is None:
            return
        for ev in staged:
            self._consume(pending, ev)

    async def open_upload(
        self, body_len: int, prefix: bytes, authority: bytes
    ) -> dict:
        """Start POST /echo with a deliberately unfinished request body.

        Used for the slow-stream scenario. aioquic extends MAX_STREAM_DATA from
        the highest received offset, so application-level hold_stream cannot
        create real receive-window backpressure; leaving the request open does.
        """
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
            "cancelled": False,
            "sent": len(prefix),
        }
        self._inflight[stream_id] = pending
        self.http.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", authority),
                (b":path", b"/echo"),
                (b"content-length", str(body_len).encode()),
            ],
            end_stream=False,
        )
        if prefix:
            self.http.send_data(stream_id, prefix, end_stream=False)
        self.transmit()
        return pending

    async def finish_upload(
        self, pending: dict, body: bytes, timeout: float = 30.0
    ) -> dict:
        """Send the remainder of an open_upload body and await the response."""
        assert self.http is not None
        stream_id = pending["stream_id"]
        sent = int(pending.get("sent", 0))
        for off in range(sent, len(body), 16384):
            self.http.send_data(
                stream_id,
                body[off : off + 16384],
                end_stream=(off + 16384 >= len(body)),
            )
        self.transmit()
        try:
            return await asyncio.wait_for(pending["future"], timeout=timeout)
        finally:
            self._inflight.pop(stream_id, None)

    async def post_echo(
        self, body: bytes, authority: bytes, *, hold: bool = False
    ) -> dict:
        """POST /echo with a large body so the response spans many datagrams.

        Used for the slow-stream case: a 64-byte /fixed response can
        complete during the artificial delay even on a serializing server,
        so a large echo response is needed to exercise multiplexing. With
        hold=True, H3 receive processing is withheld (see hold_stream);
        the pending record is returned immediately and the caller must
        release_stream() then await_pending() it.
        """
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
            "cancelled": False,
        }
        self._inflight[stream_id] = pending
        if hold:
            self.hold_stream(stream_id)
        self.http.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", authority),
                (b":path", b"/echo"),
                (b"content-length", str(len(body)).encode()),
            ],
            end_stream=False,
        )
        # Chunk to respect flow control.
        for off in range(0, len(body), 16384):
            self.http.send_data(
                stream_id,
                body[off : off + 16384],
                end_stream=(off + 16384 >= len(body)),
            )
        self.transmit()
        if hold:
            return pending
        try:
            return await asyncio.wait_for(future, timeout=30.0)
        finally:
            self._inflight.pop(stream_id, None)

    async def await_pending(self, pending: dict, timeout: float = 30.0) -> dict:
        """Await a held stream previously returned by post_echo(hold=True)."""
        try:
            return await asyncio.wait_for(pending["future"], timeout=timeout)
        finally:
            self._inflight.pop(pending["stream_id"], None)

    async def get(
        self,
        path: bytes,
        authority: bytes,
        *,
        slow_s: float = 0.0,
        cancel: bool = False,
    ) -> dict:
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
            "cancelled": False,
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
        if cancel:
            await asyncio.sleep(0.005)
            # Only a still-in-flight stream proves cancellation; a tiny
            # /fixed response may already have completed in 5ms.
            was_inflight = not future.done()
            if was_inflight:
                self._quic.reset_stream(stream_id, error_code=H3_REQUEST_CANCELLED)
                self.transmit()
            pending["cancelled"] = True
            pending["was_inflight"] = was_inflight
            self._inflight.pop(stream_id, None)
            return pending
        try:
            if slow_s > 0:
                # Delay before awaiting completion to emulate a slow consumer
                # while other streams progress on the same connection.
                await asyncio.sleep(slow_s)
            return await asyncio.wait_for(future, timeout=30.0)
        finally:
            self._inflight.pop(stream_id, None)


async def _wait_alpn(client: ScenarioProtocol) -> None:
    for _ in range(50):
        if client.alpn is not None:
            break
        await asyncio.sleep(0.01)
    if client.alpn not in H3_ALPN and client.alpn != "h3":
        raise RuntimeError(f"unexpected ALPN: {client.alpn!r}")


async def run_slow(url: str, slow_s: float, siblings: int) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    path = (parsed.path or "/").encode()
    authority = f"{host}:{port}".encode()

    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        server_name="localhost",
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE

    t0 = time.perf_counter()
    # Match H2 slow: leave a large POST /echo request unfinished so the
    # server is still reading that stream while siblings complete. aioquic
    # cannot withhold QUIC receive credit (MAX_STREAM_DATA tracks the highest
    # received offset), so a response-side "hold" would not create a slow
    # reader and must not be published as a pass.
    slow_body = b"x" * (256 * 1024)
    prefix_len = 32 * 1024
    async with connect(
        host,
        port,
        configuration=configuration,
        create_protocol=ScenarioProtocol,
    ) as client:
        assert isinstance(client, ScenarioProtocol)
        await _wait_alpn(client)

        slow_pending = await client.open_upload(
            len(slow_body), slow_body[:prefix_len], authority
        )
        target_unfinished_at_dispatch = not slow_pending["future"].done()
        sibling_tasks = [
            asyncio.create_task(client.get(path, authority))
            for _ in range(siblings)
        ]
        sibling_results = await asyncio.gather(
            *sibling_tasks, return_exceptions=True
        )
        target_unfinished_during_siblings = not slow_pending["future"].done()
        if slow_s > 0:
            await asyncio.sleep(slow_s)
        target_unfinished_before_finish = not slow_pending["future"].done()
        slow_result = await client.finish_upload(slow_pending, slow_body)

    sibling_ok = sum(
        1
        for r in sibling_results
        if isinstance(r, dict)
        and r.get("status") == b"200"
        and _body_ok(path, r)
    )
    sibling_body_bad = sum(
        1
        for r in sibling_results
        if isinstance(r, dict)
        and r.get("status") == b"200"
        and not _body_ok(path, r)
    )
    sibling_fail = siblings - sibling_ok
    slow_ok = (
        isinstance(slow_result, dict) and slow_result.get("status") == b"200"
    )
    slow_body_ok = (
        bytes(slow_result.get("body", b"")) == slow_body
        if isinstance(slow_result, dict)
        else False
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000
    verdict = (
        "pass"
        if slow_ok
        and slow_body_ok
        and sibling_ok == siblings
        and target_unfinished_at_dispatch
        and target_unfinished_during_siblings
        and target_unfinished_before_finish
        else "fail"
    )
    return {
        "scenario": "slow",
        "verdict": verdict,
        "conn": "single",
        "method": "incomplete_upload",
        "slow_ok": int(slow_ok),
        "slow_body_ok": int(slow_body_ok),
        "sibling_ok": sibling_ok,
        "sibling_body_bad": sibling_body_bad,
        "sibling_fail": sibling_fail,
        "target_unfinished_at_dispatch": int(target_unfinished_at_dispatch),
        "target_unfinished_during_siblings": int(
            target_unfinished_during_siblings
        ),
        "target_unfinished_before_finish": int(target_unfinished_before_finish),
        "elapsed_ms": elapsed_ms,
        "slow_s": slow_s,
        "siblings": siblings,
    }


async def run_cancel(url: str, siblings: int) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    path = (parsed.path or "/").encode()
    authority = f"{host}:{port}".encode()

    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        server_name="localhost",
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE

    t0 = time.perf_counter()
    # Declared larger than CANCEL_PARTIAL so END_STREAM never arrives and
    # the peer must keep the incomplete request until RESET_STREAM.
    cancel_declared = CANCEL_PARTIAL * 2
    cancel_body = b"y" * cancel_declared
    # If each incomplete cancel kept its buffered DATA charged, this many
    # cycles would exhaust the provider request-body budget.
    reserve_cycles = (H3_REQUEST_BODY_BUDGET // CANCEL_PARTIAL) + 1
    async with connect(
        host,
        port,
        configuration=configuration,
        create_protocol=ScenarioProtocol,
    ) as client:
        assert isinstance(client, ScenarioProtocol)
        await _wait_alpn(client)

        async def _incomplete_reset() -> int:
            """Send a partial POST /echo and RESET_STREAM it mid-request.

            Returns bytes sent before the reset (the amount a forgetful
            server would keep charged against the request-body budget).
            """
            assert isinstance(client, ScenarioProtocol)
            stream_id = client._quic.get_next_available_stream_id()
            loop = asyncio.get_running_loop()
            future = loop.create_future()
            pending = {
                "future": future,
                "body": bytearray(),
                "status": None,
                "start": time.perf_counter(),
                "done_at": None,
                "stream_id": stream_id,
                "cancelled": False,
            }
            assert client.http is not None
            client._inflight[stream_id] = pending
            partial = cancel_body[:CANCEL_PARTIAL]
            client.http.send_headers(
                stream_id,
                [
                    (b":method", b"POST"),
                    (b":scheme", b"https"),
                    (b":authority", authority),
                    (b":path", b"/echo"),
                    (b"content-length", str(len(cancel_body)).encode()),
                ],
                end_stream=False,
            )
            client.http.send_data(stream_id, partial, end_stream=False)
            client.transmit()
            # Let the peer buffer the DATA before we cancel.
            await asyncio.sleep(0.002)
            was_inflight = not future.done()
            if was_inflight:
                client._quic.reset_stream(
                    stream_id, error_code=H3_REQUEST_CANCELLED
                )
                client.transmit()
            pending["cancelled"] = True
            pending["was_inflight"] = was_inflight
            client._inflight.pop(stream_id, None)
            return len(partial) if was_inflight else 0

        # Phase 1: prove the peer processes RESET_STREAM cleanup. A server
        # that ignores cancel and keeps incomplete request bodies charged
        # will refuse later work once the documented budget is exceeded.
        leaked_estimate = 0
        cycles_done = 0
        for _ in range(reserve_cycles):
            leaked_estimate += await _incomplete_reset()
            cycles_done += 1

        # Phase 2: concurrent cancel + siblings so reset overlaps sibling
        # traffic (siblings remain outstanding across the reset).
        async def _cancel_large() -> dict:
            assert isinstance(client, ScenarioProtocol)
            stream_id = client._quic.get_next_available_stream_id()
            loop = asyncio.get_running_loop()
            future = loop.create_future()
            pending = {
                "future": future,
                "body": bytearray(),
                "status": None,
                "start": time.perf_counter(),
                "done_at": None,
                "stream_id": stream_id,
                "cancelled": False,
            }
            assert client.http is not None
            client._inflight[stream_id] = pending
            client.http.send_headers(
                stream_id,
                [
                    (b":method", b"POST"),
                    (b":scheme", b"https"),
                    (b":authority", authority),
                    (b":path", b"/echo"),
                    (b"content-length", str(len(cancel_body)).encode()),
                ],
                end_stream=False,
            )
            client.http.send_data(
                stream_id, cancel_body[:CANCEL_PARTIAL], end_stream=False
            )
            client.transmit()
            await asyncio.sleep(0.005)
            was_inflight = not future.done()
            # Siblings must still be outstanding when the reset fires; on
            # loopback a 64-byte /fixed can complete before the sleep ends,
            # which would hide a server that breaks the connection on reset.
            siblings_outstanding = sum(
                1
                for sid, p in client._inflight.items()
                if sid != stream_id and not p["future"].done()
            )
            if was_inflight:
                client._quic.reset_stream(
                    stream_id, error_code=H3_REQUEST_CANCELLED
                )
                client.transmit()
            pending["cancelled"] = True
            pending["was_inflight"] = was_inflight
            pending["siblings_outstanding_at_reset"] = siblings_outstanding
            client._inflight.pop(stream_id, None)
            return pending

        async def _sibling() -> dict:
            assert isinstance(client, ScenarioProtocol)
            result = await client.post_echo(sibling_body, authority)
            body_ok = bytes(result.get("body", b"")) == sibling_body
            return {"status": result.get("status"), "body_ok": body_ok}

        cancel_task = asyncio.create_task(_cancel_large())
        # Siblings use a large echo so they are still in flight when the
        # reset fires: 64-byte /fixed responses finish within the 5 ms
        # window on loopback, which would leave nothing to prove the
        # connection survives the reset.
        sibling_body = b"z" * CANCEL_PARTIAL
        sibling_tasks = [
            asyncio.create_task(_sibling()) for _ in range(siblings)
        ]
        cancelled, sibling_results = await asyncio.gather(
            cancel_task,
            asyncio.gather(*sibling_tasks, return_exceptions=True),
        )
        # Match H2 cancel: a server that GOAWAYs / drains on RST can still
        # finish already-admitted siblings. Probe a fresh GET on the same
        # connection before claiming it remains reusable — and after the
        # budget burn, so pinned incomplete bodies would block admission.
        post_reset_ok = False
        try:
            after = await client.get(FIXED_PATH, authority)
            post_reset_ok = (
                isinstance(after, dict)
                and after.get("status") == b"200"
                and _body_ok(FIXED_PATH, after)
            )
        except Exception:
            post_reset_ok = False

    sibling_ok = sum(
        1
        for r in sibling_results
        if isinstance(r, dict)
        and r.get("status") == b"200"
        and r.get("body_ok")
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000
    siblings_outstanding = int(cancelled.get("siblings_outstanding_at_reset", 0))
    # Pass: budget burn completed, target was in-flight when reset fired,
    # at least one sibling was still outstanding across the reset, all
    # siblings still succeed, and a post-reset request on the same
    # connection succeeds (connection reusable; cancel released capacity).
    verdict = (
        "pass"
        if cycles_done >= reserve_cycles
        and leaked_estimate > H3_REQUEST_BODY_BUDGET
        and cancelled.get("cancelled")
        and cancelled.get("was_inflight")
        and siblings_outstanding > 0
        and sibling_ok == siblings
        and post_reset_ok
        else "fail"
    )
    return {
        "scenario": "cancel",
        "verdict": verdict,
        "reserve_cycles": cycles_done,
        "leaked_estimate": leaked_estimate,
        "budget": H3_REQUEST_BODY_BUDGET,
        "cancelled": int(bool(cancelled.get("cancelled"))),
        "was_inflight": int(bool(cancelled.get("was_inflight"))),
        "siblings_outstanding_at_reset": siblings_outstanding,
        "sibling_ok": sibling_ok,
        "sibling_fail": siblings - sibling_ok,
        "post_reset_ok": int(post_reset_ok),
        "elapsed_ms": elapsed_ms,
        "siblings": siblings,
    }


async def run_loss(
    url: str, clients: int, streams: int, drop_rate: float, duration_s: float
) -> dict:
    """Sustained GET load with client-side outbound datagram drops."""
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    path = (parsed.path or "/").encode()
    authority = f"{host}:{port}".encode()

    latencies: List[float] = []
    counters = {"ok": 0, "failed": 0, "dropped": 0, "sent": 0}
    stop_at = time.perf_counter() + duration_s

    def factory(*args, **kwargs):
        return ScenarioProtocol(*args, drop_rate=drop_rate, **kwargs)

    async def one_conn() -> None:
        configuration = QuicConfiguration(
            is_client=True,
            alpn_protocols=H3_ALPN,
            server_name="localhost",
        )
        configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
        configuration.verify_mode = ssl.CERT_NONE
        async with connect(
            host,
            port,
            configuration=configuration,
            create_protocol=factory,
        ) as client:
            assert isinstance(client, ScenarioProtocol)
            await _wait_alpn(client)
            sem = asyncio.Semaphore(streams)
            conn_ok = 0

            async def one_request() -> None:
                nonlocal conn_ok
                async with sem:
                    try:
                        result = await asyncio.wait_for(
                            client.get(path, authority), timeout=10.0
                        )
                    except Exception:
                        counters["failed"] += 1
                        return
                    if result.get("status") == b"200":
                        done_at = result["done_at"] or time.perf_counter()
                        # Exclude completions after the measurement window:
                        # req_s divides by duration_s, so late successes
                        # would inflate throughput and contaminate percentiles.
                        if done_at > stop_at:
                            counters["late"] = counters.get("late", 0) + 1
                            return
                        # Same payload check as the main H3 loader: a 200
                        # with a wrong body is not a valid measurement.
                        if bytes(result["body"]) != FIXED_BODY:
                            counters["failed"] += 1
                            return
                        counters["ok"] += 1
                        conn_ok += 1
                        latencies.append((done_at - result["start"]) * 1_000_000.0)
                    else:
                        counters["failed"] += 1

            workers = []

            async def worker() -> None:
                while time.perf_counter() < stop_at:
                    await one_request()

            for _ in range(streams):
                workers.append(asyncio.create_task(worker()))
            await asyncio.gather(*workers)
            # A connection whose handshake finished after stop_at issues no
            # request at all; count it so a short run cannot report fewer
            # effective clients than requested and still pass.
            if conn_ok == 0:
                counters["failed"] += 1
            counters["dropped"] += client.dropped
            counters["sent"] += client.sent

    await asyncio.gather(*[one_conn() for _ in range(clients)])
    measure_s = max(1e-9, duration_s)
    latencies.sort()
    p50 = latencies[int(0.50 * (len(latencies) - 1))] if latencies else float(
        "nan"
    )
    p99 = latencies[int(0.99 * (len(latencies) - 1))] if latencies else float(
        "nan"
    )
    req_s = counters["ok"] / measure_s
    # QUIC recovers from dropped datagrams via retransmission, so a valid
    # loss run completes requests with no request or connection failures.
    # Partial runs (timeouts / non-200) must not be presented as a pass.
    verdict = (
        "pass"
        if counters["ok"] > 0
        and counters["failed"] == 0
        and (drop_rate == 0 or counters["dropped"] > 0)
        else "fail"
    )
    return {
        "scenario": "loss",
        "verdict": verdict,
        "drop_rate": drop_rate,
        "req_s": req_s,
        "ok": counters["ok"],
        "failed": counters["failed"],
        "dropped": counters["dropped"],
        "sent": counters["sent"],
        "p50_us": p50,
        "p99_us": p99,
        "clients": clients,
        "streams": streams,
        "duration_s": duration_s,
    }


def _print_result(stats: dict) -> None:
    parts = [f"{k}={v}" for k, v in stats.items()]
    print(" ".join(parts))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument(
        "--scenario",
        required=True,
        choices=("slow", "cancel", "loss"),
    )
    parser.add_argument("--slow-s", type=float, default=0.25)
    parser.add_argument("--siblings", type=int, default=8)
    parser.add_argument("--clients", type=int, default=4)
    parser.add_argument("--streams", type=int, default=4)
    parser.add_argument("--drop-rate", type=float, default=0.05)
    parser.add_argument("--duration", type=float, default=5.0)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    random.seed(args.seed)

    if args.scenario == "slow":
        stats = asyncio.run(run_slow(args.url, args.slow_s, args.siblings))
    elif args.scenario == "cancel":
        stats = asyncio.run(run_cancel(args.url, args.siblings))
    else:
        stats = asyncio.run(
            run_loss(
                args.url,
                args.clients,
                args.streams,
                args.drop_rate,
                args.duration,
            )
        )
    _print_result(stats)
    if stats.get("verdict") != "pass":
        sys.exit(1)


if __name__ == "__main__":
    main()
