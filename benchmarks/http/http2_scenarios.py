#!/usr/bin/env python3
"""HTTP/2 special scenarios for Issue #42 PR 11 multiplex matrix.

Both scenarios drive the target stream and its siblings over a *single*
HTTP/2 connection, which is the property the matrix is meant to measure: a
server that serializes streams per connection, or that mishandles
RST_STREAM, cannot pass here. curl and h2load run as separate processes and
therefore always use separate connections, so they can only measure
aggregate throughput; h2load is still used for the throughput matrix and
this driver covers the multiplexing cases.

Scenarios:
  slow   — hold one large POST /echo upload open while N GET /fixed siblings
           run on the same connection, then release it
  cancel — RST_STREAM a target whose large POST /echo response is mid-flight
           under withheld stream credit, while sibling echoes stay
           flow-control-blocked across the reset; burn Mojo's buffer budget
           with repeated cancel cycles, then require a full echo reuse

The slow case is a deterministic version of the earlier `--limit-rate`
upload: the target stream's request body is deliberately left incomplete, so
the server is waiting on that stream and must keep serving the others. The
receive credit for the target's response is also withheld (the connection
window is raised once so this cannot starve the siblings), which would cap
any early response at a single stream window.

Usage:
  pixi run -e tls-http2 python benchmarks/http/http2_scenarios.py \\
    --url https://127.0.0.1:18443/fixed --scenario slow
"""

from __future__ import annotations

import argparse
import socket
import ssl
import statistics
import sys
import threading
import time
from typing import Dict, List, Optional
from urllib.parse import urlparse

from sibling_metrics import begin_sibling_window, sibling_metrics

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.errors import ErrorCodes
from h2.events import (
    ConnectionTerminated,
    DataReceived,
    ResponseReceived,
    SettingsAcknowledged,
    StreamEnded,
    StreamReset,
    TrailersReceived,
    WindowUpdated,
)
from h2.exceptions import FlowControlError, H2Error

# RST_STREAM code for a stream the client no longer needs (RFC 7540 8.1).
CANCEL = int(ErrorCodes.CANCEL)

# Expected /fixed response, matching the Go and Mojo H2 handlers.
FIXED_PATH = b"/fixed"
FIXED_BODY = b"a" * 64

# Large enough that the echo response cannot fit in the initial 64 KiB
# per-stream window, so withholding credit is observable.
ECHO_BODY_LEN = 1 << 20
ECHO_PREFIX_LEN = 32 * 1024

# Headroom on the connection-level receive window. Cancel opens several
# FC-blocked 1 MiB echoes at once (target + siblings), so the connection
# window must cover many initial per-stream windows without stalling.
CONN_WINDOW = 32 * ECHO_BODY_LEN

# Per-request wall-clock budget for slow. Cancel burns Mojo's buffer budget
# with repeated RST cycles and needs a longer ceiling.
REQUEST_TIMEOUT_S = 30.0
CANCEL_TIMEOUT_S = 300.0

# Mojo H2 defaults from net/http/config.mojo — used to size the cancel
# capacity-release proof. Go has no such budget; the extra cycles are
# harmless there and still fail a server that pins cancelled reservations.
H2_TOTAL_BUFFER_BUDGET = 268435456
# Default peer initial stream window. Cancel waits until the response is
# FC-blocked here; the normal drain path releases those sent bytes, so only
# the unsent residual can leak if RST forgets to free the reservation.
INITIAL_STREAM_WINDOW = 65535
# Stay under http2_max_resets_per_second (100): a correct Mojo server
# GOAWAYs with ENHANCE_YOUR_CALM above this rate
# (docs/design/http2-server.md).
H2_MAX_RESETS_PER_SECOND = 100
RESET_BUDGET_PER_WINDOW = H2_MAX_RESETS_PER_SECOND - 10

# Default SETTINGS_MAX_FRAME_SIZE. Uploads are split into frames of this
# size so neither scenario depends on a larger negotiated frame size.
MAX_FRAME_PAYLOAD = 16384

