#!/usr/bin/env python3
"""Issue #42 Phase 7: shared handler contract run over HTTP/1.1 and HTTP/2.

Each table row describes one handler-visible behaviour (method/path routing,
HEAD/204/304 framing, duplicate headers, request/response trailers, handler
error isolation, body-limit rejection, hop-by-hop stripping, Content-Length
mismatch).  The same case is executed against the same running fixture over
both ALPN selections so a divergence is visible as one leg passing while
the other fails."""

from __future__ import annotations

import socket
import ssl
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import (
    ConnectionTerminated,
    DataReceived,
    ResponseReceived,
    StreamEnded,
    StreamReset,
    TrailersReceived,
)


FIXTURE = ["mojo", "run", "--Werror", "-I", ".", "tests/http_app_contract_fixture.mojo"]
REQUEST_TIMEOUT_S = 5.0
POLL_INTERVAL_S = 0.05


def _h1_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["http/1.1"])
    return ctx


def _h2_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["h2"])
    return ctx


@dataclass
class H1Response:
    status: int
    reason: str
    headers: List[Tuple[str, str]]
    body: bytes
    trailers: List[Tuple[str, str]] = field(default_factory=list)

    def header_values(self, name: str) -> List[str]:
        return [v for n, v in self.headers if n.lower() == name.lower()]

    def trailer_values(self, name: str) -> List[str]:
        return [v for n, v in self.trailers if n.lower() == name.lower()]


class H1Client:
    """Opens a fresh connection per request so each case owns its socket.

    Reusing one connection across cases would entangle the handler-visible
    contract with keep-alive behaviour that is already exercised in
    tests/test_http_server.mojo; the application-contract leg here only
    cares that the same handler-visible result appears for each case.
    """

    def __init__(self, port: int):
        self._port = port
        self._sock: Optional[ssl.SSLSocket] = None

    def _open(self) -> None:
        raw = socket.create_connection(("127.0.0.1", self._port), timeout=REQUEST_TIMEOUT_S)
        self._sock = _h1_context().wrap_socket(raw, server_hostname="localhost")
        if self._sock.selected_alpn_protocol() != "http/1.1":
            raise RuntimeError("ALPN did not negotiate http/1.1")

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def request(
        self,
        method: str,
        path: str,
        *,
        headers: Optional[List[Tuple[str, str]]] = None,
        body: bytes = b"",
        trailers: Optional[List[Tuple[str, str]]] = None,
        connection_close: bool = True,
        force_chunked: bool = False,
    ) -> H1Response:
        self._open()
        assert self._sock is not None
        request_headers = [("Host", "localhost")]
        if headers:
            request_headers.extend(headers)
        if trailers or force_chunked:
            request_headers.append(("Transfer-Encoding", "chunked"))
            if trailers:
                request_headers.append(
                    ("Trailer", ", ".join(n for n, _ in trailers))
                )
        else:
            request_headers.append(("Content-Length", str(len(body))))
        if connection_close:
            request_headers.append(("Connection", "close"))
        head = f"{method} {path} HTTP/1.1\r\n".encode()
        for name, value in request_headers:
            head += f"{name}: {value}\r\n".encode()
        head += b"\r\n"
        self._sock.sendall(head)
        if trailers or force_chunked:
            if body:
                self._sock.sendall(f"{len(body):x}\r\n".encode() + body + b"\r\n")
            self._sock.sendall(b"0\r\n")
            for name, value in trailers or []:
                self._sock.sendall(f"{name}: {value}\r\n".encode())
            self._sock.sendall(b"\r\n")
        elif body:
            self._sock.sendall(body)
        try:
            return self._read_response()
        finally:
            self.close()

    def _read_response(self) -> H1Response:
        buf = bytearray()
        while b"\r\n\r\n" not in buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise RuntimeError(f"H1: connection closed before headers (got {bytes(buf)!r})")
            buf.extend(chunk)
        head, _, rest = bytes(buf).partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        status_line = lines[0].decode("iso-8859-1")
        _, status_code, reason = status_line.split(" ", 2)
        headers: List[Tuple[str, str]] = []
        for line in lines[1:]:
            name, _, value = line.decode("iso-8859-1").partition(":")
            headers.append((name.strip(), value.strip()))

        body = bytearray(rest)
        trailers: List[Tuple[str, str]] = []
        resp_status = int(status_code)
        no_body = resp_status in (204, 304) or (100 <= resp_status < 200)
        cl = next((int(v) for n, v in headers if n.lower() == "content-length"), None)
        te = next((v.lower() for n, v in headers if n.lower() == "transfer-encoding"), None)
        if no_body:
            pass
        elif cl is not None:
            while len(body) < cl:
                chunk = self._sock.recv(4096)
                if not chunk:
                    break
                body.extend(chunk)
            if len(body) > cl:
                del body[cl:]
            body_bytes = bytes(body)
        elif te == "chunked":
            body_bytes = bytearray()
            while True:
                size_line, body = self._consume_line(body)
                size = int(size_line.decode("iso-8859-1").split(";")[0], 16)
                if size == 0:
                    while True:
                        line, body = self._consume_line(body)
                        if not line:
                            break
                        name, _, value = line.decode("iso-8859-1").partition(":")
                        trailers.append((name.strip(), value.strip()))
                    break
                while len(body) < size + 2:
                    chunk = self._sock.recv(4096)
                    if not chunk:
                        break
                    body.extend(chunk)
                body_bytes.extend(body[:size])
                del body[: size + 2]
            body_bytes = bytes(body_bytes)
        else:
            body_bytes = bytes(body)
            while True:
                chunk = self._sock.recv(4096)
                if not chunk:
                    break
                body_bytes += chunk
        if cl is not None and not no_body:
            body = bytes(body)
        else:
            body = body_bytes if no_body is False else b""
        return H1Response(resp_status, reason, headers, bytes(body), trailers)

    def _consume_line(self, buf: bytearray) -> Tuple[bytes, bytearray]:
        while True:
            idx = buf.find(b"\r\n")
            if idx >= 0:
                return bytes(buf[:idx]), buf[idx + 2 :]
            chunk = self._sock.recv(4096)
            if not chunk:
                raise RuntimeError("H1: EOF during chunked framing")
            buf.extend(chunk)


