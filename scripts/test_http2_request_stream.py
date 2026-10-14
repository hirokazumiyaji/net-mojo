#!/usr/bin/env python3
"""Exercise HTTP/2 request streaming through TLS and real body workers."""
from __future__ import annotations

import argparse
import subprocess
import sys
import time

from h2.events import InformationalResponseReceived, WindowUpdated
from h2.errors import ErrorCodes
from h2.settings import SettingCodes

from test_http2_integration import H2Peer, TIMEOUT_S, _assert, _wait_ready

FIXTURE = ["mojo", "run", "--Werror", "-I", ".", "tests/http2_request_stream_fixture.mojo"]
QUEUE = 4096
BODY_DEADLINE_S = 0.6


class Peer(H2Peer):
    def __init__(self, port: int):
        self.hold_ack = False
        self.credit: dict[int, int] = {}
        self.informational: dict[int, list[int]] = {}
        super().__init__(port)

    def _flush(self) -> None:
        if not self.hold_ack:
            super()._flush()

    def _handle(self, event) -> None:
        if isinstance(event, WindowUpdated):
            self.credit[event.stream_id] = self.credit.get(event.stream_id, 0) + event.delta
        elif isinstance(event, InformationalResponseReceived):
            self.informational.setdefault(event.stream_id, []).append(
                int(dict(event.headers)[b":status"])
            )
        else:
            super()._handle(event)

    def request(self, path: str, *, length: int | None = None,
                ended: bool = False, expect: str | None = None) -> int:
        stream = self._conn.get_next_available_stream_id()
        headers = [(b":method", b"POST"), (b":scheme", b"https"),
                   (b":authority", b"localhost"), (b":path", path.encode())]
        if length is not None:
            headers.append((b"content-length", str(length).encode()))
        if expect is not None:
            headers.append((b"expect", expect.encode()))
        self._conn.send_headers(stream, headers, end_stream=ended)
        self._flush()
        return stream

    def data(self, stream: int, data: bytes, *, ended: bool = False,
             padding: int | None = None) -> None:
        self._conn.send_data(stream, data, end_stream=ended, pad_length=padding)
        self._flush()

    def upload(self, stream: int, payload: bytes, *, ended: bool = True,
               control: Peer | None = None) -> None:
        offset = 0
        chunks = 0
        deadline = time.perf_counter() + TIMEOUT_S
        while offset < len(payload):
            window = self._conn.local_flow_control_window(stream)
            if window <= 0:
                _assert(time.perf_counter() < deadline, "body worker did not restore receive credit")
                self.pump(deadline)
                continue
            count = min(window, self._conn.max_outbound_frame_size, len(payload) - offset)
            self.data(stream, payload[offset:offset + count],
                      ended=ended and offset + count == len(payload))
            offset += count
            chunks += 1
            deadline = time.perf_counter() + TIMEOUT_S
            if control is not None and (chunks % 16 == 0 or offset == len(payload)):
                observed = status(control)
                _assert(observed["pending"] <= QUEUE, f"body queue exceeded limit: {observed}")

    def result(self, stream: int) -> dict:
        return self.wait_stream(stream, time.perf_counter() + TIMEOUT_S)

    def get(self, path: str) -> bytes:
        result = self.result(self.open_request("GET", path))
        _assert(result["status"] == 200 and result["reset"] is None, f"GET {path}: {result}")
        return bytes(result["body"])


def status(control: Peer) -> dict:
    fields = control.get("/status").decode().split(",")
    if fields == ["missing"]:
        return {"missing": True}
    return dict(zip(("count", "checksum", "done", "cancelled", "paired", "premature", "trailer", "pending", "decoded", "failed"),
                    [int(value) if i != 6 else value for i, value in enumerate(fields)]))


def wait_status(control: Peer, predicate) -> dict:
    deadline = time.perf_counter() + TIMEOUT_S
    while time.perf_counter() < deadline:
        observed = status(control)
        if "missing" not in observed and predicate(observed):
            return observed
    raise RuntimeError(f"worker status did not reach expected state: {observed}")


def healthy(peer: Peer) -> None:
    _assert(peer.get("/sibling") == b"sibling ok", "healthy sibling did not progress")


def handshake(peer: Peer) -> None:
    healthy(peer)
    healthy(peer)
    peer.credit.clear()