# Socket poll interval. pump() returns as soon as the peer stops sending, so
# a long recv timeout would stall the scenario until the server's own body
# read deadline expired and closed the target stream.
POLL_INTERVAL_S = 0.05


class ScenarioError(RuntimeError):
    """Protocol-level failure; reported as verdict=fail."""


class H2ScenarioClient:
    """One TLS+h2 connection carrying a target stream plus its siblings.

    Streams listed in `withheld` never get their received DATA
    acknowledged, so the server's per-stream send window closes and it
    stalls on that stream while the rest of the connection keeps running.
    """

    def __init__(self, sock: ssl.SSLSocket, authority: bytes) -> None:
        self._sock = sock
        self._authority = authority
        self._conn = H2Connection(
            config=H2Configuration(client_side=True, header_encoding=None)
        )
        # Raise the connection window once; per-stream windows stay at their
        # initial value so withholding one stream's credit is enough.
        # The preface has to go out before any frame that refers to stream 0,
        # so initiate first and raise the connection window afterwards.
        self._conn.initiate_connection()
        self._conn.increment_flow_control_window(CONN_WINDOW - 65535)
        self._flush()
        self.withheld: set[int] = set()
        self.responses: Dict[int, dict] = {}
        self.resets: Dict[int, int] = {}
        self.terminated: Optional[str] = None
        self.received = 0

    # --- transport ---

    def _flush(self) -> None:
        data = self._conn.data_to_send()
        if data:
            self._sock.sendall(data)

    def pump(
        self, deadline: float, *, credit_for: Optional[tuple[int, int]] = None
    ) -> None:
        """Process inbound frames until the peer goes idle or time runs out.

        The recv timeout is a short poll, not the remaining budget: this must
        return promptly so a caller can react to stream state, and so a
        silent peer cannot hold the scenario open until the server's own
        request-body deadline closes the target stream.

        Upload waits return when the next frame fits, so small receive
        windows do not add an idle poll to every upload batch.
        """
        while time.perf_counter() < deadline:
            remaining = deadline - time.perf_counter()
            self._sock.settimeout(min(POLL_INTERVAL_S, max(0.0, remaining)))
            try:
                chunk = self._sock.recv(65536)
            except (socket.timeout, ssl.SSLWantReadError):
                break
            if not chunk:
                self.terminated = "connection closed by peer"
                break
            self.received += len(chunk)
            self._handle(self._conn.receive_data(chunk))
            self._flush()
            if credit_for is not None:
                stream_id, size = credit_for
                if self._conn.local_flow_control_window(stream_id) >= size:
                    return

    def _handle(self, events) -> None:
        for event in events:
            if isinstance(event, ConnectionTerminated):
                # error_code 0 is a clean GOAWAY; anything else is a failure.
                self.terminated = (
                    "GOAWAY"
                    if event.error_code == 0
                    else f"GOAWAY error_code={event.error_code}"
                )
            elif isinstance(event, ResponseReceived):
                headers = dict(event.headers)
                record = self.responses.setdefault(
                    event.stream_id,
                    {"status": None, "body": bytearray(), "ended": False},
                )
                record["status"] = headers.get(b":status")
            elif isinstance(event, DataReceived):
                record = self.responses.setdefault(
                    event.stream_id,
                    {"status": None, "body": bytearray(), "ended": False},
                )
                record["body"].extend(event.data)
                if event.stream_id not in self.withheld:
                    # Siblings hand their credit straight back; the target
                    # keeps its window closed, which is the slow consumer.
                    self._conn.acknowledge_received_data(
                        event.flow_controlled_length, event.stream_id
                    )
            elif isinstance(event, StreamEnded):
                record = self.responses.setdefault(
                    event.stream_id,
                    {"status": None, "body": bytearray(), "ended": False},
                )
                record["done_at"] = time.perf_counter()
                record["ended"] = True
                if event.stream_id in self.withheld:
                    self._conn.acknowledge_received_data(0, event.stream_id)
            elif isinstance(event, StreamReset):
                self.resets[event.stream_id] = event.error_code
            elif isinstance(event, TrailersReceived):
                pass
            elif isinstance(event, (SettingsAcknowledged, WindowUpdated)):
                pass

    # --- request helpers ---

    def open_upload(self, body_len: int, prefix: bytes, deadline: float) -> int:
        """Start a POST /echo whose request body is deliberately unfinished."""
        stream_id = self._conn.get_next_available_stream_id()
        self.withheld.add(stream_id)
        self._conn.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", self._authority),
                (b":path", b"/echo"),
                (b"content-length", str(body_len).encode()),
            ],
            end_stream=False,
        )
        self._send_body(stream_id, prefix, 0, end_stream=False, deadline=deadline)
        self._flush()
        return stream_id

    def _send_body(
        self,
        stream_id: int,
        body: bytes,
        start: int,
        *,
        end_stream: bool,
        deadline: float,
    ) -> None:
        """Send body[start:] as DATA frames, respecting the send window.

        The server's receive window is usually smaller than the 1 MiB echo
        body, so a chunk that does not fit is retried after pumping for the
        WINDOW_UPDATE that grants the credit.
        """
        off = start
        while off < len(body):
            size = min(MAX_FRAME_PAYLOAD, len(body) - off)
            chunk = body[off : off + size]
            last = off + size >= len(body)
            try:
                self._conn.send_data(
                    stream_id, chunk, end_stream=end_stream and last
                )
            except FlowControlError:
                if time.perf_counter() >= deadline:
                    raise ScenarioError(
                        f"upload stalled at offset {off}: no WINDOW_UPDATE"
                    )
                self._flush()
                self.pump(deadline, credit_for=(stream_id, size))
                continue
            off += size
        self._flush()

    def finish_upload(
        self, stream_id: int, body: bytes, sent: int, deadline: float
    ) -> None:
        """Send the rest of the request body and close the request side."""
        self._send_body(
            stream_id, body, sent, end_stream=True, deadline=deadline
        )

    def release(self, stream_id: int) -> None:
        """Hand back the withheld credit so the target stream can finish."""
        record = self.responses.get(stream_id)
        held = len(record["body"]) if record else 0
        if held:
            self._conn.acknowledge_received_data(held, stream_id)
        self.withheld.discard(stream_id)
        self._flush()

    def abandon(self, stream_id: int) -> None:
        """Drop local interest after RST_STREAM without returning window credit."""
        self.withheld.discard(stream_id)

    def _start_response(self, stream_id: int) -> None:
        self.responses[stream_id] = {
            "status": None, "body": bytearray(), "ended": False,
            "start": time.perf_counter(), "done_at": None,
        }

    def get(self, path: bytes = FIXED_PATH) -> int:
        stream_id = self._conn.get_next_available_stream_id()
        self._start_response(stream_id)
        self._conn.send_headers(
            stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", self._authority),
                (b":path", path),
            ],
            end_stream=True,
        )
        self._flush()
        return stream_id

    def post_echo(
        self, body: bytes, deadline: float, *, withhold: bool = False
    ) -> int:
        """POST /echo with a finished request body.

        When withhold is set, response DATA is not acknowledged so a body
        larger than the initial per-stream window stalls mid-response.
        """
        stream_id = self._conn.get_next_available_stream_id()
        self._start_response(stream_id)
        if withhold:
            self.withheld.add(stream_id)
        self._conn.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", self._authority),
                (b":path", b"/echo"),
                (b"content-length", str(len(body)).encode()),
            ],
            end_stream=False,
        )
        self._send_body(
            stream_id, body, 0, end_stream=True, deadline=deadline
        )
        return stream_id

    def reset(self, stream_id: int) -> None:
        """Reset only the target stream; siblings and the connection stay."""
        self._conn.reset_stream(stream_id, error_code=CANCEL)
        self._flush()

    # --- inspection ---

    def open_streams(self, exclude: int) -> int:
        try:
            return sum(
                1
                for sid, stream in self._conn.streams.items()
                if sid != exclude and stream.open
            )
        except H2Error:
            return 0

    def ended(self, stream_id: int) -> bool:
        record = self.responses.get(stream_id)
        return bool(record and record["ended"])

    def body(self, stream_id: int) -> bytes:
        record = self.responses.get(stream_id)
        return bytes(record["body"]) if record else b""

    def status(self, stream_id: int) -> Optional[bytes]:
        record = self.responses.get(stream_id)
        return record["status"] if record else None

    def fixed_ok(self, stream_id: int) -> bool:
        """A sibling counts only with HTTP/2 200 and the exact fixture body."""
        return self.status(stream_id) == b"200" and self.body(
            stream_id
        ) == FIXED_BODY

    def echo_ok(self, stream_id: int, body: bytes) -> bool:
        return self.status(stream_id) == b"200" and self.body(stream_id) == body

    def response_blocked(self, stream_id: int) -> bool:
        """True when some DATA arrived but StreamEnded has not — FC stall."""
        return (not self.ended(stream_id)) and len(self.body(stream_id)) > 0

    def wait_siblings(
        self, siblings: List[int], deadline: float
    ) -> bool:
        """Pump until every sibling stream ended."""
        while time.perf_counter() < deadline:
            if all(self.ended(sid) for sid in siblings):
                return True
            self.pump(deadline)
        return all(self.ended(sid) for sid in siblings)

    def wait_flow_blocked(
        self, stream_ids: List[int], deadline: float
    ) -> bool:
        """Pump until every stream has a partial, non-ended response body."""
        while time.perf_counter() < deadline:
            if all(self.response_blocked(sid) for sid in stream_ids):
                return True
            self.pump(deadline)
        return all(self.response_blocked(sid) for sid in stream_ids)

    def wait_stream(self, stream_id: int, deadline: float) -> bool:
        while time.perf_counter() < deadline:
            if self.ended(stream_id):
                return True
            self.pump(deadline)
        return self.ended(stream_id)