@dataclass
class H2Response:
    status: int
    headers: Dict[bytes, List[bytes]]
    body: bytes
    trailers: Dict[bytes, List[bytes]]
    reset_code: Optional[int]
    stream_ended: bool

    def header_values(self, name: str) -> List[str]:
        return [
            v.decode("iso-8859-1")
            for v in self.headers.get(name.lower().encode(), [])
        ]

    def trailer_values(self, name: str) -> List[str]:
        return [
            v.decode("iso-8859-1")
            for v in self.trailers.get(name.lower().encode(), [])
        ]


class H2Client:
    def __init__(self, port: int):
        raw = socket.create_connection(("127.0.0.1", port), timeout=REQUEST_TIMEOUT_S)
        self._sock = _h2_context().wrap_socket(raw, server_hostname="localhost")
        if self._sock.selected_alpn_protocol() != "h2":
            raise RuntimeError("ALPN did not negotiate h2")
        self._conn = H2Connection(
            config=H2Configuration(client_side=True, header_encoding=None)
        )
        self._conn.initiate_connection()
        self._conn.increment_flow_control_window(16 * 1024 * 1024)
        self._flush()
        self._streams: Dict[int, Dict] = {}
        self._terminated = False

    def close(self) -> None:
        try:
            self._conn.close_connection()
            self._flush()
        except Exception:
            pass
        try:
            self._sock.close()
        except OSError:
            pass

    def _flush(self) -> None:
        data = self._conn.data_to_send()
        if data:
            self._sock.sendall(data)

    def _pump(self, deadline: float, until: Callable[[], bool]) -> None:
        while time.perf_counter() < deadline:
            if until():
                return
            self._sock.settimeout(
                min(POLL_INTERVAL_S, max(0.0, deadline - time.perf_counter()))
            )
            try:
                chunk = self._sock.recv(65536)
            except (socket.timeout, ssl.SSLWantReadError):
                continue
            if not chunk:
                self._terminated = True
                return
            for event in self._conn.receive_data(chunk):
                self._handle(event)
            self._flush()
        if not until():
            raise RuntimeError("H2: deadline exceeded while waiting for condition")

    def _record(self, stream_id: int) -> Dict:
        rec = self._streams.setdefault(
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
        return rec

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
            self._conn.acknowledge_received_data(
                event.flow_controlled_length, event.stream_id
            )
        elif isinstance(event, TrailersReceived):
            rec = self._record(event.stream_id)
            for name, value in event.headers:
                rec["trailers"].setdefault(name, []).append(value)
        elif isinstance(event, StreamEnded):
            self._record(event.stream_id)["ended"] = True
        elif isinstance(event, StreamReset):
            rec = self._record(event.stream_id)
            rec["reset"] = int(event.error_code)
            rec["ended"] = True
        elif isinstance(event, ConnectionTerminated):
            self._terminated = True

    def request(
        self,
        method: str,
        path: str,
        *,
        headers: Optional[List[Tuple[bytes, bytes]]] = None,
        body: bytes = b"",
        trailers: Optional[List[Tuple[bytes, bytes]]] = None,
    ) -> H2Response:
        stream_id = self._conn.get_next_available_stream_id()
        req_headers = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", b"localhost"),
            (b":path", path.encode()),
        ]
        if headers:
            req_headers.extend(headers)
        if body or trailers:
            req_headers.append((b"content-length", str(len(body)).encode()))
        end_stream_on_headers = not body and not trailers
        self._conn.send_headers(stream_id, req_headers, end_stream=end_stream_on_headers)
        if body:
            self._conn.send_data(stream_id, body, end_stream=not trailers)
        if trailers:
            self._conn.send_headers(stream_id, trailers, end_stream=True)
        self._flush()
        deadline = time.perf_counter() + REQUEST_TIMEOUT_S
        self._pump(deadline, lambda: self._streams.get(stream_id, {}).get("ended", False))
        rec = self._streams.pop(stream_id)
        return H2Response(
            status=rec["status"] or 0,
            headers=rec["headers"],
            body=bytes(rec["body"]),
            trailers=rec["trailers"],
            reset_code=rec["reset"],
            stream_ended=rec["ended"],
        )

    def terminated(self) -> bool:
        return self._terminated


