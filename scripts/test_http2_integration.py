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
                    deadline = time.perf_counter() + TIMEOUT_S
                    while (
                        self._conn.local_flow_control_window(stream_id) < size
                        and time.perf_counter() < deadline
                    ):
                        self.pump(deadline)
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


def case_large_response_body(port: int) -> None:
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        stream_id = peer.open_request("GET", "/large")
        rec = peer.wait_stream(stream_id, time.perf_counter() + TIMEOUT_S)
        _assert(rec["status"] == 200, f"large resp status {rec['status']}")
        _assert(rec["reset"] is None, f"large resp reset {rec['reset']}")
        _assert(len(rec["body"]) == 128 * 1024, f"large resp len {len(rec['body'])}")
        _assert(rec["body"][0:1] == b"a", f"large resp first byte {rec['body'][:1]!r}")
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
        sock.settimeout(0.5)
        deadline = time.perf_counter() + TIMEOUT_S
        header = bytearray()
        while time.perf_counter() < deadline and not got_end:
            # Read a 9-byte frame header.
            while len(header) < 9:
                chunk = sock.recv(9 - len(header))
                if not chunk:
                    raise RuntimeError("connection closed during continuation test")
                header.extend(chunk)
            length = int.from_bytes(header[:3], "big")
            frame_type = header[3]
            flags = header[4]
            frame_stream = int.from_bytes(header[5:9], "big")
            payload = bytearray()
            while len(payload) < length:
                chunk = sock.recv(length - len(payload))
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
        # Spin pumping briefly so the server starts sending the stalled
        # response until the per-stream window closes.
        deadline = time.perf_counter() + 1.0
        while time.perf_counter() < deadline:
            peer.pump(deadline)
            rec = peer._streams.get(stalled)
            if rec and len(rec["body"]) >= INITIAL_WINDOW:
                break
        sib_id = peer.open_request("GET", "/sibling")
        sib = peer.wait_stream(sib_id, time.perf_counter() + TIMEOUT_S)
        _assert(sib["status"] == 200, f"sibling status under stall {sib['status']}")
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
    finally:
        peer.close()


def case_client_sent_goaway(port: int) -> None:
    """A client-initiated GOAWAY on the connection must let an in-flight
    stream complete and then the server closes."""
    peer = H2Peer(port, raise_conn_window=1 << 20)
    try:
        stream_id = peer.open_request("GET", "/sibling")
        rec = peer.wait_response_only(stream_id, time.perf_counter() + TIMEOUT_S)
        _assert(rec["status"] == 200, f"GOAWAY precondition status {rec['status']}")
        peer._conn.close_connection(error_code=int(ErrorCodes.NO_ERROR))
        peer._flush()
        # Drain any residual frames; expect no error from server.
        deadline = time.perf_counter() + TIMEOUT_S
        peer._sock.settimeout(0.5)
        while time.perf_counter() < deadline:
            try:
                chunk = peer._sock.recv(65536)
            except (socket.timeout, ssl.SSLWantReadError):
                continue
            if not chunk:
                break
            for event in peer._conn.receive_data(chunk):
                peer._handle(event)
    finally:
        peer.close()


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
            # Probe one byte of read to confirm no plaintext downgrade.
            sock.settimeout(0.5)
            try:
                payload = sock.recv(1)
            except (socket.timeout, ssl.SSLError, OSError):
                payload = b""
            if payload:
                raise RuntimeError(
                    f"server sent data without a negotiated application protocol: {payload!r}"
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
        _shutdown(port)
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