def connect_h2(host: str, port: int, timeout: float) -> ssl.SSLSocket:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2"])
    raw = socket.create_connection((host, port), timeout=timeout)
    sock = context.wrap_socket(raw, server_hostname="localhost")
    if sock.selected_alpn_protocol() != "h2":
        sock.close()
        raise ScenarioError("server did not negotiate h2")
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


# Churn mode: open a fresh TLS+h2 connection per request. No session
# resumption client-side because every connect uses a new SSLContext with
# an empty session cache.
CHURN_REQUEST_TIMEOUT_S = 10.0


def churn_one_request(
    host: str, port: int, authority: bytes
) -> tuple[bool, float, Optional[str]]:
    """Open a new TLS+h2 connection, send GET /fixed, read the body.

    Returns (ok, elapsed_s, tls_info). tls_info is set on the first
    successful connection and is ``alpn/version/cipher``.
    """
    begin = time.perf_counter()
    try:
        sock = connect_h2(host, port, CHURN_REQUEST_TIMEOUT_S)
    except (OSError, ssl.SSLError, ScenarioError):
        return False, time.perf_counter() - begin, None
    tls_info = (
        f"{sock.selected_alpn_protocol()}/{sock.version()}/{sock.cipher()[0]}"
        if sock.cipher() is not None
        else f"{sock.selected_alpn_protocol()}/{sock.version()}/"
    )
    try:
        client = H2ScenarioClient(sock, authority)
        deadline = time.perf_counter() + CHURN_REQUEST_TIMEOUT_S
        stream_id = client.get(FIXED_PATH)
        if not client.wait_stream(stream_id, deadline):
            return False, time.perf_counter() - begin, tls_info
        if not client.fixed_ok(stream_id):
            return False, time.perf_counter() - begin, tls_info
        return True, time.perf_counter() - begin, tls_info
    except (H2Error, OSError, ssl.SSLError, ScenarioError):
        return False, time.perf_counter() - begin, tls_info
    finally:
        try:
            sock.close()
        except OSError:
            pass


