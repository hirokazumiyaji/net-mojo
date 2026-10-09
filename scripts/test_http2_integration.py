#!/usr/bin/env python3
"""Issue #42 Phase 7: HTTP/2 integration-test gaps against the Mojo server.

Covers the audit items the existing suite does not reach: a request body
larger than the initial 65,535-byte stream window, a response body larger
than the initial window (flow control), a header block split with
CONTINUATION, a client RST_STREAM on one stream while a sibling finishes,
a flow-blocked stream that drains during a shutdown GOAWAY, a stalled
(zero-window) stream while a sibling progresses, client-sent GOAWAY, and
ALPN mismatches that must not downgrade to plaintext.  Afterwards the
fixture asserts active_connections() returned to zero (fd release)."""

from __future__ import annotations

import socket
import ssl
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.errors import ErrorCodes
from h2.events import (
    ConnectionTerminated,
    DataReceived,
    ResponseReceived,
    StreamEnded,
    StreamReset,
    TrailersReceived,
    WindowUpdated,
)
from h2.exceptions import FlowControlError


FIXTURE = ["mojo", "run", "--Werror", "-I", ".", "tests/http2_integration_fixture.mojo"]
TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.05
MAX_FRAME = 16384
INITIAL_WINDOW = 65535


def _h2_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["h2"])
    return ctx


def _assert(cond: bool, msg: str) -> None:
    if not cond:
        raise RuntimeError(msg)


