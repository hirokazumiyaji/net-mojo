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
           under withheld stream credit (queued response), while siblings
           complete, then verify the connection still admits a full echo

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
import sys
import time
from typing import Dict, List, Optional
from urllib.parse import urlparse

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

# Headroom on the connection-level receive window. Slow-scenario siblings are
# tiny /fixed bodies; cancel-scenario siblings are full echo responses under
# per-stream withhold. Raising the connection window once keeps stream-level
# withholding from exhausting the shared connection window.
CONN_WINDOW = 8 * ECHO_BODY_LEN

# Per-request wall-clock budget. The scenarios are sub-second on loopback;
# anything slower means the server is not making progress.
REQUEST_TIMEOUT_S = 30.0

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

    def pump(self, deadline: float) -> None:
        """Process inbound frames until the peer goes idle or time runs out.

        The recv timeout is a short poll, not the remaining budget: this must
        return promptly so a caller can react to stream state, and so a
        silent peer cannot hold the scenario open until the server's own
        request-body deadline closes the target stream.
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
                self.pump(deadline)
                self._flush()
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

    def get(self, path: bytes = FIXED_PATH) -> int:
        stream_id = self._conn.get_next_available_stream_id()
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
    return sock


def _target_and_siblings(
    client: H2ScenarioClient, siblings: int, deadline: float
) -> tuple[int, List[int], bytes]:
    """Open the held upload, then dispatch the siblings immediately.

    Both live on the same connection, and no await happens between them, so
    the siblings are in flight while the target is still unfinished.
    """
    body = b"y" * ECHO_BODY_LEN
    target = client.open_upload(
        ECHO_BODY_LEN, body[:ECHO_PREFIX_LEN], deadline
    )
    sib_ids = [client.get() for _ in range(siblings)]
    return target, sib_ids, body


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
        target, sib_ids, body = _target_and_siblings(
            client, siblings, deadline
        )
        siblings_done = client.wait_siblings(sib_ids, deadline)
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
    }


def run_cancel(url: str, siblings: int) -> dict:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    authority = f"{host}:{port}".encode()

    t0 = time.perf_counter()
    body = b"y" * ECHO_BODY_LEN
    with connect_h2(host, port, REQUEST_TIMEOUT_S) as sock:
        client = H2ScenarioClient(sock, authority)
        deadline = time.perf_counter() + REQUEST_TIMEOUT_S
        # Target must have a queued mid-response when RST_STREAM fires.
        # An incomplete upload never reaches the response scheduler, so it
        # cannot exercise "RST_STREAM cancels the corresponding queued
        # response and releases its buffer reservation"
        # (docs/design/http2-server.md). Finish the request, withhold stream
        # credit until some DATA arrives, then reset that stalled response.
        target = client.post_echo(body, deadline, withhold=True)
        target_blocked = client.wait_flow_blocked([target], deadline)
        target_bytes_at_reset = len(client.body(target))
        # Siblings share the connection while the target response is stalled.
        sib_ids = [client.get() for _ in range(siblings)]
        reset_sent = False
        if target_blocked and client.response_blocked(target):
            client.reset(target)
            client.abandon(target)
            reset_sent = True
        siblings_done = client.wait_siblings(sib_ids, deadline)
        # RFC 7540 5.1: the receiver of RST_STREAM may answer with its own
        # RST_STREAM but need not, so this is recorded, not required.
        peer_reset = client.resets.get(target)
        # Prove admission/reservation was released: another full-size echo
        # must be accepted and completed on the same connection.
        reuse_id = client.post_echo(body, deadline, withhold=False)
        reuse_done = client.wait_stream(reuse_id, deadline)
        reuse_ok = reuse_done and client.echo_ok(reuse_id, body)
        # And a small GET still works afterwards.
        after_id = client.get()
        after_ok = client.wait_stream(after_id, deadline) and client.fixed_ok(
            after_id
        )
        terminated = client.terminated
    elapsed_ms = (time.perf_counter() - t0) * 1000

    sibling_ok = sum(1 for sid in sib_ids if client.fixed_ok(sid))
    verdict = (
        "pass"
        if target_blocked
        and target_bytes_at_reset > 0
        and reset_sent
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
        "target_response_blocked": int(target_blocked),
        "target_bytes_at_reset": target_bytes_at_reset,
        "reset_sent": int(reset_sent),
        "peer_reset_code": peer_reset,
        "sibling_ok": sibling_ok,
        "sibling_fail": siblings - sibling_ok,
        "reuse_echo_ok": int(reuse_ok),
        "post_reset_ok": int(after_ok),
        "elapsed_ms": elapsed_ms,
        "siblings": siblings,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--scenario", required=True, choices=("slow", "cancel"))
    parser.add_argument("--siblings", type=int, default=8)
    args = parser.parse_args()

    try:
        if args.scenario == "slow":
            stats = run_slow(args.url, args.siblings)
        else:
            stats = run_cancel(args.url, args.siblings)
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