def run_churn(
    url: str, clients: int, warmup_s: float, duration_s: float
) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    authority = f"{host}:{port}".encode()
    if clients < 1:
        raise ScenarioError(f"--clients must be >= 1, got {clients}")

    latencies: List[float] = []
    counters = {
        "ok": 0,
        "failed": 0,
        "warmup_ok": 0,
        "warmup_failed": 0,
        "late": 0,
        "late_failed": 0,
    }
    tls_info: List[Optional[str]] = [None]
    lock = threading.Lock()

    anchor_before = time.perf_counter()
    anchor_unix_s = time.time()
    start = time.perf_counter()
    anchor_span_s = start - anchor_before
    load_start_unix_s = anchor_unix_s + anchor_span_s / 2
    warmup_until = start + warmup_s
    stop_at = warmup_until + duration_s

    def worker() -> None:
        while time.perf_counter() < stop_at:
            ok, elapsed, info = churn_one_request(host, port, authority)
            done_at = time.perf_counter()
            with lock:
                if info is not None and tls_info[0] is None:
                    tls_info[0] = info
                if done_at > stop_at:
                    if ok:
                        counters["late"] += 1
                    else:
                        counters["late_failed"] += 1
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
                        counters["warmup_failed"] += 1

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(clients)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    latencies.sort()
    measure_s = max(1e-9, duration_s)
    req_s = counters["ok"] / measure_s

    def _p(values: List[float], p: float) -> float:
        if not values:
            return float("nan")
        idx = max(0, min(len(values) - 1, int(round((p / 100.0) * (len(values) - 1)))))
        return values[idx]

    return {
        "scenario": "churn",
        "verdict": "pass" if counters["failed"] == 0 and counters["ok"] > 0 else "fail",
        "req_s": req_s,
        "ok": counters["ok"],
        "failed": counters["failed"],
        "warmup_successes": counters["warmup_ok"],
        "warmup_failed": counters["warmup_failed"],
        "late": counters["late"],
        "late_failed": counters["late_failed"],
        "samples": len(latencies),
        "p50_us": _p(latencies, 50),
        "p95_us": _p(latencies, 95),
        "p99_us": _p(latencies, 99),
        "mean_us": statistics.fmean(latencies) if latencies else float("nan"),
        "load_start_unix_s": load_start_unix_s,
        "measurement_start_unix_s": load_start_unix_s + warmup_s,
        "measurement_end_unix_s": load_start_unix_s + warmup_s + duration_s,
        "clients": clients,
        "tls_info": tls_info[0] or "",
    }