class H2Peer:
    """A thin h2 driver for the server; one connection per test unless
    the test specifically requires sharing (e.g. sibling isolation)."""

    def __init__(self, port: int, *, raise_conn_window: int = 0):
        raw = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT_S)
        self._sock = _h2_context().wrap_socket(raw, server_hostname="localhost")
        if self._sock.selected_alpn_protocol() != "h2":
            raise RuntimeError("ALPN did not negotiate h2")
        self._conn = H2Connection(
            config=H2Configuration(client_side=True, header_encoding=None)
        )
        self._conn.initiate_connection()
        if raise_conn_window:
            self._conn.increment_flow_control_window(raise_conn_window)
        self._flush()
        self._streams: Dict[int, Dict] = {}
        self.terminated: Optional[int] = None
        self._withheld: set = set()
        self._pending_increments: Dict[int, int] = {}

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def _flush(self) -> None:
        data = self._conn.data_to_send()
        if data:
            self._sock.sendall(data)

    def send_raw(self, data: bytes) -> None:
        self._sock.sendall(data)

    def _handle(self, event) -> None:
        if isinstance(event, ResponseReceived):
            rec = self._record(event.stream_id)
            for name, value in event.headers:
                if name == b":status":
                    rec["status"] = int(value.decode())
                else:
                    rec["headers"].setdefault(name, []).append(value)
        elif isinstance(event, DataReceived):
            rec = self._record(event.stream_id)
            rec["body"].extend(event.data)
            if event.stream_id in self._withheld:
                return
            self._conn.acknowledge_received_data(
                event.flow_controlled_length, event.stream_id
            )
        elif isinstance(event, TrailersReceived):
            rec = self._record(event.stream_id)
            for name, value in event.headers:
                rec["trailers"].setdefault(name, []).append(value)
        elif isinstance(event, StreamEnded):
            self._record(event.stream_id)["ended"] = True
            if event.stream_id in self._withheld:
                # Release withheld credit on stream end so the peer's
                # connection window is restored for the next test.
                self._withheld.discard(event.stream_id)
        elif isinstance(event, StreamReset):
            rec = self._record(event.stream_id)
            rec["reset"] = int(event.error_code)
            rec["ended"] = True
        elif isinstance(event, ConnectionTerminated):
            self.terminated = int(event.error_code)
        elif isinstance(event, WindowUpdated):
            pass

    def _record(self, stream_id: int) -> Dict:
        return self._streams.setdefault(
            stream_id,
            {
                "status": None,
                "headers": {},
                "body": bytearray(),
                "trailers": {},
                "ended": False,
                "reset": None,
            },
        )

    def pump(self, deadline: float) -> None:
        self._sock.settimeout(min(POLL_INTERVAL_S, max(0.0, deadline - time.perf_counter())))
        try:
            chunk = self._sock.recv(65536)
        except (socket.timeout, ssl.SSLWantReadError):
            return
        if not chunk:
            self.terminated = self.terminated if self.terminated is not None else -1
            return
        for event in self._conn.receive_data(chunk):
            self._handle(event)
        self._flush()

    def wait_stream(self, stream_id: int, deadline: float) -> Dict:
        while time.perf_counter() < deadline:
            rec = self._streams.get(stream_id)
            if rec is not None and rec["ended"]:
                return rec
            self.pump(deadline)
            if self.terminated is not None:
                break
        rec = self._streams.get(stream_id)
        if rec is None:
            raise RuntimeError(f"stream {stream_id}: no response before deadline")
        if not rec["ended"]:
            raise RuntimeError(
                f"stream {stream_id}: no END_STREAM before deadline"
            )
        return rec

    def wait_terminated(self, deadline: float) -> None:
        while time.perf_counter() < deadline and self.terminated is None:
            self.pump(deadline)

    def wait_response_only(self, stream_id: int, deadline: float) -> Dict:
        while time.perf_counter() < deadline:
            rec = self._streams.get(stream_id)
            if rec is not None and rec["status"] is not None:
                return rec
            self.pump(deadline)
        rec = self._streams.get(stream_id)
        if rec is None:
            raise RuntimeError(
                f"stream {stream_id}: no response headers before deadline"
            )
        return rec

    def open_request(
        self,
        method: str,
        path: str,
        *,
        body: bytes = b"",
        withhold: bool = False,
        end_stream_on_headers: Optional[bool] = None,
    ) -> int:
        stream_id = self._conn.get_next_available_stream_id()
        if withhold:
            self._withheld.add(stream_id)
        headers = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", b"localhost"),
            (b":path", path.encode()),
        ]
        if body:
            headers.append((b"content-length", str(len(body)).encode()))
        if end_stream_on_headers is None:
            end_stream_on_headers = not body
        self._conn.send_headers(stream_id, headers, end_stream=end_stream_on_headers)
        if body:
            off = 0
            upload_deadline = time.perf_counter() + TIMEOUT_S
            while off < len(body):
                size = min(MAX_FRAME, len(body) - off)
                chunk = body[off : off + size]
                last = off + size >= len(body)
                try:
                    self._conn.send_data(
                        stream_id, chunk, end_stream=last
                    )
                except FlowControlError:
                    self._flush()
                    while (
                        self._conn.local_flow_control_window(stream_id) < size
                        and time.perf_counter() < upload_deadline
                    ):
                        self.pump(upload_deadline)
                    if (
                        self._conn.local_flow_control_window(stream_id) < size
                    ):
                        raise RuntimeError(
                            "upload stalled: peer stopped granting flow control credit"
                        )
                    continue
                off += size
        self._flush()
        return stream_id


# --- Test cases ---


def case_large_request_body(port: int) -> None:
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        body = bytes(((i * 7) & 0xFF) for i in range(96 * 1024))
        stream_id = peer.open_request("POST", "/echo", body=body)
        rec = peer.wait_stream(stream_id, time.perf_counter() + TIMEOUT_S)
        _assert(rec["status"] == 200, f"large req status {rec['status']}")
        _assert(rec["reset"] is None, f"large req reset {rec['reset']}")
        _assert(bytes(rec["body"]) == body, f"large req body mismatch len={len(rec['body'])}")
    finally:
        peer.close()


LARGE_RESPONSE_BODY = bytes((97 + i % 26) for i in range(128 * 1024))


def case_large_response_body(port: int) -> None:
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        stream_id = peer.open_request("GET", "/large")
        rec = peer.wait_stream(stream_id, time.perf_counter() + TIMEOUT_S)
        _assert(rec["status"] == 200, f"large resp status {rec['status']}")
        _assert(rec["reset"] is None, f"large resp reset {rec['reset']}")
        _assert(
            bytes(rec["body"]) == LARGE_RESPONSE_BODY,
            f"large resp body mismatch len={len(rec['body'])}",
        )
    finally:
        peer.close()