def assert_complete(control: Peer, payload: bytes, trailer: str = "") -> None:
    observed = wait_status(control, lambda value: value["done"])
    _assert(observed["count"] == len(payload), f"body length mismatch: {observed}")
    _assert(observed["checksum"] == sum(payload), f"body checksum mismatch: {observed}")
    _assert(not observed["cancelled"] and not observed["premature"] and not observed["failed"], f"unexpected worker error: {observed}")
    _assert(observed["trailer"] == trailer, f"request trailer mismatch: {observed}")


def case_first_flight(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        # Send the complete first flight before receiving server SETTINGS.
        stream = peer.request("/hold", length=16384)
        payload = b"a" * 8192
        peer.data(stream, payload)
        sibling = peer.open_request("GET", "/sibling")
        peer.hold_ack = True
        observed = wait_status(control, lambda value: value["decoded"] == 8192)
        _assert(observed["pending"] == 8192 and observed["count"] == 0,
                f"pre-ACK default receive window was not retained: {observed}")
        _assert(bytes(peer.result(sibling)["body"]) == b"sibling ok", "pre-ACK sibling failed")
        _assert(peer.credit.get(stream, 0) == 0 and peer.credit.get(0, 0) == 0,
                f"queued first-flight payload received early credit: {peer.credit}")
        peer.hold_ack = False
        peer._flush()
        control.get("/release")
        peer.upload(stream, payload)
        payload *= 2
        result = peer.result(stream)
        _assert(result["status"] == 200 and bytes(result["body"]) == b"16384", f"first-flight body failed: {result}")
        assert_complete(control, payload)
    finally:
        peer.close()


def case_credit_and_trailers(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/hold")
        peer.data(stream, b"b" * QUEUE)
        observed = wait_status(control, lambda value: value["pending"] == QUEUE)
        _assert(observed["count"] == 0, f"consumer gate did not hold: {observed}")
        healthy(peer)
        _assert(peer.credit.get(stream, 0) == 0 and peer.credit.get(0, 0) == 0,
                f"payload was credited before consumption: {peer.credit}")
        control.get("/release")
        wait_status(control, lambda value: value["count"] == QUEUE)
        tail = bytes(range(256)) * (4096 - 16)
        peer.upload(stream, tail, ended=False, control=control)
        peer._conn.send_headers(stream, [(b"x-end", b"done")], end_stream=True)
        peer._flush()
        result = peer.result(stream)
        payload = b"b" * QUEUE + tail
        _assert(len(payload) == 1024 * 1024, "fixture payload must be exactly 1 MiB")
        _assert(result["status"] == 200 and result["reset"] is None,
                f"body larger than queue failed: {result}")
        _assert(peer.credit.get(stream, 0) >= len(payload) - QUEUE,
                f"body upload did not use consumer-driven stream credit: {peer.credit}")
        assert_complete(control, payload, "done")
    finally:
        peer.close()


def case_padding(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/hold")
        peer.data(stream, b"", padding=127)
        healthy(peer)
        _assert(peer.credit.get(stream, 0) == 128 and peer.credit.get(0, 0) == 128,
                f"padding credit must be immediate and exact: {peer.credit}")
        peer.data(stream, b"pad", ended=True)
        control.get("/release")
        peer.result(stream)
        assert_complete(control, b"pad")
    finally:
        peer.close()


def case_early_fin_and_zero_body(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/early", length=16384)
        result = peer.result(stream)
        _assert(result["status"] == 200 and bytes(result["body"]) == b"early", f"early response failed: {result}")
        payload = b"c" * 16384
        peer.upload(stream, payload)
        assert_complete(control, payload)
        healthy(peer)
        zero = peer.request("/upload", length=0, ended=True)
        _assert(bytes(peer.result(zero)["body"]) == b"0", "zero-body worker did not wake at EOF")
        assert_complete(control, b"")
        waiting_zero = peer.request("/upload")
        healthy(peer)
        wait_status(control, lambda value: not value["done"])
        peer.data(waiting_zero, b"", ended=True)
        _assert(bytes(peer.result(waiting_zero)["body"]) == b"0",
                "blocked body worker did not wake on empty DATA END_STREAM")
        assert_complete(control, b"")
    finally:
        peer.close()


def case_standalone_receiver(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/standalone", length=4)
        _assert(bytes(peer.result(stream)["body"]) == b"standalone", "standalone synchronous FIN failed")
        _assert(control.get("/standalone-status") == b"waiting", "standalone receiver did not wait after FIN")
        peer.data(stream, b"body", ended=True)
        deadline = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < deadline:
            value = control.get("/standalone-status")
            _assert(value != b"failed", "standalone receiver was cancelled after synchronous FIN")
            if value == b"4":
                break
        _assert(value == b"4", f"standalone receiver did not consume late DATA: {value}")
        healthy(peer)
    finally:
        peer.close()


def case_synchronous_ignored_body(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        for _ in range(32):
            stream = peer.request("/ignore", length=4096)
            peer.data(stream, b"x" * 4096, ended=True)
            _assert(bytes(peer.result(stream)["body"]) == b"ignored", "synchronous response failed")
            healthy(peer)
    finally:
        peer.close()


def case_response_only_detach(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        for _ in range(32):
            stream = peer.request("/response-only", length=4096)
            peer.data(stream, b"x" * 4096, ended=True)
            _assert(bytes(peer.result(stream)["body"]) == b"response only", "response-only detach failed")
            healthy(peer)
    finally:
        peer.close()


def case_expect(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/upload", length=4, expect="100-continue")
        deadline = time.perf_counter() + TIMEOUT_S
        while not peer.informational.get(stream) and time.perf_counter() < deadline:
            peer.pump(deadline)
        _assert(peer.informational.get(stream) == [100], "body-open Expect did not receive one 100 Continue")
        _assert(not peer._record(stream)["ended"], "100 Continue ended the stream")
        peer.data(stream, b"body", ended=True)
        _assert(peer.result(stream)["status"] == 200, "100 Continue body was not consumed")
        assert_complete(control, b"body")
        zero = peer.request("/upload", length=0, ended=True, expect="100-continue")
        peer.result(zero)
        _assert(not peer.informational.get(zero), "bodyless request received 100 Continue")
        rejected = peer.request("/upload", length=4, expect="unsupported")
        result = peer.result(rejected)
        _assert(result["status"] == 417, f"unsupported Expect status: {result}")
        peer.data(rejected, b"body", ended=True)
        healthy(peer)
    finally:
        peer.close()


def case_expect_table_resize(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        healthy(peer)
        for table_size in (0, 4096, 128):
            peer._conn.update_settings({SettingCodes.HEADER_TABLE_SIZE: table_size})
            peer._flush()
            stream = peer.request("/upload", length=4, expect="100-continue")
            deadline = time.perf_counter() + TIMEOUT_S
            while not peer.informational.get(stream) and time.perf_counter() < deadline:
                peer.pump(deadline)
            _assert(peer.informational.get(stream) == [100], "Expect lost HPACK state after table resize")
            peer.data(stream, b"body", ended=True)
            _assert(peer.result(stream)["status"] == 200, "Expect resize final response failed")
            assert_complete(control, b"body")
            healthy(peer)
    finally:
        peer.close()


def assert_cancelled(control: Peer) -> None:
    observed = wait_status(control, lambda value: value["done"])
    _assert(observed["cancelled"] and observed["paired"], f"body cancellation did not cancel both endpoints: {observed}")


def case_cancellation(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/upload", length=1)
        wait_status(control, lambda value: not value["done"])
        peer._conn.reset_stream(stream, error_code=ErrorCodes.CANCEL)
        peer._flush()
        assert_cancelled(control)
        healthy(peer)
        expired = peer.request("/upload", length=1)
        result = peer.result(expired)
        _assert(result["reset"] is not None, f"body deadline did not reset stream: {result}")
        assert_cancelled(control)
        healthy(peer)
    finally:
        peer.close()


def case_deadline_progress(port: int, control: Peer) -> None:
    peer = Peer(port)
    try:
        handshake(peer)
        stream = peer.request("/upload", length=6)
        started = time.perf_counter()
        for count in range(1, 7):
            peer.data(stream, b"p", ended=count == 6)
            wait_status(control, lambda value: value["count"] == count)
            if count != 6:
                # Each interval is safely below the configured body deadline;
                # total elapsed input time exceeds that deadline.
                until = started + count * BODY_DEADLINE_S / 3
                while time.perf_counter() < until:
                    healthy(peer)
        _assert(time.perf_counter() - started > BODY_DEADLINE_S,
                "progress probe did not cross the initial body deadline")
        _assert(peer.result(stream)["status"] == 200, "real input progress did not renew body deadline")
        assert_complete(control, b"p" * 6)
        empty = peer.request("/upload", length=1)
        deadline = time.perf_counter() + 2 * BODY_DEADLINE_S
        while time.perf_counter() < deadline and not peer._record(empty)["ended"]:
            peer.data(empty, b"")
            peer.pump(min(deadline, time.perf_counter() + 0.03))
        _assert(peer._record(empty)["reset"] is not None,
                "empty DATA incorrectly renewed the body deadline")
        assert_cancelled(control)
        healthy(peer)
    finally:
        peer.close()


def case_shutdown(port: int, control: Peer) -> None:
    from hpack import Encoder
    peer = Peer(port)
    try:
        handshake(peer)
        accepted = peer.request("/upload", length=4)
        wait_status(control, lambda value: not value["done"])
        blocked = peer.request("/upload", length=1)
        healthy(peer)
        wait_status(control, lambda value: not value["done"])
        _assert(control.get("/shutdown") == b"shutdown", "shutdown trigger failed")
        peer.data(accepted, b"body", ended=True)
        peer._sock.settimeout(TIMEOUT_S)
        received = bytearray()
        refused = False
        goaway = False
        response_status = None
        response_body = bytearray()
        accepted_ended = False
        new_stream = blocked + 2
        while True:
            chunk = peer._sock.recv(65536)
            if not chunk:
                break
            received.extend(chunk)
            while len(received) >= 9:
                length = int.from_bytes(received[:3], "big")
                if len(received) < 9 + length:
                    break
                kind, flags = received[3:5]
                current = int.from_bytes(received[5:9], "big") & 0x7fffffff
                payload = bytes(received[9:9 + length])
                del received[:9 + length]
                if kind == 7:
                    _assert(int.from_bytes(payload[4:8], "big") == 0,
                            "graceful shutdown GOAWAY did not use NO_ERROR")
                    goaway = True
                    # hyper-h2 closes its send state at GOAWAY. A literal
                    # block probes admission while an accepted input blocks.
                    block = Encoder().encode([(b":method", b"GET"), (b":scheme", b"https"),
                                              (b":authority", b"localhost"), (b":path", b"/sibling")], huffman=False)
                    peer.send_raw(len(block).to_bytes(3, "big") + b"\x01\x05" + new_stream.to_bytes(4, "big") + block)
                elif kind == 1:
                    headers = dict(peer._conn.decoder.decode(payload, raw=True))
                    if current == accepted:
                        response_status = int(headers[b":status"])
                        accepted_ended |= bool(flags & 1)
                elif kind == 0 and current == accepted:
                    response_body.extend(payload)
                    accepted_ended |= bool(flags & 1)
                elif kind == 3:
                    if current == new_stream:
                        refused = int.from_bytes(payload, "big") == int(ErrorCodes.REFUSED_STREAM)
                    _assert(current != accepted, "accepted upload was reset during shutdown grace")
        _assert(goaway, "graceful shutdown did not send GOAWAY")
        _assert(refused, "new stream during shutdown was not refused")
        _assert(response_status == 200 and accepted_ended and response_body == b"4",
                f"accepted upload did not complete within grace: {response_status}, {response_body}, {accepted_ended}")
        # Fixture joins the blocked worker and asserts paired cancellation.
    finally:
        peer.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", help="run a precompiled fixture, including a sanitizer build")
    args = parser.parse_args()
    command = [args.fixture] if args.fixture else FIXTURE
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        port = _wait_ready(proc)
        control = Peer(port)
        try:
            handshake(control)
            for case in (case_first_flight, case_credit_and_trailers, case_padding,
                         case_early_fin_and_zero_body, case_standalone_receiver, case_synchronous_ignored_body, case_response_only_detach, case_expect, case_expect_table_resize, case_cancellation,
                         case_deadline_progress, case_shutdown):
                case(port, control)
                print(f"{case.__name__}: passed", flush=True)
        finally:
            control.close()
        rc = proc.wait(timeout=TIMEOUT_S)
        _assert(rc == 0, f"fixture exited {rc}: {proc.stderr.read()}")
    except Exception:
        proc.kill()
        proc.wait()
        sys.stderr.write(proc.stderr.read())
        raise
    print("HTTP/2 request streaming integration suite succeeded")


if __name__ == "__main__":
    main()