def _target_and_siblings(
    client: H2ScenarioClient, siblings: int, deadline: float
) -> tuple[int, List[int], bytes, tuple]:
    """Open the held upload, then dispatch the siblings immediately.

    Both live on the same connection, and no await happens between them, so
    the siblings are in flight while the target is still unfinished.
    """
    body = b"y" * ECHO_BODY_LEN
    target = client.open_upload(
        ECHO_BODY_LEN, body[:ECHO_PREFIX_LEN], deadline
    )
    window = begin_sibling_window()
    sib_ids = [client.get() for _ in range(siblings)]
    return target, sib_ids, body, window


def run_slow(url: str, siblings: int) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    path = (parsed.path or "/").encode()
    authority = f"{host}:{port}".encode()

    t0 = time.perf_counter()
    with connect_h2(host, port, REQUEST_TIMEOUT_S) as sock:
        client = H2ScenarioClient(sock, authority)
        deadline = time.perf_counter() + REQUEST_TIMEOUT_S
        target, sib_ids, body, window = _target_and_siblings(
            client, siblings, deadline
        )
        siblings_done = client.wait_siblings(sib_ids, deadline)
        metrics = sibling_metrics(
            (client.responses.get(sid) for sid in sib_ids),
            lambda record: record["status"] == b"200" and bytes(record["body"]) == FIXED_BODY,
            window, time.perf_counter(),
        )
        # The target must still be incomplete at sibling completion: a
        # server that serialized (or answered) it first cannot pass.
        target_unfinished = not client.ended(target)
        target_bytes_while_held = len(client.body(target))
        target_siblings_outstanding = siblings_done
        # Release the slow consumer and let the upload finish.
        client.release(target)
        client.finish_upload(target, body, ECHO_PREFIX_LEN, deadline)
        target_done = client.wait_stream(target, deadline)
        target_ok = client.status(target) == b"200"
        target_body_ok = client.body(target) == body
        terminated = client.terminated
    elapsed_ms = (time.perf_counter() - t0) * 1000

    sibling_ok = sum(1 for sid in sib_ids if client.fixed_ok(sid))
    # A server that only answers once the whole request body has arrived (both
    # the Go and Mojo handlers do) sends no response bytes at all while the
    # upload is held, so target_bytes_while_held is reported rather than
    # required; the load-bearing condition is that the target had not ended
    # when the siblings were served. The withheld credit is still in force
    # for a server that answers early, and would cap it at one stream window.
    verdict = (
        "pass"
        if siblings_done
        and sibling_ok == siblings
        and target_unfinished
        and target_siblings_outstanding
        and target_done
        and target_ok
        and target_body_ok
        and terminated is None
        else "fail"
    )
    return {
        "scenario": "slow",
        "verdict": verdict,
        "conn": "single",
        "sibling_ok": sibling_ok,
        "sibling_fail": siblings - sibling_ok,
        "target_unfinished_during_siblings": int(target_unfinished),
        "target_bytes_while_held": target_bytes_while_held,
        "target_ok": int(target_ok),
        "target_body_ok": int(target_body_ok),
        "elapsed_ms": elapsed_ms,
        "siblings": siblings,
        **metrics,
    }