def case_continuation_header_block(port: int) -> None:
    """Split a request header block across HEADERS + CONTINUATION frames.

    The h2 library's client-side state machine refuses to accept a server
    response on a stream it never saw go out through `send_headers`, so
    this test bypasses the library entirely: raw TLS, raw preface, raw
    HPACK via the library's encoder, raw frame reader, raw HPACK decoder."""
    raw = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT_S)
    sock = _h2_context().wrap_socket(raw, server_hostname="localhost")
    try:
        # Preface + empty SETTINGS so the server can finish bootstrap.
        sock.sendall(
            b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            + b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
        )

        from hpack import Encoder, Decoder  # type: ignore[import-not-found]

        encoder = Encoder()
        padding_value = ("A" * 128).encode()
        extra_headers = [(f"x-pad-{i}".encode(), padding_value) for i in range(16)]
        request_headers = [
            (b":method", b"GET"),
            (b":scheme", b"https"),
            (b":authority", b"localhost"),
            (b":path", b"/sibling"),
            *extra_headers,
        ]
        encoded = encoder.encode(request_headers)

        def frame(frame_type: int, flags: int, stream: int, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(3, "big")
                + bytes([frame_type, flags])
                + stream.to_bytes(4, "big")
                + payload
            )

        chunk_size = max(1, len(encoded) // 4)
        pieces: List[bytes] = [
            encoded[off : off + chunk_size]
            for off in range(0, len(encoded), chunk_size)
        ]
        _assert(len(pieces) >= 2, f"continuation requires >=2 pieces (got {len(pieces)})")
        stream_id = 1
        wire = frame(0x01, 0x01, stream_id, pieces[0])  # HEADERS END_STREAM
        for mid in pieces[1:-1]:
            wire += frame(0x09, 0x00, stream_id, mid)
        wire += frame(0x09, 0x04, stream_id, pieces[-1])  # CONTINUATION END_HEADERS
        sock.sendall(wire)

        decoder = Decoder()
        got_status = None
        body = bytearray()
        got_end = False
        deadline = time.perf_counter() + TIMEOUT_S
        header = bytearray()
        while time.perf_counter() < deadline and not got_end:
            # Read a 9-byte frame header. Poll at POLL_INTERVAL_S but
            # keep retrying until the overall `deadline` so a healthy
            # server that pauses between frames does not fail the case.
            while len(header) < 9:
                remaining = max(0.0, deadline - time.perf_counter())
                if remaining <= 0:
                    raise RuntimeError("continuation deadline before header")
                sock.settimeout(min(POLL_INTERVAL_S, remaining))
                try:
                    chunk = sock.recv(9 - len(header))
                except (socket.timeout, ssl.SSLWantReadError):
                    continue
                if not chunk:
                    raise RuntimeError("connection closed during continuation test")
                header.extend(chunk)
            length = int.from_bytes(header[:3], "big")
            frame_type = header[3]
            flags = header[4]
            frame_stream = int.from_bytes(header[5:9], "big")
            payload = bytearray()
            while len(payload) < length:
                remaining = max(0.0, deadline - time.perf_counter())
                if remaining <= 0:
                    raise RuntimeError("continuation deadline mid-payload")
                sock.settimeout(min(POLL_INTERVAL_S, remaining))
                try:
                    chunk = sock.recv(length - len(payload))
                except (socket.timeout, ssl.SSLWantReadError):
                    continue
                if not chunk:
                    raise RuntimeError("connection closed mid-frame")
                payload.extend(chunk)
            header.clear()

            if frame_type == 0x04 and (flags & 0x01) == 0:
                # SETTINGS from server; ACK it.
                sock.sendall(b"\x00\x00\x00\x04\x01\x00\x00\x00\x00")
            elif frame_type == 0x04:
                pass
            elif frame_type == 0x08:
                # Server WINDOW_UPDATE; just ignore.
                pass
            elif frame_type == 0x01 and frame_stream == stream_id:
                decoded = decoder.decode(bytes(payload))
                for name, value in decoded:
                    if name == ":status":
                        got_status = int(value)
            elif frame_type == 0x00 and frame_stream == stream_id:
                body.extend(payload)
                if flags & 0x01:
                    got_end = True
            elif frame_type == 0x03 and frame_stream == stream_id:
                raise RuntimeError(
                    f"CONTINUATION stream was reset: code={int.from_bytes(payload[:4], 'big')}"
                )
            elif frame_type == 0x07:
                raise RuntimeError(
                    f"server GOAWAY during CONTINUATION test: payload={bytes(payload)!r}"
                )
        _assert(got_status == 200, f"CONTINUATION response status {got_status}")
        _assert(got_end, "CONTINUATION response never ended")
        _assert(bytes(body) == b"sibling ok", f"CONTINUATION response body {bytes(body)!r}")
    finally:
        try:
            sock.close()
        except OSError:
            pass


def case_rst_while_sibling_completes(port: int) -> None:
    """Open two streams; RST_STREAM the first mid-flight and verify the
    sibling completes on the same connection."""
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        rst_id = peer.open_request("GET", "/large")
        sib_id = peer.open_request("GET", "/sibling")
        peer._conn.reset_stream(rst_id, error_code=int(ErrorCodes.CANCEL))
        peer._flush()
        rec = peer.wait_stream(sib_id, time.perf_counter() + TIMEOUT_S)
        _assert(rec["status"] == 200, f"sibling after RST status {rec['status']}")
        _assert(rec["reset"] is None, f"sibling after RST unexpected reset {rec['reset']!r}")
        _assert(bytes(rec["body"]) == b"sibling ok", f"sibling body {rec['body']!r}")
        _assert(peer.terminated is None, "connection terminated after client RST")
    finally:
        peer.close()


def case_stalled_stream_sibling_progresses(port: int) -> None:
    """Open a GET /large with its response credit withheld (zero stream
    window) while a sibling GET /sibling runs to completion."""
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        stalled = peer.open_request("GET", "/large", withhold=True)
        # Spin pumping until the stalled response has filled its stream
        # window. If this never happens, the scenario was never set up
        # (a server that completes the sibling before starting /large
        # would otherwise silently pass).
        deadline = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < deadline:
            peer.pump(deadline)
            rec = peer._streams.get(stalled)
            if rec and len(rec["body"]) >= INITIAL_WINDOW:
                break
        rec = peer._streams.get(stalled) or {}
        _assert(
            len(rec.get("body") or b"") >= INITIAL_WINDOW,
            f"/large never filled its initial window: got {len(rec.get('body') or b'')}",
        )
        _assert(not rec.get("ended", False), "/large ended before sibling probe")
        sib_id = peer.open_request("GET", "/sibling")
        sib = peer.wait_stream(sib_id, time.perf_counter() + TIMEOUT_S)
        _assert(sib["status"] == 200, f"sibling status under stall {sib['status']}")
        _assert(sib["reset"] is None, f"sibling under stall unexpected reset {sib['reset']!r}")
        _assert(bytes(sib["body"]) == b"sibling ok", f"sibling body under stall {sib['body']!r}")
        _assert(peer.terminated is None, "connection terminated under stall")
        # Release withheld credit so stalled stream can finish.
        rec = peer._streams.setdefault(
            stalled,
            {"status": None, "headers": {}, "body": bytearray(),
             "trailers": {}, "ended": False, "reset": None},
        )
        held = len(rec["body"])
        if held:
            peer._conn.acknowledge_received_data(held, stalled)
        peer._withheld.discard(stalled)
        peer._flush()
        rec = peer.wait_stream(stalled, time.perf_counter() + TIMEOUT_S)
        _assert(rec["status"] == 200, f"stalled stream status after release {rec['status']}")
        _assert(rec["reset"] is None, f"stalled stream reset after release {rec['reset']!r}")
        _assert(
            bytes(rec["body"]) == LARGE_RESPONSE_BODY,
            f"stalled stream body mismatch len={len(rec['body'])}",
        )
    finally:
        peer.close()


def case_shutdown_goaway_drains_in_flight(port: int) -> None:
    """Server-initiated shutdown: one in-flight flow-blocked response
    completes after the client opens its window, a new stream submitted
    after GOAWAY is refused, and the connection closes once the first
    stream finishes.

    Uses raw framing throughout so h2's client state machine (which marks
    the connection CLOSED on GOAWAY) does not interfere with the drain."""
    from hpack import Decoder, Encoder  # type: ignore[import-not-found]

    raw = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT_S)
    sock = _h2_context().wrap_socket(raw, server_hostname="localhost")
    try:
        sock.sendall(
            b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            + b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
        )
        encoder = Encoder()
        decoder = Decoder()
        streams: Dict[int, Dict] = {}

        def record(stream_id: int) -> Dict:
            return streams.setdefault(
                stream_id,
                {"status": None, "body": bytearray(), "ended": False, "reset": None},
            )

        def frame(frame_type: int, flags: int, stream_id: int, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(3, "big")
                + bytes([frame_type, flags])
                + stream_id.to_bytes(4, "big")
                + payload
            )

        def send_headers_frame(
            stream_id: int, path: bytes, end_stream: bool = True
        ) -> None:
            block = encoder.encode(
                [
                    (b":method", b"GET"),
                    (b":scheme", b"https"),
                    (b":authority", b"localhost"),
                    (b":path", path),
                ]
            )
            flags = 0x04 | (0x01 if end_stream else 0x00)
            sock.sendall(frame(0x01, flags, stream_id, block))

        # Open a 1 MiB connection-level receive window so stall is
        # bounded by the per-stream window alone.
        sock.sendall(frame(0x08, 0x00, 0, (1 << 20).to_bytes(4, "big")))

        goaway_last_id: Optional[int] = None
        goaway_error: Optional[int] = None
        connection_closed = False

        # Sentinel for a timeout — distinct from EOF (returned as None)
        # so the drain-close check cannot pass just because the client
        # read deadline expired while the server kept the socket open.
        READ_TIMEOUT = object()

        def read_frame(
            deadline: float,
        ) -> Optional[Tuple[int, int, int, bytes]]:
            header = bytearray()
            while len(header) < 9:
                remaining = max(0.0, deadline - time.perf_counter())
                sock.settimeout(min(POLL_INTERVAL_S, remaining) if remaining else 0.0)
                try:
                    chunk = sock.recv(9 - len(header))
                except (socket.timeout, ssl.SSLWantReadError):
                    if time.perf_counter() >= deadline:
                        return READ_TIMEOUT  # type: ignore[return-value]
                    continue
                except (OSError, ssl.SSLError):
                    return None
                if not chunk:
                    return None
                header.extend(chunk)
            length = int.from_bytes(header[:3], "big")
            frame_type = header[3]
            flags = header[4]
            stream_id = int.from_bytes(header[5:9], "big") & 0x7FFFFFFF
            payload = bytearray()
            while len(payload) < length:
                remaining = max(0.0, deadline - time.perf_counter())
                sock.settimeout(min(POLL_INTERVAL_S, remaining) if remaining else 0.0)
                try:
                    chunk = sock.recv(length - len(payload))
                except (socket.timeout, ssl.SSLWantReadError):
                    if time.perf_counter() >= deadline:
                        return READ_TIMEOUT  # type: ignore[return-value]
                    continue
                except (OSError, ssl.SSLError):
                    return None
                if not chunk:
                    return None
                payload.extend(chunk)
            return frame_type, flags, stream_id, bytes(payload)

        def drive(deadline: float, condition) -> None:
            nonlocal goaway_last_id, goaway_error, connection_closed
            while time.perf_counter() < deadline and not condition():
                parsed = read_frame(deadline)
                if parsed is READ_TIMEOUT:
                    return
                if parsed is None:
                    connection_closed = True
                    return
                frame_type, flags, stream_id, payload = parsed
                if frame_type == 0x04 and (flags & 0x01) == 0:
                    sock.sendall(frame(0x04, 0x01, 0, b""))
                elif frame_type == 0x04:
                    pass
                elif frame_type == 0x08:
                    pass
                elif frame_type == 0x06 and (flags & 0x01) == 0:
                    sock.sendall(frame(0x06, 0x01, 0, payload))
                elif frame_type == 0x01 and stream_id:
                    decoded = decoder.decode(payload)
                    rec = record(stream_id)
                    for name, value in decoded:
                        if name == ":status":
                            rec["status"] = int(value)
                    if flags & 0x01:
                        rec["ended"] = True
                elif frame_type == 0x00 and stream_id:
                    rec = record(stream_id)
                    rec["body"].extend(payload)
                    if flags & 0x01:
                        rec["ended"] = True
                elif frame_type == 0x03 and stream_id:
                    code = int.from_bytes(payload[:4], "big")
                    rec = record(stream_id)
                    rec["reset"] = code
                    rec["ended"] = True
                elif frame_type == 0x07 and stream_id == 0:
                    goaway_last_id = int.from_bytes(payload[:4], "big") & 0x7FFFFFFF
                    goaway_error = int.from_bytes(payload[4:8], "big")

        # 1) Stall stream 1 on withheld credit (never ACK data for stream 1).
        stall_id = 1
        send_headers_frame(stall_id, b"/large", end_stream=True)
        drive(
            time.perf_counter() + 3.0,
            lambda: streams.get(stall_id, {}).get("status") == 200
            and len(streams.get(stall_id, {}).get("body") or b"") >= INITIAL_WINDOW,
        )
        rec1 = streams.get(stall_id)
        _assert(rec1 is not None and rec1["status"] == 200, f"stall precondition {rec1!r}")
        _assert(
            len(rec1["body"]) >= INITIAL_WINDOW,
            f"stall body only {len(rec1['body'])} bytes (want >= {INITIAL_WINDOW})",
        )
        _assert(not rec1["ended"], "stall stream ended before shutdown")

        # 2) Trigger server shutdown via a short second stream.
        trigger_id = 3
        send_headers_frame(trigger_id, b"/trigger-shutdown", end_stream=True)
        drive(
            time.perf_counter() + TIMEOUT_S,
            lambda: streams.get(trigger_id, {}).get("ended", False),
        )
        rec_trigger = streams.get(trigger_id)
        _assert(
            rec_trigger is not None and rec_trigger["status"] == 200,
            f"trigger-shutdown status {rec_trigger!r}",
        )
        _assert(
            bytes(rec_trigger["body"]) == b"shutdown requested",
            f"trigger-shutdown body {rec_trigger['body']!r}",
        )

        # 3) Wait for GOAWAY from the server.
        drive(
            time.perf_counter() + TIMEOUT_S,
            lambda: goaway_last_id is not None,
        )
        _assert(
            goaway_error == 0,
            f"shutdown GOAWAY error code {goaway_error!r}",
        )
        _assert(
            goaway_last_id is not None and goaway_last_id >= trigger_id,
            f"GOAWAY last_stream_id {goaway_last_id!r} < trigger {trigger_id}",
        )

        # 4) Open a new stream after GOAWAY and verify REFUSED_STREAM (7).
        refused_id = (goaway_last_id or trigger_id) + 2
        if refused_id % 2 == 0:
            refused_id += 1
        send_headers_frame(refused_id, b"/sibling", end_stream=True)
        drive(
            time.perf_counter() + TIMEOUT_S,
            lambda: streams.get(refused_id, {}).get("reset") is not None,
        )
        rec_refused = streams.get(refused_id)
        _assert(
            rec_refused is not None and rec_refused["reset"] == 7,
            f"post-GOAWAY stream reset {rec_refused!r} (want REFUSED_STREAM=7)",
        )

        # 5) Open the stream window generously so the stalled response
        # can finish regardless of how much the server has already sent.
        sock.sendall(frame(0x08, 0x00, stall_id, (1 << 20).to_bytes(4, "big")))
        drive(
            time.perf_counter() + TIMEOUT_S,
            lambda: streams.get(stall_id, {}).get("ended", False),
        )
        rec1 = streams.get(stall_id)
        _assert(
            rec1["ended"] and rec1["reset"] is None,
            f"stall stream after release {rec1!r}",
        )
        _assert(
            bytes(rec1["body"]) == LARGE_RESPONSE_BODY,
            f"stall final body mismatch len={len(rec1['body'])}",
        )

        # 6) Server closes the connection: EOF.
        drive(time.perf_counter() + TIMEOUT_S, lambda: connection_closed)
        _assert(connection_closed, "server did not close connection after drain")
    finally:
        try:
            sock.close()
        except OSError:
            pass