def _assert(cond: bool, msg: str) -> None:
    if not cond:
        raise RuntimeError(msg)


# --- Shared contract cases ---


def case_routing(h1: H1Client, h2: H2Client) -> None:
    for method in ("GET", "POST"):
        r1 = h1.request(method, "/echo?a=1&b=2", body=b"ping" if method == "POST" else b"")
        _assert(r1.status == 200, f"H1 routing status {r1.status}")
        _assert(r1.header_values("x-method") == [method], f"H1 X-Method {r1.header_values('x-method')!r}")
        _assert(r1.header_values("x-path") == ["/echo"], f"H1 X-Path {r1.header_values('x-path')!r}")
        _assert(r1.header_values("x-query") == ["a=1&b=2"], f"H1 X-Query {r1.header_values('x-query')!r}")
        if method == "POST":
            _assert(r1.body == b"ping", f"H1 body {r1.body!r}")

        h2b = H2Client(h2._port) if hasattr(h2, "_port") else h2
        r2 = h2b.request(method, "/echo?a=1&b=2", body=b"ping" if method == "POST" else b"")
        _assert(r2.status == 200, f"H2 routing status {r2.status}")
        _assert(r2.header_values("x-method") == [method], f"H2 X-Method {r2.header_values('x-method')!r}")
        _assert(r2.header_values("x-path") == ["/echo"], f"H2 X-Path {r2.header_values('x-path')!r}")
        _assert(r2.header_values("x-query") == ["a=1&b=2"], f"H2 X-Query {r2.header_values('x-query')!r}")
        if method == "POST":
            _assert(r2.body == b"ping", f"H2 body {r2.body!r}")


def case_not_found(h1: H1Client, h2: H2Client) -> None:
    r1 = h1.request("GET", "/does-not-exist")
    _assert(r1.status == 404 and r1.body == b"missing", f"H1 404 {r1!r}")
    r2 = h2.request("GET", "/does-not-exist")
    _assert(r2.status == 404 and r2.body == b"missing", f"H2 404 {r2!r}")


def case_head_no_body(port: int) -> None:
    h1 = H1Client(port)
    try:
        r1 = h1.request("HEAD", "/head")
        _assert(r1.status == 200, f"H1 HEAD status {r1.status}")
        _assert(r1.header_values("content-length") == ["10"], f"H1 HEAD CL {r1.header_values('content-length')!r}")
        _assert(r1.body == b"", f"H1 HEAD body {r1.body!r}")
    finally:
        h1.close()
    h2 = H2Client(port)
    try:
        r2 = h2.request("HEAD", "/head")
        _assert(r2.status == 200, f"H2 HEAD status {r2.status}")
        _assert(r2.header_values("content-length") == ["10"], f"H2 HEAD CL {r2.header_values('content-length')!r}")
        _assert(r2.body == b"", f"H2 HEAD body {r2.body!r}")
    finally:
        h2.close()