def run_cancel(url: str, siblings: int) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    authority = f"{host}:{port}".encode()

    t0 = time.perf_counter()
    body = b"y" * ECHO_BODY_LEN
    with connect_h2(host, port, CANCEL_TIMEOUT_S) as sock:
        client = H2ScenarioClient(sock, authority)
        deadline = time.perf_counter() + CANCEL_TIMEOUT_S
        # Phase 1: burn reserved capacity from the *unsent* residual. Each
        # cycle waits until the initial stream window has drained; those
        # sent bytes are released by the normal path (server.mojo drain).
        # A cancel that frees the stream but leaves the queued remainder
        # charged therefore leaks about (echo - window) per cycle — size
        # the burn from that residual until it would exceed the budget.
        # Pace RST_STREAM below Mojo's http2_max_resets_per_second so a
        # correct flood defense does not GOAWAY before the release check.
        cycles_done = 0
        leaked_estimate = 0
        reset_window_start = time.perf_counter()
        resets_in_window = 0
        while leaked_estimate <= H2_TOTAL_BUFFER_BUDGET:
            if time.perf_counter() >= deadline:
                break
            tid = client.post_echo(body, deadline, withhold=True)
            if not client.wait_flow_blocked([tid], deadline):
                break
            sent = len(client.body(tid))
            client.reset(tid)
            client.abandon(tid)
            leaked_estimate += max(0, ECHO_BODY_LEN - sent)
            cycles_done += 1
            resets_in_window += 1
            if resets_in_window >= RESET_BUDGET_PER_WINDOW:
                remaining = 1.0 - (time.perf_counter() - reset_window_start)
                if remaining > 0:
                    time.sleep(remaining)
                reset_window_start = time.perf_counter()
                resets_in_window = 0
            if client.terminated is not None:
                break

        # Phase 2: RST a queued mid-response while siblings are also
        # FC-blocked, then release siblings only after the reset.
        window = begin_sibling_window()
        target = client.post_echo(body, deadline, withhold=True)
        target_blocked = client.wait_flow_blocked([target], deadline)
        target_bytes_at_reset = len(client.body(target))
        sib_ids = [
            client.post_echo(body, deadline, withhold=True)
            for _ in range(siblings)
        ]
        siblings_blocked = client.wait_flow_blocked(sib_ids, deadline)
        reset_sent = False
        if (
            target_blocked
            and siblings_blocked
            and client.response_blocked(target)
            and all(client.response_blocked(sid) for sid in sib_ids)
        ):
            client.reset(target)
            client.abandon(target)
            reset_sent = True
        # Siblings must still be incomplete after the server processes RST.
        siblings_blocked_after_reset = all(
            client.response_blocked(sid) for sid in sib_ids
        )
        for sid in sib_ids:
            client.release(sid)
        siblings_done = client.wait_siblings(sib_ids, deadline)
        metrics = sibling_metrics(
            (client.responses.get(sid) for sid in sib_ids),
            lambda record: record["status"] == b"200" and bytes(record["body"]) == body,
            window, time.perf_counter(),
        )
        # RFC 7540 5.1: the receiver of RST_STREAM may answer with its own
        # RST_STREAM but need not, so this is recorded, not required.
        peer_reset = client.resets.get(target)
        # Phase 3: after burning the budget with cancels, a full echo and a
        # GET must still be admitted — reservation must have been released.
        reuse_id = client.post_echo(body, deadline, withhold=False)
        reuse_done = client.wait_stream(reuse_id, deadline)
        reuse_ok = reuse_done and client.echo_ok(reuse_id, body)
        after_id = client.get()
        after_ok = client.wait_stream(after_id, deadline) and client.fixed_ok(
            after_id
        )
        terminated = client.terminated
    elapsed_ms = (time.perf_counter() - t0) * 1000

    sibling_ok = sum(1 for sid in sib_ids if client.echo_ok(sid, body))
    verdict = (
        "pass"
        if leaked_estimate > H2_TOTAL_BUFFER_BUDGET
        and target_blocked
        and target_bytes_at_reset > 0
        and siblings_blocked
        and reset_sent
        and siblings_blocked_after_reset
        and siblings_done
        and sibling_ok == siblings
        and reuse_ok
        and after_ok
        and terminated is None
        else "fail"
    )
    return {
        "scenario": "cancel",
        "verdict": verdict,
        "conn": "single",
        "reserve_cycles": cycles_done,
        "leaked_estimate": leaked_estimate,
        "budget": H2_TOTAL_BUFFER_BUDGET,
        "target_response_blocked": int(target_blocked),
        "target_bytes_at_reset": target_bytes_at_reset,
        "siblings_blocked_at_reset": int(siblings_blocked),
        "siblings_blocked_after_reset": int(siblings_blocked_after_reset),
        "reset_sent": int(reset_sent),
        "peer_reset_code": peer_reset,
        "sibling_ok": sibling_ok,
        "sibling_fail": siblings - sibling_ok,
        "reuse_echo_ok": int(reuse_ok),
        "post_reset_ok": int(after_ok),
        "elapsed_ms": elapsed_ms,
        "siblings": siblings,
        **metrics,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument(
        "--scenario", required=True, choices=("slow", "cancel", "churn")
    )
    parser.add_argument("--siblings", type=int, default=8)
    parser.add_argument(
        "--clients", type=int, default=1,
        help="churn: concurrent workers (each opens a new TLS+h2 connection per request)",
    )
    parser.add_argument("--warmup", type=float, default=5.0, help="churn: warmup seconds")
    parser.add_argument("--duration", type=float, default=10.0, help="churn: measure seconds")
    args = parser.parse_args()

    try:
        if args.scenario == "slow":
            stats = run_slow(args.url, args.siblings)
        elif args.scenario == "cancel":
            stats = run_cancel(args.url, args.siblings)
        else:
            stats = run_churn(args.url, args.clients, args.warmup, args.duration)
    except (ScenarioError, H2Error, OSError) as exc:
        # A protocol or transport failure is a scenario failure, not a
        # harness crash: record it so the summary still explains the run.
        stats = {
            "scenario": args.scenario,
            "verdict": "fail",
            "conn": "single",
            "error": type(exc).__name__,
            "detail": str(exc)[:120],
        }

    print(" ".join(f"{k}={v}" for k, v in stats.items()))
    if stats.get("verdict") != "pass":
        sys.exit(1)


if __name__ == "__main__":
    main()