def case_client_sent_goaway(port: int) -> None:
    """A client-initiated GOAWAY must let the in-flight stream complete
    and then the server closes. Open /large (128 KiB) so the server's
    first drain stalls at the initial stream window (65535) and the
    stream is guaranteed to still be in flight when GOAWAY lands. Drive
    with raw framing so hyper-h2 cannot transition the client to CLOSED
    on the server's reciprocating GOAWAY and reject in-flight DATA."""
    from hpack import Decoder, Encoder  # type: ignore[import-not-found]

    raw = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT_S)
    sock = _h2_context().wrap_socket(raw, server_hostname="localhost")
    try:
        _assert(
            sock.selected_alpn_protocol() == "h2",
            f"ALPN not h2: {sock.selected_alpn_protocol()!r}",
        )
        sock.sendall(
            b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            + (0).to_bytes(3, "big")
            + bytes([0x04, 0x00])
            + (0).to_bytes(4, "big")
        )

        encoder = Encoder()
        decoder = Decoder()

        def frame(kind: int, flags: int, stream: int, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(3, "big")
                + bytes([kind, flags])
                + stream.to_bytes(4, "big")
                + payload
            )

        # Raise the connection receive window up front so the response
        # is only ever flow-blocked on its stream window, not the
        # connection one.
        sock.sendall(frame(0x08, 0x00, 0, ((1 << 20) - 1).to_bytes(4, "big")))

        stream_id = 1
        block = encoder.encode(
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/large"),
            ]
        )
        sock.sendall(frame(0x01, 0x05, stream_id, block))

        deadline = time.perf_counter() + TIMEOUT_S
        buf = bytearray()
        total_body = bytearray()
        status: Optional[int] = None
        headers_decoded = False
        stream_ended = False
        reset_code: Optional[int] = None
        server_closed = False
        goaway_sent = False
        credit_sent = False
        while time.perf_counter() < deadline and not (stream_ended and server_closed):
            remaining = max(0.0, deadline - time.perf_counter())
            sock.settimeout(min(POLL_INTERVAL_S, remaining) if remaining else 0.0)
            try:
                chunk = sock.recv(65536)
            except (socket.timeout, ssl.SSLWantReadError):
                if (
                    not goaway_sent
                    and headers_decoded
                    and len(total_body) >= 65535
                    and not stream_ended
                ):
                    # /large is 128 KiB; a server that honored the
                    # initial 65535 stream window must have stalled by
                    # now with END_STREAM pending. Send GOAWAY so
                    # draining engages while the response is still in
                    # flight — the asserts below reject a probe that
                    # sees the full response or END_STREAM beforehand.
                    goaway = (
                        (0).to_bytes(4, "big")
                        + (int(ErrorCodes.NO_ERROR)).to_bytes(4, "big")
                    )
                    sock.sendall(frame(0x07, 0x00, 0, goaway))
                    goaway_sent = True
                continue
            except (OSError, ssl.SSLError):
                server_closed = True
                break
            if not chunk:
                server_closed = True
                break
            buf.extend(chunk)
            while len(buf) >= 9:
                length = int.from_bytes(buf[:3], "big")
                if len(buf) < 9 + length:
                    break
                frame_type = buf[3]
                flags = buf[4]
                frame_stream = int.from_bytes(buf[5:9], "big") & 0x7FFFFFFF
                payload = bytes(buf[9 : 9 + length])
                del buf[: 9 + length]
                if frame_type == 0x01 and frame_stream == stream_id:
                    for name, value in decoder.decode(payload):
                        name_bytes = name if isinstance(name, bytes) else name.encode()
                        if name_bytes == b":status":
                            value_bytes = value if isinstance(value, bytes) else value.encode()
                            status = int(value_bytes.decode())
                    headers_decoded = True
                elif frame_type == 0x00 and frame_stream == stream_id:
                    total_body.extend(payload)
                    if flags & 0x01:
                        stream_ended = True
                elif frame_type == 0x03 and frame_stream == stream_id:
                    reset_code = int.from_bytes(payload[:4], "big")
                    stream_ended = True
            if goaway_sent and not credit_sent and headers_decoded:
                sock.sendall(
                    frame(
                        0x08,
                        0x00,
                        stream_id,
                        ((1 << 20) - 1).to_bytes(4, "big"),
                    )
                )
                credit_sent = True
        _assert(headers_decoded, "server never emitted response HEADERS")
        _assert(goaway_sent, "test never had a chance to send GOAWAY")
        _assert(stream_ended, "in-flight stream never finished with END_STREAM")
        _assert(reset_code is None, f"in-flight stream reset: {reset_code!r}")
        _assert(status == 200, f"GOAWAY-drained response status {status!r}")
        _assert(
            bytes(total_body) == LARGE_RESPONSE_BODY,
            f"GOAWAY-drained response body mismatch len={len(total_body)}",
        )
        _assert(server_closed, "server did not close after client GOAWAY drain")
    finally:
        try:
            sock.close()
        except OSError:
            pass
        try:
            raw.close()
        except OSError:
            pass