def case_no_body_statuses(h1: H1Client, h2: H2Client) -> None:
    for path, status in (("/no-content", 204), ("/not-modified", 304)):
        r1 = h1.request("GET", path)
        _assert(r1.status == status, f"H1 {path} status {r1.status}")
        _assert(r1.body == b"", f"H1 {path} body {r1.body!r}")
        _assert(r1.header_values("content-length") == [], f"H1 {path} CL {r1.header_values('content-length')!r}")

        r2 = h2.request("GET", path)
        _assert(r2.status == status, f"H2 {path} status {r2.status}")
        _assert(r2.body == b"", f"H2 {path} body {r2.body!r}")
        _assert(r2.header_values("content-length") == [], f"H2 {path} CL {r2.header_values('content-length')!r}")


def case_duplicate_headers(h1: H1Client, h2: H2Client) -> None:
    r1 = h1.request("GET", "/dup")
    _assert(r1.header_values("x-dup") == ["one", "two"], f"H1 dup headers {r1.header_values('x-dup')!r}")
    r2 = h2.request("GET", "/dup")
    _assert(sorted(r2.header_values("x-dup")) == ["one", "two"], f"H2 dup headers {r2.header_values('x-dup')!r}")


def case_request_trailers(h1: H1Client, h2: H2Client) -> None:
    r1 = h1.request(
        "POST",
        "/req-trailers",
        body=b"abc",
        trailers=[("X-Trailer-In", "contract")],
    )
    _assert(r1.status == 200, f"H1 req trailers status {r1.status}")
    _assert(r1.body == b"trailer=contract", f"H1 req trailers body {r1.body!r}")
    r2 = h2.request(
        "POST",
        "/req-trailers",
        body=b"abc",
        trailers=[(b"x-trailer-in", b"contract")],
    )
    _assert(r2.status == 200, f"H2 req trailers status {r2.status}")
    _assert(r2.body == b"trailer=contract", f"H2 req trailers body {r2.body!r}")


def case_response_trailers(h1: H1Client, h2: H2Client) -> None:
    r1 = h1.request("GET", "/resp-trailers")
    _assert(r1.body == b"with-trailers", f"H1 resp trailers body {r1.body!r}")
    _assert(r1.trailer_values("x-trailer-out") == ["ok"], f"H1 resp trailers {r1.trailers!r}")
    r2 = h2.request("GET", "/resp-trailers")
    _assert(r2.body == b"with-trailers", f"H2 resp trailers body {r2.body!r}")
    _assert(r2.trailer_values("x-trailer-out") == ["ok"], f"H2 resp trailers {r2.trailers!r}")


def case_handler_error_sibling_survives(port: int) -> None:
    # H1 case: /boom returns 500 and closes.  A sibling on a fresh connection
    # continues to work (the H1 adapter closes the connection on handler
    # error, which is the contract for the plaintext/TLS leg).
    h1 = H1Client(port)
    try:
        r1 = h1.request("GET", "/boom")
        _assert(r1.status == 500, f"H1 boom status {r1.status}")
    finally:
        h1.close()
    h1b = H1Client(port)
    try:
        r1b = h1b.request("GET", "/sibling")
        _assert(r1b.status == 200 and r1b.body == b"sibling ok", f"H1 sibling after boom {r1b!r}")
    finally:
        h1b.close()
    # H2 case: /boom returns 500 and the connection stays alive for a
    # sibling stream on the same connection.
    h2 = H2Client(port)
    try:
        rboom = h2.request("GET", "/boom")
        _assert(rboom.status == 500, f"H2 boom status {rboom.status}")
        rsib = h2.request("GET", "/sibling")
        _assert(
            rsib.status == 200 and rsib.body == b"sibling ok",
            f"H2 sibling after boom {rsib!r}",
        )
        _assert(not h2.terminated(), "H2 connection terminated after handler error")
    finally:
        h2.close()


def case_body_over_limit(port: int) -> None:
    big = b"x" * 400
    # H1: fresh connection; parser enforces max_body_bytes and returns 413.
    h1 = H1Client(port)
    try:
        r1 = h1.request("POST", "/echo", body=big)
        _assert(r1.status == 413, f"H1 oversize status {r1.status}")
    finally:
        h1.close()
    # H2: oversized body resets the stream (stream-level 500/RST), but the
    # connection stays usable for the next stream.
    h2 = H2Client(port)
    try:
        r2 = h2.request("POST", "/echo", body=big)
        _assert(
            r2.status != 200,
            f"H2 oversize unexpectedly accepted: status={r2.status} reset={r2.reset_code}",
        )
        r2sib = h2.request("GET", "/sibling")
        _assert(
            r2sib.status == 200 and r2sib.body == b"sibling ok",
            f"H2 sibling after oversize {r2sib!r}",
        )
    finally:
        h2.close()