def _attempt_alpn(port: int, protocols: List[str]) -> Tuple[Optional[str], Optional[Exception]]:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if protocols:
        ctx.set_alpn_protocols(protocols)
    raw = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT_S)
    try:
        try:
            sock = ctx.wrap_socket(raw, server_hostname="localhost")
        except ssl.SSLError as exc:
            return None, exc
        try:
            negotiated = sock.selected_alpn_protocol()
            # Send an HTTP/1.1 request and confirm the server never
            # responds — otherwise an unprotected HTTP/1.1 fallback
            # could silently serve clients that offered no (or wrong)
            # ALPN. Inactivity alone is not enough: without a request
            # a correctly-shutting-down server also stays silent.
            try:
                sock.sendall(
                    b"GET / HTTP/1.1\r\n"
                    b"Host: localhost\r\n"
                    b"Connection: close\r\n\r\n"
                )
            except (ssl.SSLError, OSError):
                return negotiated, None
            sock.settimeout(1.0)
            try:
                payload = sock.recv(1024)
            except (socket.timeout, ssl.SSLError, OSError):
                payload = b""
            if payload:
                raise RuntimeError(
                    "server responded to an HTTP/1.1 request without a"
                    f" negotiated application protocol: {payload!r}"
                )
            return negotiated, None
        finally:
            try:
                sock.close()
            except OSError:
                pass
    finally:
        try:
            raw.close()
        except OSError:
            pass


def case_alpn_mismatch_and_absent(port: int) -> None:
    """A client offering only unknown ALPN or none must not get a
    successful ALPN selection and must not receive plaintext data."""
    # Unknown ALPN.
    negotiated, exc = _attempt_alpn(port, ["unknown/1"])
    _assert(
        negotiated in (None, "") or exc is not None,
        f"server negotiated an unknown ALPN: {negotiated!r}",
    )
    # No ALPN at all.
    negotiated, exc = _attempt_alpn(port, [])
    _assert(
        negotiated in (None, "") or exc is not None,
        f"server negotiated an empty ALPN: {negotiated!r}",
    )


# --- Driver ---


def _wait_ready(proc: subprocess.Popen) -> int:
    line = proc.stdout.readline().strip()
    if not line.startswith("READY "):
        raise RuntimeError(f"fixture did not start: {line!r}")
    return int(line.split()[1])


def _shutdown(port: int) -> None:
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        stream_id = peer.open_request("GET", "/shutdown")
        peer.wait_stream(stream_id, time.perf_counter() + TIMEOUT_S)
    finally:
        peer.close()


def _run_cases(port: int) -> None:
    case_large_request_body(port)
    case_large_response_body(port)
    case_continuation_header_block(port)
    case_rst_while_sibling_completes(port)
    case_stalled_stream_sibling_progresses(port)
    case_client_sent_goaway(port)
    case_alpn_mismatch_and_absent(port)
    # Terminal case: shuts the fixture down via /trigger-shutdown; no
    # /shutdown call afterwards.
    case_shutdown_goaway_drains_in_flight(port)


def main() -> None:
    proc = subprocess.Popen(
        FIXTURE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        port = _wait_ready(proc)
        _run_cases(port)
        rc = proc.wait(timeout=30)
        if rc != 0:
            raise RuntimeError(
                f"fixture exited with {rc}: stderr={proc.stderr.read()!r}"
            )
    except Exception:
        proc.kill()
        proc.wait()
        sys.stderr.write(proc.stderr.read())
        raise
    print("HTTP/2 integration gap suite succeeded")


if __name__ == "__main__":
    main()