def case_content_length_mismatch(port: int) -> None:
    """H1: handler-set Content-Length that disagrees with the written body
    is caught by the H1 encoder (NetError on the mismatch), the server
    sends 500 and closes.  H2: the response-header encoder flags the same
    disagreement, retries with an empty 500, and the sibling stream on the
    same connection still succeeds."""
    h1 = H1Client(port)
    try:
        r1 = h1.request("GET", "/cl-mismatch")
        _assert(
            r1.status == 500,
            f"H1 CL mismatch: expected 500, got {r1.status}",
        )
    finally:
        h1.close()
    h2 = H2Client(port)
    try:
        r2 = h2.request("GET", "/cl-mismatch")
        _assert(
            r2.status == 500,
            f"H2 CL mismatch: expected 500, got status={r2.status} reset={r2.reset_code}",
        )
        _assert(
            not h2.terminated(),
            "H2 CL mismatch unexpectedly closed the connection",
        )
        rsib = h2.request("GET", "/sibling")
        _assert(
            rsib.status == 200 and rsib.body == b"sibling ok",
            f"H2 sibling after CL mismatch {rsib!r}",
        )
    finally:
        h2.close()


def case_hop_by_hop_headers(h1: H1Client, h2: H2Client) -> None:
    # Handler-set Connection and Keep-Alive are valid on H1 and must be
    # silently dropped on H2 without closing the connection (RFC 9113 §8.2.2).
    # Transfer-Encoding is intentionally not covered here: the H1 encoder
    # rejects a handler-set TE outright (test_http_server.mojo /bad-frame),
    # which is a stricter contract than H2 silently strips.
    r1 = h1.request("GET", "/strip")
    _assert(r1.body == b"stripped?", f"H1 strip body {r1.body!r}")
    _assert(
        r1.header_values("connection") == ["close"],
        f"H1 handler-set Connection header expected: {r1.header_values('connection')!r}",
    )
    r2 = h2.request("GET", "/strip")
    _assert(r2.body == b"stripped?", f"H2 strip body {r2.body!r}")
    for hop in ("connection", "keep-alive", "transfer-encoding"):
        _assert(
            r2.header_values(hop) == [],
            f"H2 hop header leaked: {hop}={r2.header_values(hop)!r}",
        )
    _assert(not h2.terminated(), "H2 connection terminated after hop header strip")


# --- Driver ---


def _wait_ready(proc: subprocess.Popen) -> int:
    line = proc.stdout.readline().strip()
    if not line.startswith("READY "):
        raise RuntimeError(f"fixture did not start: {line!r}")
    return int(line.split()[1])


def _shutdown(port: int) -> None:
    h1 = H1Client(port)
    try:
        try:
            h1.request("GET", "/shutdown")
        except Exception:
            pass
    finally:
        h1.close()


def _run_cases(port: int) -> None:
    # Create one shared H1/H2 pair for the multi-request cases that reuse
    # the same connection; one-shot cases open their own pairs.
    pair_h1 = H1Client(port)
    pair_h2 = H2Client(port)
    pair_h2._port = port  # noqa: SLF001 — only used by case_routing's helper
    try:
        case_routing(pair_h1, pair_h2)
        case_not_found(pair_h1, pair_h2)
        case_no_body_statuses(pair_h1, pair_h2)
        case_duplicate_headers(pair_h1, pair_h2)
        case_request_trailers(pair_h1, pair_h2)
        case_response_trailers(pair_h1, pair_h2)
        case_hop_by_hop_headers(pair_h1, pair_h2)
    finally:
        pair_h1.close()
        pair_h2.close()
    case_head_no_body(port)
    case_handler_error_sibling_survives(port)
    case_body_over_limit(port)
    case_content_length_mismatch(port)


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
        rc = proc.wait(timeout=15)
        if rc != 0:
            raise RuntimeError(
                f"fixture exited with {rc}: stderr={proc.stderr.read()!r}"
            )
    except Exception:
        proc.kill()
        proc.wait()
        sys.stderr.write(proc.stderr.read())
        raise
    print("HTTP application contract suite succeeded on H1 and H2")


if __name__ == "__main__":
    main()
