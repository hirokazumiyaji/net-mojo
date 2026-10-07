from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.sys import size_of
from std.time import perf_counter_ns, sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net._reactor import ReactorToken
from net._sys.common import _OwnedFD, _set_no_sigpipe
from net.http._buffer import BufferBudget, SharedBufferBudget
from net.http._connection import (
    HttpConnection,
    STATE_SENDING_100,
    H1_ERROR_CAPACITY,
)
from net.http._deadline import NO_DEADLINE, now_ns
from net.http import (
    Headers,
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
)
from tests.support import (
    _content_length_of,
    _header_end,
    _response_complete,
    _socket_pair,
    _status_of,
    _tick_n,
    _to_bytes,
)


struct _HeadErrorHandler(Handler):
    var completed: Int

    def __init__(out self):
        self.completed = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/raise":
            writer.write_string("discarded")
            raise Error("test handler error")
        elif req.path == "/bad-frame":
            writer.headers.add(String("Transfer-Encoding"), String("chunked"))
        elif req.path == "/abort":
            var sender = writer.detach()
            sender.abort()
        else:
            writer.set_should_close(True)
            writer.write_string("alive")
        self.completed += 1


def _drain_head_error_to_eof[
    H: Handler
](mut server: Server, mut handler: H, mut client: TCPConn) raises -> List[Byte]:
    var out = List[Byte]()
    var scratch = Array[Byte, 8192](fill=0)
    var expires = Int(perf_counter_ns()) + 2_000_000_000
    var eof = False
    while not eof and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var count = client.try_read(Span(scratch))
            if count == 0:
                eof = True
            else:
                out.extend(Span(scratch)[0:count])
        except e:
            assert_equal(e.kind, NetErrorKind.timeout())
    assert_true(eof)
    return out^


def _check_completed_head_error(path: String) raises:
    for is_head in [True, False]:
        var config = ServerConfig.default()
        config.max_bytes_per_tick = 17
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var handler = _HeadErrorHandler()
        var client = dial_tcp(address, Timeout.seconds(1))
        var request = String("HEAD ") if is_head else String("GET ")
        request += path + String(" HTTP/1.1\r\nHost: x\r\n\r\n")
        client.write_all(request.as_bytes(), Timeout.seconds(1))
        var response = _drain_head_error_to_eof(server, handler, client)
        var wire = String(from_utf8_lossy=Span(response))
        assert_true(wire.startswith("HTTP/1.1 500 Internal Server Error\r\n"))
        assert_true(wire.find("\r\nContent-Length: 25\r\n") >= 0)
        assert_true(wire.find("\r\nConnection: close\r\n") >= 0)
        var header_end = wire.find("\r\n\r\n") + 4
        assert_true(header_end >= 4)
        assert_equal(handler.completed, 0 if path == "/raise" else 1)
        var body = String(from_utf8_lossy=wire.as_bytes()[header_end:])
        assert_equal(
            body,
            String("") if is_head else String("500 Internal Server Error"),
        )
        assert_equal(server.active_connections(), 0)
        assert_equal(server._budget.used(), 0)
        client.close()

        var sibling = dial_tcp(address, Timeout.seconds(1))
        sibling.write_all(
            "GET /sibling HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        var next = _drain_head_error_to_eof(server, handler, sibling)
        var sibling_wire = String(from_utf8_lossy=Span(next))
        assert_true(sibling_wire.startswith("HTTP/1.1 200 OK\r\n"))
        assert_true(sibling_wire.find("\r\nContent-Length: 5\r\n") >= 0)
        assert_true(sibling_wire.endswith("\r\n\r\nalive"))
        assert_equal(server.active_connections(), 0)
        assert_equal(server._budget.used(), 0)
        sibling.close()


struct _EmergencySaturationHandler(Handler):
    var budget: SharedBufferBudget
    var foreign: Int
    var admitted: Bool
    var remaining_after_reserve: Int

    def __init__(out self, var budget: SharedBufferBudget):
        self.budget = budget^
        self.foreign = 0
        self.admitted = False
        self.remaining_after_reserve = -1

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/saturate":
            self.foreign = self.budget.remaining()
            self.admitted = self.budget.try_reserve(self.foreign)
            self.remaining_after_reserve = self.budget.remaining()
            raise Error("emergency error reserve witness")
        writer.set_should_close(True)
        writer.write_string("alive")


@fieldwise_init
struct _EmergencyReadResult(Movable):
    var wire: List[Byte]
    var eof: Bool
    var unexpected_io: Bool


def _read_emergency_response[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    mut client: TCPConn,
) -> _EmergencyReadResult:
    var wire = List[Byte]()
    var scratch = Array[Byte, 1024](fill=0)
    var eof = False
    var unexpected_io = False
    var expires = Int(perf_counter_ns()) + 2_000_000_000
    while not eof and Int(perf_counter_ns()) < expires:
        try:
            _ = server.tick(handler, Timeout.nanoseconds(0))
        except:
            unexpected_io = True
            break
        try:
            var count = client.try_read(Span(scratch))
            if count == 0:
                eof = True
            else:
                wire.extend(Span(scratch)[0:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                unexpected_io = True
                break
    return _EmergencyReadResult(wire^, eof, unexpected_io)


@fieldwise_init
struct _EmergencySaturationResult(Movable):
    var is_head: Bool
    var response: _EmergencyReadResult
    var sibling: _EmergencyReadResult
    var foreign: Int
    var admitted: Bool
    var remaining_after_reserve: Int
    var held_after_error: Int
    var after_refund: Int
    var stopped: Bool
    var cleanup_failed: Bool
    var active_after_shutdown: Int
    var after_owner_drop: Int


def test_saturated_foreign_budget_keeps_get_and_head_handler_error_wire() raises:
    var results = List[_EmergencySaturationResult]()
    for is_head in [False, True]:
        var config = ServerConfig.default()
        config.max_bytes_per_tick = 17
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var observer = server._budget.copy()
        var handler = _EmergencySaturationHandler(observer.copy())
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var client = dial_tcp(address, Timeout.seconds(1))
        var method = String("HEAD") if is_head else String("GET")
        var request = method + String(" /saturate HTTP/1.1\r\nHost: x\r\n\r\n")
        client.write_all(request.as_bytes(), Timeout.seconds(1))
        var response = _read_emergency_response(server, handler, client)
        client.close()
        var held_after_error = observer.used()
        var foreign = handler.foreign
        var admitted = handler.admitted
        var remaining_after_reserve = handler.remaining_after_reserve
        if admitted:
            observer.release(foreign)
        handler.foreign = 0
        var after_refund = observer.used()

        var sibling = dial_tcp(address, Timeout.seconds(1))
        sibling.write_all(
            "GET /alive HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        var next = _read_emergency_response(server, handler, sibling)
        sibling.close()
        server.request_shutdown()
        var stopped = False
        var cleanup_failed = False
        var expires = Int(perf_counter_ns()) + 2_000_000_000
        while not stopped and Int(perf_counter_ns()) < expires:
            try:
                stopped = not server.tick(handler, Timeout.nanoseconds(0))
            except:
                cleanup_failed = True
                break
        var active = server.active_connections()
        _ = server^
        var after_owner_drop = observer.used()
        _ = handler^
        print(
            "emergency saturation",
            method,
            "wire_bytes",
            len(response.wire),
            "eof",
            response.eof,
            "foreign",
            foreign,
            "held",
            held_after_error,
            "after_refund",
            after_refund,
            "after_owner_drop",
            after_owner_drop,
        )
        results.append(
            _EmergencySaturationResult(
                is_head,
                response^,
                next^,
                foreign,
                admitted,
                remaining_after_reserve,
                held_after_error,
                after_refund,
                stopped,
                cleanup_failed,
                active,
                after_owner_drop,
            )
        )

    while len(results) > 0:
        var result = results.pop(0)
        assert_true(result.admitted)
        assert_true(result.foreign > 0)
        assert_equal(result.remaining_after_reserve, 0)
        assert_equal(result.held_after_error, result.foreign)
        assert_equal(result.after_refund, 0)
        assert_true(result.stopped)
        assert_false(result.cleanup_failed)
        assert_equal(result.active_after_shutdown, 0)
        assert_equal(result.after_owner_drop, 0)
        assert_true(result.response.eof)
        assert_false(result.response.unexpected_io)
        assert_true(result.sibling.eof)
        assert_false(result.sibling.unexpected_io)
        var sibling_wire = String(from_utf8_lossy=Span(result.sibling.wire))
        assert_true(sibling_wire.startswith("HTTP/1.1 200 OK\r\n"))
        assert_true(sibling_wire.endswith("\r\n\r\nalive"))
        var wire = String(from_utf8_lossy=Span(result.response.wire))
        assert_true(wire.startswith("HTTP/1.1 500 Internal Server Error\r\n"))
        assert_true(wire.find("\r\nContent-Length: 25\r\n") >= 0)
        assert_true(wire.find("\r\nConnection: close\r\n") >= 0)
        var header_end = _header_end(result.response.wire)
        assert_true(header_end >= 4)
        var body = String(
            from_utf8_lossy=Span(result.response.wire)[header_end:]
        )
        assert_equal(
            body,
            String("") if result.is_head else String(
                "500 Internal Server Error"
            ),
        )


def test_completed_head_handler_error_closes_without_body_and_keeps_sibling() raises:
    _check_completed_head_error(String("/raise"))


def test_completed_head_encoder_error_closes_without_body_and_keeps_sibling() raises:
    _check_completed_head_error(String("/bad-frame"))


def test_completed_head_detached_abort_closes_without_body_and_keeps_sibling() raises:
    _check_completed_head_error(String("/abort"))


def test_emergency_accept_exact_capacity_and_denial_preserve_foreign() raises:
    for capacity in [H1_ERROR_CAPACITY - 1, H1_ERROR_CAPACITY]:
        var config = ServerConfig.default()
        config.total_buffer_budget = capacity + 5
        var server = Server(config^)
        var observer = server._budget.copy()
        assert_true(observer.try_reserve(5))
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var client = dial_tcp(
            String("127.0.0.1:") + String(server.local_address().port),
            Timeout.seconds(1),
        )
        var admitted = capacity == H1_ERROR_CAPACITY
        var accepted = False
        var scratch = Array[Byte, 1](fill=42)
        var expires = Int(perf_counter_ns()) + 2_000_000_000
        while not accepted and Int(perf_counter_ns()) < expires:
            server._accept_pending(now_ns())
            if admitted:
                accepted = server.active_connections() == 1
            else:
                try:
                    accepted = client.try_read(Span(scratch)) == 0
                except e:
                    assert_equal(e.kind, NetErrorKind.timeout())
        assert_true(accepted)
        assert_equal(server.active_connections(), 1 if admitted else 0)
        assert_equal(len(server._conns), 1 if admitted else 0)
        assert_equal(
            observer.used(), 5 + (H1_ERROR_CAPACITY if admitted else 0)
        )
        if admitted:
            assert_equal(
                server._conns[0]._error_wire.capacity(), H1_ERROR_CAPACITY
            )
            assert_equal(len(server._conns[0]._error_wire), 0)
            assert_equal(
                server._conns[0]._error_ticket.amount, H1_ERROR_CAPACITY
            )
            server._close_conn(0)
            assert_equal(server._conns[0]._error_wire.capacity(), 0)
            assert_equal(server._conns[0]._error_ticket.amount, 0)
        client.close()
        _ = server^
        assert_equal(observer.used(), 5)
        observer.release(5)
        assert_equal(observer.used(), 0)


def test_emergency_server_drop_releases_unused_and_transferred_store() raises:
    for transferred in [False, True]:
        var server = Server(ServerConfig.default())
        var observer = server._budget.copy()
        assert_true(observer.try_reserve(5))
        var client = _interim_native_pair(server)
        var address = Int(server._conns[0]._error_wire.unsafe_ptr())
        assert_true(server._charge_read(0, 7))
        server._conns[0].append_bytes("partial".as_bytes())
        if transferred:
            server._send_error(0, 500)
            assert_equal(Int(server._conns[0].pending.unsafe_ptr()), address)
            assert_equal(server._conns[0].try_write_pending_capped(1), 1)
            assert_equal(server._conns[0].pending.capacity(), H1_ERROR_CAPACITY)
            assert_equal(server._conns[0]._error_wire.capacity(), 0)
        assert_equal(observer.used(), 5 + 7 + H1_ERROR_CAPACITY)
        _ = server^
        var refunded = observer.used()
        client.close()
        observer.release(5)
        assert_equal(refunded, 5)
        assert_equal(observer.used(), 0)


def test_emergency_body_denial_uses_prepaid_wire_without_foreign_refund() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var observer = server._budget.copy()
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nConnection:"
        " close\r\n\r\n".as_bytes(),
        Timeout.seconds(1),
    )
    var expires = Int(perf_counter_ns()) + 2_000_000_000
    while (
        len(server._conns) == 0 or server._conns[0].http1_body_reserved != 1
    ) and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.milliseconds(1))
    assert_equal(server._conns[0].http1_body_reserved, 1)
    assert_true(server._conns[0].buf.capacity() > 0)
    var address = Int(server._conns[0]._error_wire.unsafe_ptr())
    var foreign = observer.remaining()
    assert_true(observer.try_reserve(foreign))
    client.write_all("x".as_bytes(), Timeout.seconds(1))
    while (
        server._conns[0].pending_remaining() == 0
        and server._conns[0].active
        and Int(perf_counter_ns()) < expires
    ):
        server._pump_read(0, True, now_ns())
    assert_true(server._conns[0].active)
    assert_equal(Int(server._conns[0].pending.unsafe_ptr()), address)
    assert_equal(server._conns[0].pending.capacity(), H1_ERROR_CAPACITY)
    assert_equal(server._conns[0].http1_body_reserved, 0)
    assert_equal(server._conns[0].reserved, 1)
    assert_equal(
        observer.used(),
        foreign + H1_ERROR_CAPACITY + server._conns[0].buf.capacity() + 1,
    )
    var response = _read_emergency_response(server, handler, client)
    var held = observer.used()
    client.close()
    observer.release(foreign)
    _ = server^
    assert_true(response.eof)
    assert_false(response.unexpected_io)
    assert_equal(_status_of(response.wire), 503)
    _assert_body(response.wire, "503 Service Unavailable")
    assert_equal(held, foreign)
    assert_equal(observer.used(), 0)


def test_error_wire_transfer_partial_close_and_reuse_preserve_foreign() raises:
    for scenario in range(4):
        var config = ServerConfig.default()
        config.total_buffer_budget = [166, 165, 176, 175][
            scenario
        ] + 2 * H1_ERROR_CAPACITY
        var server = Server(config^)
        server._tick_date = "Sun, 06 Nov 1994 08:49:37 GMT"
        var foreign = _interim_native_pair(server)
        assert_true(server._charge_read(0, 5))
        server._conns[0].append_bytes("GET /".as_bytes())
        var client = _interim_native_pair(server)
        var address = Int(server._conns[1]._error_wire.unsafe_ptr())
        var reservation = 0
        if scenario >= 2:
            var old = List[Byte](capacity=7)
            old.extend("oldwire".as_bytes())
            assert_true(server._conns[1].set_pending(old^, server._budget))
            reservation = 3
            assert_true(server._budget.try_reserve(reservation))
            server._conns[1].reserved = reservation
        var before = server._budget.used()
        server._send_error(1, 503)
        assert_equal(server._conns[1].pending.capacity(), H1_ERROR_CAPACITY)
        assert_equal(Int(server._conns[1].pending.unsafe_ptr()), address)
        assert_equal(server._conns[1]._error_wire.capacity(), 0)
        assert_equal(server._conns[1]._error_ticket.amount, 0)
        assert_equal(
            server._budget.used(), before - (7 if scenario >= 2 else 0)
        )
        assert_equal(
            server._budget.used(), 5 + 2 * H1_ERROR_CAPACITY + reservation
        )
        assert_equal(server._conns[1].reserved, reservation)
        assert_equal(server._conns[1].try_write_pending_capped(11), 11)
        assert_equal(server._conns[1].pending.capacity(), H1_ERROR_CAPACITY)
        assert_equal(
            server._budget.used(), 5 + 2 * H1_ERROR_CAPACITY + reservation
        )
        var out = List[Byte]()
        _read_interim(client, out, 11)
        if scenario % 2 == 0:
            server._pump_send(1, True)
            _read_interim(client, out, 161)
            assert_equal(
                String(from_utf8_lossy=Span(out)),
                (
                    "HTTP/1.1 503 Service Unavailable\r\n"
                    "Content-Type: text/plain\r\n"
                    "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"
                    "Content-Length: 23\r\nConnection: close\r\n\r\n"
                    "503 Service Unavailable"
                ),
            )
        elif scenario == 1:
            server._conns[1].write_at = now_ns() - 1
            server._arm_deadline(1)
            server._expire_deadlines(now_ns())
        else:
            client.close()
            server._pump_send(1, True)
        assert_false(server._conns[1].active)
        assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
        assert_equal(server._conns[1].pending.capacity(), 0)
        assert_equal(server._conns[1].reserved, 0)
        assert_true(server._conns[0].active)
        if scenario != 3:
            client.close()
        var retry = _interim_native_pair(server)
        server._send_error(2, 503, is_head=True)
        assert_equal(server._conns[2].pending.capacity(), H1_ERROR_CAPACITY)
        assert_equal(len(server._conns[2].pending), 138)
        assert_equal(server._budget.used(), 5 + 2 * H1_ERROR_CAPACITY)
        server._close_conn(2)
        assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
        retry.close()
        foreign.close()
        server._close_conn(0)
        assert_equal(server._budget.used(), 0)


def _read_interim(mut client: TCPConn, mut out: List[Byte], wanted: Int) raises:
    var scratch = Array[Byte, 64](fill=0)
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while len(out) < wanted and Int(perf_counter_ns()) < expires:
        try:
            var count = client.try_read(Span(scratch))
            if count == 0:
                break
            out.extend(Span(scratch)[0:count])
        except e:
            assert_equal(e.kind, NetErrorKind.timeout())
    assert_equal(len(out), wanted)


def test_interim_static_full_exact_partial_and_denied_tail_preserve_foreign_budget() raises:
    for limit in [80, 93, 92]:
        var config = ServerConfig.default()
        config.total_buffer_budget = limit + 2 * H1_ERROR_CAPACITY
        config.max_bytes_per_tick = 81 if limit != 80 else 128
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var handler = _HelloHandler()
        var foreign = dial_tcp(address, Timeout.seconds(1))
        foreign.write_all("GET /".as_bytes(), Timeout.seconds(1))
        var expires = Int(perf_counter_ns()) + 1_000_000_000
        while (
            server._budget.used() != 5 + H1_ERROR_CAPACITY
            and Int(perf_counter_ns()) < expires
        ):
            _ = server.tick(handler, Timeout.nanoseconds(0))
        assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
        var client = dial_tcp(address, Timeout.seconds(1))
        while (
            server.active_connections() != 2
            and Int(perf_counter_ns()) < expires
        ):
            _ = server.tick(handler, Timeout.nanoseconds(0))
        assert_equal(server.active_connections(), 2)
        client.write_all(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect:"
            " 100-continue\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        while (
            server._conns[1].active
            and server._conns[1].buffered_len() == 0
            and Int(perf_counter_ns()) < expires
        ):
            _ = server.tick(handler, Timeout.nanoseconds(0))
        var out = List[Byte]()
        _read_interim(client, out, 25 if limit == 80 else 12)
        if limit == 92:
            assert_false(server._conns[1].active)
            assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
            assert_equal(server._conns[1].pending.capacity(), 0)
        else:
            assert_true(server._conns[1].active)
            if limit == 93:
                assert_equal(server._conns[1].pending.capacity(), 13)
                assert_equal(server._conns[1].state, STATE_SENDING_100)
                assert_equal(server._budget.used(), 93 + 2 * H1_ERROR_CAPACITY)
                while (
                    server._conns[1].pending_remaining() > 0
                    and Int(perf_counter_ns()) < expires
                ):
                    _ = server.tick(handler, Timeout.nanoseconds(0))
                _read_interim(client, out, 25)
            assert_equal(
                String(from_utf8_lossy=Span(out)),
                "HTTP/1.1 100 Continue\r\n\r\n",
            )
            assert_true(server._conns[1].sent_100)
            assert_equal(server._conns[1].pending.capacity(), 0)
            assert_equal(server._budget.used(), 80 + 2 * H1_ERROR_CAPACITY)
            server._close_conn(1)
            assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
        assert_true(server._conns[0].active)
        client.close()
        foreign.close()
        server._close_conn(0)
        assert_equal(server._budget.used(), 0)


def _interim_native_pair(mut server: Server) raises -> TCPConn:
    var pair = _socket_pair()
    var client = TCPConn(_OwnedFD(pair.first._take()))
    var accepted = TCPConn(_OwnedFD(pair.second._take()))
    _set_no_sigpipe(accepted.raw_fd())
    var token = server._reactor.register(accepted.raw_fd())
    var idx = len(server._conns)
    var entry = HttpConnection(
        token, Optional[TCPConn](accepted^), None, -1, -1, -1
    )
    assert_true(
        entry._reserve_error_wire(server._budget.copy(), H1_ERROR_CAPACITY)
    )
    var address = Int(entry._error_wire.unsafe_ptr())
    var used = server._budget.used()
    server._conns.append(entry^)
    assert_equal(Int(server._conns[idx]._error_wire.unsafe_ptr()), address)
    assert_equal(server._budget.used(), used)
    server._ensure_slot_map(token.slot)
    server._slot_map[token.slot] = idx
    server._active_conns += 1
    server._ensure_conn_arrays(idx)
    return client^


def test_interim_native_would_block_and_write_error_release_only_target() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 30 + 2 * H1_ERROR_CAPACITY
    var server = Server(config^)
    var foreign = _interim_native_pair(server)
    assert_true(server._charge_read(0, 5))
    server._conns[0].append_bytes("GET /".as_bytes())
    var client = _interim_native_pair(server)
    server._conns[1].conn.value().set_write_buffer(1024)
    var filler = Array[Byte, 4096](fill=42)
    var blocked = False
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while not blocked and Int(perf_counter_ns()) < expires:
        try:
            _ = server._conns[1].conn.value().try_write(Span(filler))
        except e:
            assert_equal(e.kind, NetErrorKind.timeout())
            blocked = True
    assert_true(blocked)
    assert_false(server._send_100(1))
    assert_true(server._conns[1].active)
    assert_equal(server._conns[1].state, STATE_SENDING_100)
    assert_equal(server._conns[1].pending.capacity(), 25)
    assert_equal(server._conns[1].bytes_this_tick, 0)
    assert_equal(server._budget.used(), 30 + 2 * H1_ERROR_CAPACITY)
    server._close_conn(1)
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
    client.close()

    var failed = _interim_native_pair(server)
    failed.close()
    assert_false(server._send_100(2))
    assert_false(server._conns[2].active)
    assert_true(server._conns[0].active)
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
    foreign.close()
    server._close_conn(0)
    assert_equal(server._budget.used(), 0)


def test_read_into_native_span_count_would_block_and_eof() raises:
    var pair = _socket_pair()
    var client = TCPConn(_OwnedFD(pair.first._take()))
    var accepted = TCPConn(_OwnedFD(pair.second._take()))
    var conn = HttpConnection(
        ReactorToken(0, 0), Optional[TCPConn](accepted^), None, 0, -1, -1
    )
    var scratch = Array[Byte, 3](fill=0)
    var blocked = False
    try:
        _ = conn.try_read_into(Span(scratch))
    except e:
        assert_equal(e.kind, NetErrorKind.timeout())
        blocked = True
    assert_true(blocked)
    client.write_all("abcdef".as_bytes(), Timeout.seconds(1))
    assert_equal(conn.try_read_into(Span(scratch)), 3)
    assert_equal(String(from_utf8_lossy=Span(scratch)), "abc")
    assert_equal(conn.try_read_into(Span(scratch)), 3)
    assert_equal(String(from_utf8_lossy=Span(scratch)), "def")
    client.close()
    assert_equal(conn.try_read_into(Span(scratch)), 0)
    conn.close()


def test_read_scratch_fits_small_budget_preserves_fairness_and_denied_admission() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 12 + 2 * H1_ERROR_CAPACITY
    config.max_bytes_per_tick = 7
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _HelloHandler()
    var foreign = dial_tcp(address, Timeout.seconds(1))
    foreign.write_all("GET /".as_bytes(), Timeout.seconds(1))
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while (
        server._budget.used() != 5 + H1_ERROR_CAPACITY
        and Int(perf_counter_ns()) < expires
    ):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
    var client = dial_tcp(address, Timeout.seconds(1))
    while server.active_connections() != 2 and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 2)
    client.write_all("GET /ab".as_bytes(), Timeout.seconds(1))
    while (
        server._conns[1].buffered_len() != 7
        and Int(perf_counter_ns()) < expires
    ):
        server._pump_read(1, True, now_ns())
    assert_equal(server._conns[1].buf.capacity(), 7)
    assert_equal(server._conns[1].bytes_this_tick, 7)
    assert_equal(server._budget.used(), 12 + 2 * H1_ERROR_CAPACITY)
    assert_equal(String(from_utf8_lossy=Span(server._conns[1].buf)), "GET /ab")
    client.close()
    server._conns[1].bytes_this_tick = 0
    while not server._conns[1].read_eof and Int(perf_counter_ns()) < expires:
        server._pump_read(1, True, now_ns())
    assert_true(server._conns[1].read_eof)
    server._close_conn(1)
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)

    var denied = dial_tcp(address, Timeout.seconds(1))
    while server.active_connections() != 2 and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 2)
    denied.write_all("GET /abc".as_bytes(), Timeout.seconds(1))
    while (
        server._conns[1].buffered_len() != 7
        and Int(perf_counter_ns()) < expires
    ):
        server._pump_read(1, True, now_ns())
    assert_equal(server._conns[1].bytes_this_tick, 7)
    server._pump_read(1, True, now_ns())
    assert_equal(server._conns[1].buffered_len(), 7)
    assert_equal(server._budget.used(), 12 + 2 * H1_ERROR_CAPACITY)
    server._conns[1].bytes_this_tick = 0
    while server._conns[1].active and Int(perf_counter_ns()) < expires:
        server._pump_read(1, True, now_ns())
    assert_false(server._conns[1].active)
    assert_true(server._conns[0].active)
    assert_equal(server._conns[0].buf.capacity(), 5)
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
    denied.close()
    foreign.close()
    server._close_conn(0)
    assert_equal(server._budget.used(), 0)


def _pending_test_connection() raises -> HttpConnection:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(
        String("127.0.0.1:") + String(listener.local_address().port),
        Timeout.seconds(1),
    )
    var accepted = listener.accept(Timeout.seconds(1))
    client.close()
    return HttpConnection(
        ReactorToken(0, 0), Optional[TCPConn](accepted^), None, 0, -1, -1
    )


def test_pending_adoption_and_replacement_charge_capacity() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(20)
    var first = List[Byte](capacity=8)
    first.append(42)
    assert_true(conn.set_pending(first^, budget))
    assert_equal(budget.used, 8)
    var second = List[Byte](capacity=12)
    second.append(43)
    assert_true(conn.set_pending(second^, budget))
    assert_equal(budget.used, 12)
    assert_equal(conn.pending.capacity(), 12)
    assert_equal(len(conn.pending), 1)
    assert_equal(conn.pending[0], 43)
    conn.advance_pending(1)
    var third = List[Byte](capacity=8)
    third.append(44)
    assert_true(conn.append_pending(third^, budget))
    assert_equal(budget.used, 8)
    assert_equal(conn.pending_offset, 0)
    assert_equal(conn.pending[0], 44)


def test_precharged_wire_transfer_releases_only_old_pending_capacity() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(20)
    var old = List[Byte](capacity=8)
    old.append(42)
    assert_true(conn.set_pending(old^, budget))
    assert_true(budget.try_reserve(12))
    var wire = List[Byte](capacity=12)
    wire.append(43)
    conn._set_reserved_pending(wire^, budget)
    assert_equal(budget.used, 12)
    assert_equal(conn.pending.capacity(), 12)
    assert_equal(conn.pending[0], 43)


def test_pending_replacement_requires_old_plus_incoming_peak() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(19)
    var first = List[Byte](capacity=8)
    first.append(42)
    assert_true(conn.set_pending(first^, budget))
    var second = List[Byte](capacity=12)
    second.append(43)
    assert_false(conn.set_pending(second^, budget))
    assert_equal(budget.used, 8)
    assert_equal(conn.pending.capacity(), 8)
    assert_equal(conn.pending[0], 42)


def test_precharged_append_preserves_full_peak_and_foreign_charge() raises:
    for offset in [0, 3]:
        for admitted in [True, False]:
            var conn = _pending_test_connection()
            var target = 12 - offset
            var budget = BufferBudget(5 + 8 + 4 + target - Int(not admitted))
            assert_true(budget.try_reserve(5))
            var old = List[Byte](capacity=8)
            for i in range(8):
                old.append(Byte(i))
            assert_true(conn.set_pending(old^, budget))
            conn.advance_pending(offset)
            assert_true(budget.try_reserve(4))
            var incoming = List[Byte](length=4, fill=42)
            assert_equal(
                conn._append_reserved_pending(incoming^, budget), admitted
            )
            assert_equal(budget.used, 5 + (target if admitted else 8))
            assert_equal(conn.pending.capacity(), target if admitted else 8)
            assert_equal(conn.pending_offset, 0 if admitted else offset)
            assert_equal(len(conn.pending), target if admitted else 8)
            assert_equal(conn.pending[0], Byte(offset if admitted else 0))
            assert_equal(
                conn.pending[len(conn.pending) - 1], Byte(42 if admitted else 7)
            )
            var capacity = conn.pending.capacity()
            conn.clear_pending()
            budget.release(capacity)
            assert_equal(budget.used, 5)


def test_precharged_append_adopts_without_double_charge_and_keeps_tls_retry() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(17)
    assert_true(budget.try_reserve(5))
    var old = List[Byte](length=8, fill=42)
    assert_true(conn.set_pending(old^, budget))
    conn.advance_pending(8)
    conn.tls_write_retry_length = 4
    conn.tls_write_would_block = True
    conn.tls_write_wants_read = True
    assert_true(budget.try_reserve(4))
    var incoming = List[Byte](length=4, fill=43)
    assert_true(conn._append_reserved_pending(incoming^, budget))
    assert_equal(budget.used, 9)
    assert_equal(conn.pending.capacity(), 4)
    assert_equal(conn.pending_offset, 0)
    assert_equal(conn.pending[0], 43)
    assert_equal(conn.tls_write_retry_length, 4)
    assert_true(conn.tls_write_would_block)
    assert_true(conn.tls_write_wants_read)


def test_pending_append_compacts_and_charges_three_allocation_peak() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(28)
    var first = List[Byte](capacity=8)
    for i in range(8):
        first.append(Byte(i))
    assert_true(conn.set_pending(first^, budget))
    conn.advance_pending(2)
    var second = List[Byte](length=4, fill=42)
    assert_true(conn.append_pending(second^, budget))
    assert_equal(budget.used, 16)
    assert_equal(conn.pending.capacity(), 16)
    assert_equal(conn.pending_offset, 0)
    assert_equal(len(conn.pending), 10)
    assert_equal(conn.pending[0], 2)
    assert_equal(conn.pending[5], 7)
    assert_equal(conn.pending[6], 42)
    assert_equal(conn.pending[9], 42)


def test_pending_failed_append_preserves_unsent_queue_and_budget() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(21)
    var first = List[Byte](capacity=8)
    for i in range(8):
        first.append(Byte(i))
    assert_true(conn.set_pending(first^, budget))
    conn.advance_pending(2)
    var second = List[Byte](length=4, fill=42)
    assert_false(conn.append_pending(second^, budget))
    assert_equal(budget.used, 8)
    assert_equal(conn.pending.capacity(), 8)
    assert_equal(conn.pending_offset, 2)
    assert_equal(len(conn.pending), 8)
    assert_equal(conn.pending[0], 0)
    assert_equal(conn.pending[7], 7)


def test_pending_append_reuses_capacity_without_duplicate_tail() raises:
    var conn = _pending_test_connection()
    var budget = BufferBudget(12)
    var first = List[Byte](capacity=8)
    for i in range(8):
        first.append(Byte(i))
    assert_true(conn.set_pending(first^, budget))
    conn.advance_pending(6)
    var second = List[Byte](length=4, fill=42)
    assert_true(conn.append_pending(second^, budget))
    assert_equal(budget.used, 8)
    assert_equal(conn.pending.capacity(), 8)
    assert_equal(len(conn.pending), 6)
    assert_equal(conn.pending[0], 6)
    assert_equal(conn.pending[1], 7)
    assert_equal(conn.pending[5], 42)


def test_pending_clear_drops_allocation() raises:
    var conn = _pending_test_connection()
    var bytes = List[Byte](capacity=8)
    bytes.append(42)
    var budget = BufferBudget(8)
    assert_true(conn.set_pending(bytes^, budget))
    conn.clear_pending()
    assert_equal(conn.pending.capacity(), 0)
    assert_equal(conn.pending_offset, 0)


def test_pending_capacity_released_on_full_send_error_close_and_reuse() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512 + H1_ERROR_CAPACITY
    config.max_bytes_per_tick = 1
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _HelloHandler()
    var client = dial_tcp(address, Timeout.seconds(1))
    _tick_n(server, handler, 2)
    var bytes = List[Byte](capacity=8)
    bytes.extend(String("xyz").as_bytes())
    assert_true(server._conns[0].set_pending(bytes^, server._budget))
    server._pump_send(0, True)
    assert_equal(server._budget.used(), 8 + H1_ERROR_CAPACITY)
    assert_equal(server._conns[0].pending_offset, 1)
    for _ in range(2):
        server._conns[0].reset_tick()
        server._pump_send(0, True)
    assert_equal(server._budget.used(), H1_ERROR_CAPACITY)
    assert_equal(server._conns[0].pending.capacity(), 0)
    assert_true(server._conns[0].active)
    server._send_error(0, 503)
    assert_equal(server._conns[0].buf.capacity(), 0)
    assert_equal(server._conns[0].reserved, 0)
    assert_equal(server._budget.used(), server._conns[0].pending.capacity())
    assert_equal(server._budget.used(), H1_ERROR_CAPACITY)
    assert_equal(len(server._conns[0].pending), 161)
    var out = _drain_until_eof_driven(server, handler, client)
    assert_true(String(from_utf8_lossy=Span(out)).find("503") >= 0)
    assert_equal(server._budget.used(), 0)
    assert_equal(server._conns[0].pending.capacity(), 0)
    client.close()
    var second = dial_tcp(address, Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(len(server._conns), 1)
    var queued = List[Byte](capacity=12)
    queued.append(42)
    assert_true(server._conns[0].set_pending(queued^, server._budget))
    server._close_conn(0)
    assert_equal(server._budget.used(), 0)
    assert_equal(server._conns[0].pending.capacity(), 0)
    second.close()


def test_receive_compaction_consumption_close_and_slot_reuse() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 256 + H1_ERROR_CAPACITY
    var server = Server(config^)
    var listener = listen_tcp("127.0.0.1:0")
    server.add_listener(listener^)
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _HelloHandler()
    var client = dial_tcp(String(address), Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(len(server._conns), 1)
    assert_true(server._charge_read(0, 8))
    for i in range(8):
        server._conns[0].buf.append(Byte(i))
    server._consume_receive(0, 5)
    assert_equal(server._budget.used(), 8 + H1_ERROR_CAPACITY)
    assert_equal(server._conns[0].buf.capacity(), 8)
    assert_equal(len(server._conns[0].buf), 3)
    assert_equal(server._conns[0].buf[0], 5)
    assert_equal(server._conns[0].buf[2], 7)
    server._consume_receive(0, 3)
    assert_equal(server._budget.used(), H1_ERROR_CAPACITY)
    assert_equal(server._conns[0].buf.capacity(), 0)
    assert_true(server._charge_read(0, 12))
    assert_equal(server._budget.used(), 12 + H1_ERROR_CAPACITY)
    assert_true(server._charge_read(0, 96))
    var head = String(
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 40\r\n\r\n"
    )
    server._conns[0].append_bytes(head.as_bytes())
    server._pump_parse(0, handler, 0)
    assert_equal(server._conns[0].reserved, 0)
    assert_equal(server._conns[0].http1_body_reserved, 40)
    assert_equal(server._budget.used(), 136 + H1_ERROR_CAPACITY)
    assert_true(server._budget.try_reserve(7))
    server._conns[0].reserved = 7
    server._close_conn(0)
    assert_equal(server._budget.used(), 0)
    assert_equal(server._conns[0].http1_body_reserved, 0)
    assert_equal(server._conns[0].buf.capacity(), 0)
    client.close()
    var second = dial_tcp(String(address), Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(len(server._conns), 1)
    assert_true(server._conns[0].active)
    assert_equal(server._conns[0].reserved, 0)
    assert_equal(server._conns[0].buf.capacity(), 0)
    assert_equal(server._budget.used(), H1_ERROR_CAPACITY)
    second.close()


struct _HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.method == "GET" and req.path == "/hello":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _EchoHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/echo":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/octet-stream")
            )
            for i in range(len(req.body)):
                writer.body.append(req.body[i])
        elif req.path == "/hello":
            writer.set_status(200)
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _BodyCountHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        for i in range(len(req.body)):
            assert_equal(req.body[i], Byte(ord("b")))
        writer.write_string(String(len(req.body)))


struct _BufferedSixKHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var body = Array[Byte, 6000](fill=Byte(ord("b")))
        writer.write(Span(body))


def test_response_needs_combined_body_and_wire_capacity() raises:
    # The body and framed wire must coexist at the 12097-byte boundary.
    var handler = _BufferedSixKHandler()
    for limit in [12096, 12097]:
        var config = ServerConfig.default()
        config.total_buffer_budget = limit + H1_ERROR_CAPACITY
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var client = dial_tcp(
            String("127.0.0.1:") + String(server.local_address().port),
            Timeout.seconds(1),
        )
        var request = String(
            "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        )
        var out = _exchange(server, handler, client, request)
        assert_equal(_status_of(out), 500 if limit == 12096 else 200)
        if limit == 12097:
            assert_equal(_content_length_of(out), 6000)
            _assert_body(out, String("b") * 6000)
        assert_equal(server._budget.used(), 0)
        client.close()


struct _JsonHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/json":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/json")
            )
            for i in range(1024):
                writer.body.append(Byte(ord("a") + (i % 26)))
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _BigJsonHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/json":
            writer.set_status(200)
            for i in range(262144):
                writer.body.append(Byte(ord("j") + (i % 8)))
        elif req.path == "/hello":
            writer.set_status(200)
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _BoomHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        raise Error("boom")


struct _WorkspaceHandler(Handler):
    var action: Int
    var workspace: Int

    def __init__(out self):
        self.action = 0
        self.workspace = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.workspace = writer._body_budget.value().remaining()
        writer.write_string(String("a") * 64)
        if self.action == 1:
            raise Error("after body allocation")
        if self.action == 2:
            writer.body.reserve(1024)
            return
        if self.action == 3:
            writer.headers.add(String("Content-Length"), String("999"))
        writer.write_string(String("b") * 64)


struct _SharedBodyHandler(Handler):
    var budget: SharedBufferBudget
    var available: Int
    var with_body: Int
    var foreign_admitted: Bool

    def __init__(out self, var budget: SharedBufferBudget):
        self.budget = budget^
        self.available = -1
        self.with_body = -1
        self.foreign_admitted = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.available = self.budget.remaining()
        self.foreign_admitted = self.budget.try_reserve(7)
        writer.write_string("body1234")
        self.with_body = self.budget.used()
        if self.foreign_admitted:
            self.budget.release(7)


def test_handler_writer_charges_only_its_body_and_allows_foreign_admission() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512 + H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _SharedBodyHandler(server._budget.copy())
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    )
    client.close()
    assert_equal(_status_of(out), 200)
    _assert_body(out, "body1234")
    assert_equal(handler.available, 512)
    assert_true(handler.foreign_admitted)
    assert_equal(handler.with_body, 15 + H1_ERROR_CAPACITY)
    assert_equal(server._budget.used(), 0)


struct _HeaderCapacityHandler(Handler):
    var budget: SharedBufferBudget
    var before: Int
    var after: Int
    var names_capacity: Int
    var lower_capacity: Int
    var values_capacity: Int
    var raw_capacity: Int
    var raw_matches: Bool
    var original_name_capacity: Int
    var lowercase_name_capacity: Int

    def __init__(out self, var budget: SharedBufferBudget):
        self.budget = budget^
        self.before = -1
        self.after = -1
        self.names_capacity = -1
        self.lower_capacity = -1
        self.values_capacity = -1
        self.raw_capacity = -1
        self.raw_matches = False
        self.original_name_capacity = -1
        self.lowercase_name_capacity = -1

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var value = Array[Byte, 64](fill=Byte(ord("a")))
        self.before = self.budget.used()
        writer.headers.add_bytes(String("X-Probe"), Span(value))
        self.after = self.budget.used()
        self.original_name_capacity = writer.headers._names[0].capacity_bytes()
        self.lowercase_name_capacity = writer.headers._lower_names[
            0
        ].capacity_bytes()
        self.names_capacity = writer.headers._names.capacity()
        self.lower_capacity = writer.headers._lower_names.capacity()
        self.values_capacity = writer.headers._values.capacity()
        self.raw_capacity = writer.headers._values[0].capacity()
        self.raw_matches = len(writer.headers._values[0]) == 64
        for i in range(len(writer.headers._values[0])):
            self.raw_matches = (
                self.raw_matches and writer.headers._values[0][i] == value[i]
            )
        writer.set_status(204)


def test_http1_handler_charges_owned_header_backing_before_return() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var observer = server._budget.copy()
    var foreign_admitted = observer.try_reserve(5)
    var handler = _HeaderCapacityHandler(observer.copy())
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".as_bytes(),
        Timeout.seconds(1),
    )
    var out = List[Byte]()
    var scratch = Array[Byte, 1024](fill=0)
    var eof = False
    var unexpected_io = False
    var expires = Int(perf_counter_ns()) + 2_000_000_000
    while not eof and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.milliseconds(1))
        try:
            var count = client.try_read(Span(scratch))
            if count == 0:
                eof = True
            else:
                out.extend(Span(scratch)[0:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                unexpected_io = True
                break
    client.close()
    server.request_shutdown()
    var stopped = False
    expires = Int(perf_counter_ns()) + 2_000_000_000
    while not stopped and Int(perf_counter_ns()) < expires:
        stopped = not server.tick(handler, Timeout.milliseconds(1))
    var active = server.active_connections()
    var before_owner_drop = observer.used()
    var before = handler.before
    var after = handler.after
    var names_capacity = handler.names_capacity
    var lower_capacity = handler.lower_capacity
    var values_capacity = handler.values_capacity
    var raw_capacity = handler.raw_capacity
    var raw_matches = handler.raw_matches
    var original_name_capacity = handler.original_name_capacity
    var lowercase_name_capacity = handler.lowercase_name_capacity
    _ = server^
    var after_owner_drop = observer.used()
    if foreign_admitted:
        observer.release(5)
    var after_refund = observer.used()
    _ = handler^

    assert_true(foreign_admitted)
    assert_false(unexpected_io)
    assert_true(eof)
    assert_true(stopped)
    assert_equal(active, 0)
    assert_equal(before_owner_drop, 5)
    assert_equal(after_owner_drop, 5)
    assert_equal(after_refund, 0)
    assert_equal(_status_of(out), 204)
    var wire = String(from_utf8_lossy=Span(out))
    assert_true(wire.find("\r\nX-Probe: " + String("a") * 64 + "\r\n") >= 0)
    assert_true(raw_matches)
    assert_equal(names_capacity, 1)
    assert_equal(lower_capacity, 1)
    assert_equal(values_capacity, 1)
    assert_equal(raw_capacity, 64)
    var known = (
        names_capacity * size_of[String]()
        + lower_capacity * size_of[String]()
        + values_capacity * size_of[List[Byte]]()
        + raw_capacity
    )
    assert_equal(known, 64 + 2 * size_of[String]() + size_of[List[Byte]]())
    assert_equal(
        after - before,
        known
        + original_name_capacity
        + lowercase_name_capacity
        + 2 * String.REF_COUNT_SIZE,
    )


struct _HeaderAdoptionErrorHandler(Handler):
    var budget: SharedBufferBudget
    var mode: Int
    var foreign: Int
    var room: Int
    var header_capacity: Int

    def __init__(out self, var budget: SharedBufferBudget, mode: Int):
        self.budget = budget^
        self.mode = mode
        self.foreign = 0
        self.room = -1
        self.header_capacity = -1

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var room: Int
        if self.mode < 2:
            var headers = Headers()
            headers.add(String("X-Owned"), String("a"))
            headers._values[0].reserve(256)
            writer.headers = headers^
            var known = (
                256
                + 2 * size_of[String]()
                + size_of[List[Byte]]()
                + writer.headers._names[0].capacity_bytes()
                + writer.headers._lower_names[0].capacity_bytes()
                + 2 * String.REF_COUNT_SIZE
            )
            self.header_capacity = known
            room = known + 128 if self.mode == 0 else known - 1
            writer.set_status(204)
        else:
            if self.mode == 2:
                var raw = Array[Byte, 64](fill=97)
                writer.headers.add_bytes(String("X-Owned"), Span(raw))
            else:
                writer.headers.add(
                    String("Transfer-Encoding"), String("chunked")
                )
            var known = (
                writer.headers._names.capacity() * size_of[String]()
                + writer.headers._lower_names.capacity() * size_of[String]()
                + writer.headers._values.capacity() * size_of[List[Byte]]()
                + writer.headers._values[0].capacity()
                + writer.headers._names[0].capacity_bytes()
                + writer.headers._lower_names[0].capacity_bytes()
                + 2 * String.REF_COUNT_SIZE
            )
            self.header_capacity = known
            room = max(0, (140 if req.method == "HEAD" else 165) - known)
        self.room = room
        self.foreign = self.budget.remaining() - room
        assert_true(self.budget.try_reserve(self.foreign))
        if self.mode == 2:
            raise Error("after budgeted header")


def _check_header_replacement_and_error(mode: Int, is_head: Bool) raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var observer = server._budget.copy()
    assert_true(observer.try_reserve(5))
    var handler = _HeaderAdoptionErrorHandler(observer.copy(), mode)
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    var method = String("HEAD") if is_head else String("GET")
    client.write_all(
        (
            method + " / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    var response = _drain_head_error_to_eof(server, handler, client)
    client.close()
    var retained_foreign = 5 + handler.foreign
    var room = handler.room
    var header_capacity = handler.header_capacity
    var remaining = observer.used()
    observer.release(retained_foreign)
    _ = server^
    _ = handler^
    assert_equal(remaining, retained_foreign)
    assert_equal(observer.used(), 0)
    if mode == 2:
        assert_equal(room, 0)
        assert_equal(
            header_capacity,
            64
            + 2 * size_of[String]()
            + size_of[List[Byte]]()
            + String("X-Owned").capacity_bytes()
            + String.INLINE_CAPACITY
            + 2 * String.REF_COUNT_SIZE,
        )
    elif mode == 3:
        assert_equal(room, 5 if is_head else 30)
    else:
        assert_equal(
            header_capacity,
            256
            + 2 * size_of[String]()
            + size_of[List[Byte]]()
            + String("X-Owned").capacity_bytes()
            + String.INLINE_CAPACITY
            + 2 * String.REF_COUNT_SIZE,
        )
        assert_equal(
            room, header_capacity + 128 if mode == 0 else header_capacity - 1
        )
    assert_equal(_status_of(response), 204 if mode == 0 else 500)
    if mode == 0:
        assert_true(
            String(from_utf8_lossy=Span(response)).find("\r\nX-Owned: a\r\n")
            >= 0
        )
    else:
        var wire = String(from_utf8_lossy=Span(response))
        assert_true(wire.find("\r\nContent-Length: 25\r\n") >= 0)
        assert_true(
            wire.endswith("\r\n\r\n") if is_head else wire.endswith(
                "\r\n\r\n500 Internal Server Error"
            )
        )


def test_http1_header_replacement_admits_retained_capacity() raises:
    for mode in [0, 1]:
        for is_head in [False, True]:
            _check_header_replacement_and_error(mode, is_head)


def test_http1_header_error_destroys_backing_before_wire_reservation() raises:
    for mode in [2, 3]:
        for is_head in [False, True]:
            _check_header_replacement_and_error(mode, is_head)


struct _RequestWorkspaceHandler(Handler):
    var action: Int
    var workspace: Int

    def __init__(out self):
        self.action = 0
        self.workspace = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        assert_equal(req.body.capacity(), 5)
        self.workspace = writer._body_budget.value().remaining()
        writer.write_string("reply")
        if self.action == 1:
            raise Error("after borrowed request")
        if self.action == 2:
            writer.headers.add(String("Content-Length"), String("999"))
        if self.action == 3:
            _ = writer.detach()


def _check_request_capacity_workspace(request: String) raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512 + 2 * H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _RequestWorkspaceHandler()
    var waiting = dial_tcp(address, Timeout.seconds(1))
    waiting.write_all("GET /".as_bytes(), Timeout.seconds(1))
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while (
        server._budget.used() != 5 + H1_ERROR_CAPACITY
        and Int(perf_counter_ns()) < expires
    ):
        _ = server.tick(handler, Timeout.milliseconds(1))
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
    for action in range(4):
        handler.action = action
        var client = dial_tcp(address, Timeout.seconds(1))
        var out = _exchange(
            server,
            handler,
            client,
            request,
        )
        assert_equal(_status_of(out), 200 if action == 0 else 500)
        assert_equal(handler.workspace, 502)
        assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
        client.close()
    server._close_conn(0)
    assert_equal(server._budget.used(), 0)
    waiting.close()


def test_request_capacity_limits_workspace_and_returns_on_terminal_paths() raises:
    _check_request_capacity_workspace(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection:"
        " close\r\n\r\nbody!"
    )


def test_chunked_capacity_limits_workspace_and_returns_on_terminal_paths() raises:
    _check_request_capacity_workspace(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding:"
        " chunked\r\nConnection:"
        " close\r\n\r\n2\r\nbo\r\n3\r\ndy!\r\n0\r\nX-Final: yes\r\n\r\n"
    )


def test_chunked_copy_peak_is_rejected_before_handler() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 8192 + H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _BodyCountHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    var request = (
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n1770\r\n"
        )
        + String("b") * 6000
        + String("\r\n0\r\n\r\n")
    )
    var out = _exchange(server, handler, client, request)
    assert_equal(_status_of(out), 503)
    assert_equal(server._budget.used(), 0)
    client.close()


def test_partial_chunked_body_does_not_reserve_decoded_allocation() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512 + H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
        "Connection: close\r\n\r\n2\r\nbo\r\n3\r\nd".as_bytes(),
        Timeout.seconds(1),
    )
    _tick_n(server, handler, 4)
    assert_equal(server._conns[0].http1_body_reserved, 0)
    assert_equal(
        server._budget.used(),
        server._conns[0].buf.capacity() + H1_ERROR_CAPACITY,
    )
    var out = _exchange(server, handler, client, "y!\r\n0\r\n\r\n")
    assert_equal(_status_of(out), 200)
    _assert_body(out, "body!")
    assert_equal(server._budget.used(), 0)
    client.close()


def test_request_copy_peak_is_rejected_before_receiving_body() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 8192 + H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _BodyCountHandler()
    var client = dial_tcp(address, Timeout.seconds(1))
    var out = _exchange(
        server,
        handler,
        client,
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6000\r\n\r\n",
    )
    assert_equal(_status_of(out), 503)
    assert_equal(server._budget.used(), 0)
    client.close()


def test_writer_workspace_returns_on_success_handler_and_encoder_errors() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512 + 2 * H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _WorkspaceHandler()
    var waiting = dial_tcp(address, Timeout.seconds(1))
    waiting.write_all("GET /".as_bytes(), Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
    for action in range(4):
        handler.action = action
        var client = dial_tcp(address, Timeout.seconds(1))
        var out = _exchange(
            server,
            handler,
            client,
            "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        )
        assert_equal(_status_of(out), 200 if action == 0 else 500)
        assert_equal(handler.workspace, 507)
        assert_equal(server._budget.used(), 5 + H1_ERROR_CAPACITY)
        client.close()
    server._close_conn(0)
    assert_equal(server._budget.used(), 0)
    waiting.close()


struct _HugeHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(200)
        writer.write_string(String("a") * (1024 * 1024 + 1))


struct _DirectHugeHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        # Bypasses write()/write_string() on purpose: the server must
        # still enforce the cap after the handler returns.
        writer.set_status(200)
        for _ in range(1024 * 1024 + 1):
            writer.body.append(Byte(ord("z")))


struct _TwoHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/one":
            writer.set_status(200)
            writer.write_string("ONE")
        elif req.path == "/two":
            writer.set_status(200)
            writer.write_string("TWO")
        else:
            writer.set_status(404)
            writer.write_string("missing")


def _exchange[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    client: TCPConn,
    request: String,
    max_ticks: Int = 300,
) raises -> List[Byte]:
    client.write_all(request.as_bytes(), Timeout.seconds(2))
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(max_ticks):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    return out^


def _assert_body(wire: List[Byte], expected: String) raises:
    var end = _header_end(wire)
    assert_true(end >= 0)
    var length = _content_length_of(wire)
    assert_equal(length, expected.byte_length())
    assert_equal(len(wire), end + length)
    var expected_bytes = expected.as_bytes()
    for i in range(len(expected_bytes)):
        assert_equal(wire[end + i], expected_bytes[i])


def test_hello_keep_alive_two_requests() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var first = _exchange(
        server,
        handler,
        client,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(first), 200)
    _assert_body(first, "hello")
    assert_equal(server.active_connections(), 1)
    var second = _exchange(
        server,
        handler,
        client,
        "GET /missing HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(second), 404)
    _assert_body(second, "missing")
    assert_equal(server.active_connections(), 1)
    client.close()
    _tick_n(server, handler, 50)
    assert_equal(server.active_connections(), 0)


def test_pipeline_order_preserved() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _TwoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost:"
            " x\r\nConnection: close\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
            continue
        if len(out) > 0 and _header_end(out) > 0:
            # Two small responses expected; stop once both arrived.
            var text = String(from_utf8_lossy=Span(out))
            if text.find("TWO") >= 0:
                break
    var text = String(from_utf8_lossy=Span(out))
    var one_at = text.find("ONE")
    var two_at = text.find("TWO")
    assert_true(one_at >= 0)
    assert_true(two_at >= 0)
    assert_true(one_at < two_at)
    client.close()


def _drain_until_eof(
    client: TCPConn, max_rounds: Int = 500
) raises -> List[Byte]:
    # Drains until EOF: the server under test always ends these flows
    # with Connection: close, so FIN terminates the loop deterministically
    # regardless of loopback delivery timing.
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(max_rounds):
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
            sleep(0.001)
            continue
    return out^


def _drain_until_eof_driven[
    H: Handler
](mut server: Server, mut handler: H, client: TCPConn) raises -> List[Byte]:
    # Ticks the server while draining: for flows where the server only
    # progresses while being driven.
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(500):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
            continue
    return out^


def test_pipelined_chain_completes_without_extra_waits() raises:
    # Six pipelined requests must all complete well before six ticks:
    # chaining parses each buffered request in the same drive instead
    # of stalling one poll wait per request. The bound is deliberately
    # loose (chaining needs two ticks: accept, then everything) so no
    # wall-clock timing is asserted, only tick counts.
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _TwoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var batch = String("")
    for _ in range(5):
        batch += String("GET /one HTTP/1.1\r\nHost: x\r\n\r\n")
    batch += String("GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    client.write_all(batch.as_bytes(), Timeout.seconds(2))
    # Ticks alone must quiesce the server: client reads play no role in
    # server progress (kernel buffers hold the small batch), so delivery
    # timing cannot flake this bound. Without chaining, six requests
    # need at least seven ticks (accept plus one each).
    for _ in range(4):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if server.active_connections() == 0:
            break
    assert_equal(server.active_connections(), 0)
    var out = _drain_until_eof(client)
    var text = String(from_utf8_lossy=Span(out))
    var ones = 0
    var rest = text
    while True:
        var at = rest.find("ONE")
        if at < 0:
            break
        ones += 1
        var rest_bytes = rest.as_bytes()
        var tail = String(from_utf8_lossy=rest_bytes[at + 3 : len(rest_bytes)])
        rest = tail^
    assert_equal(ones, 5)
    assert_true(text.find("TWO") >= 0)
    client.close()


def test_capped_pipeline_does_not_wait_between_batches() raises:
    # Twenty pipelined requests exceed one tick's request cap, so the
    # remainder carries into later ticks. Those ticks must not block on
    # the kernel for bytes already buffered: with real (blocking) waits
    # the whole batch finishes in milliseconds, not ~100ms per batch.
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _TwoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(5)
    )
    var batch = String("")
    for _ in range(19):
        batch += String("GET /one HTTP/1.1\r\nHost: x\r\n\r\n")
    batch += String("GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    client.write_all(batch.as_bytes(), Timeout.seconds(5))
    # Server completion is measured without client reads: kernel buffers
    # hold the batch, so delivery timing cannot flake the bound. Content
    # is drained separately after quiescence.
    var start = Int(perf_counter_ns())
    for _ in range(30):
        _ = server.tick(handler, None)
        if server.active_connections() == 0:
            break
    var elapsed_ms = (Int(perf_counter_ns()) - start) // 1_000_000
    assert_equal(server.active_connections(), 0)
    var out = _drain_until_eof(client)
    var text = String(from_utf8_lossy=Span(out))
    var ones = 0
    var rest = text
    while True:
        var at = rest.find("ONE")
        if at < 0:
            break
        ones += 1
        var rest_bytes = rest.as_bytes()
        var tail = String(from_utf8_lossy=rest_bytes[at + 3 : len(rest_bytes)])
        rest = tail^
    assert_equal(ones, 19)
    assert_true(text.find("TWO") >= 0)
    # Without the skip-wait the capped remainder would stall one full
    # poll cap (~100ms); the margin below is wide in both directions.
    assert_true(elapsed_ms < 60)


def test_100_continue_flow() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect:"
            " 100-continue\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    var interim = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    for _ in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                interim.append(tmp[i])
            if _header_end(interim) >= 0:
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(interim), 100)
    client.write_all(String("abc").as_bytes(), Timeout.seconds(2))
    var final = List[Byte]()
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                final.append(tmp[i])
            if _response_complete(final):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(final), 200)
    _assert_body(final, "abc")
    client.close()


def test_unknown_expectation_is_417() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        (
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect:"
            " 418-teapot\r\n\r\nabc"
        ),
    )
    assert_equal(_status_of(out), 417)
    client.close()


def test_partial_send_byte_at_a_time() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var raw = String(
        "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    )
    var raw_bytes = raw.as_bytes()
    var out = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    for i in range(len(raw_bytes)):
        var one = Array[Byte, 1](fill=0)
        one[0] = raw_bytes[i]
        client.write_all(Span(one), Timeout.seconds(2))
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            for k in range(n):
                out.append(tmp[k])
        except e:
            _ = e
            continue
    for _ in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for k in range(n):
                out.append(tmp[k])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    client.close()


def test_eof_after_complete_responds_then_closes() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    client.shutdown(False, True)
    var out = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    var saw_eof = False
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                saw_eof = True
                break
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    _tick_n(server, handler, 50)
    assert_equal(server.active_connections(), 0)
    assert_true(saw_eof)
    client.close()


def test_eof_after_pipelined_batch_serves_all() raises:
    # Three pipelined requests followed by a write-side shutdown: every
    # queued request is answered before the connection closes.
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _TwoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost:"
            " x\r\n\r\nGET /one HTTP/1.1\r\nHost: x\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    client.shutdown(False, True)
    var out = _drain_until_eof_driven(server, handler, client)
    var text = String(from_utf8_lossy=Span(out))
    var ones = 0
    var rest = text
    while True:
        var at = rest.find("ONE")
        if at < 0:
            break
        ones += 1
        var rest_bytes = rest.as_bytes()
        var tail = String(from_utf8_lossy=rest_bytes[at + 3 : len(rest_bytes)])
        rest = tail^
    assert_equal(ones, 2)
    assert_true(text.find("TWO") >= 0)
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_eof_mid_request_closes_without_success() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nabc"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    client.shutdown(False, True)
    _tick_n(server, handler, 100)
    assert_equal(server.active_connections(), 0)
    var tmp = Array[Byte, 4096](fill=0)
    var got_bytes = False
    for _ in range(50):
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            got_bytes = True
        except e:
            _ = e
            break
    assert_false(got_bytes)
    client.close()


def test_slow_reader_does_not_block_fast_client() raises:
    var config = ServerConfig.default()
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _BigJsonHandler()
    var slow = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    # Shrink the slow client's receive window so the 256 KiB response
    # cannot fit in flight: the server must park the remainder and keep
    # serving others instead of blocking the loop.
    slow.set_read_buffer(4096)
    slow.write_all(
        String("GET /json HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    var fast = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var fast_done = False
    var fast_bytes = List[Byte]()
    for t in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var probe = Array[Byte, 4096](fill=0)
            var n = fast.try_read(Span(probe))
            for i in range(n):
                fast_bytes.append(probe[i])
            if _response_complete(fast_bytes):
                fast_done = True
                break
        except e:
            _ = e
        if t == 5:
            fast.write_all(
                String("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
                Timeout.seconds(2),
            )
    assert_true(fast_done)
    assert_equal(_status_of(fast_bytes), 200)
    # Drain the slow response to completion and verify integrity.
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(10000):
        _ = server.tick(handler, Timeout.milliseconds(1))
        try:
            var n = slow.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    assert_equal(_content_length_of(out), 262144)
    assert_equal(len(out), _header_end(out) + 262144)
    slow.close()
    fast.close()


def test_malformed_request_is_400() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GARBAGE\r\n\r\n",
    )
    assert_equal(_status_of(out), 400)
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_handler_error_is_500_and_loop_continues() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var boom = _BoomHandler()
    var bad = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var out = _exchange(
        server,
        boom,
        bad,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 500)
    var text = String(from_utf8_lossy=Span(out))
    assert_true(text.find("boom") < 0)
    bad.close()
    _tick_n(server, boom, 20)
    assert_equal(server.active_connections(), 0)
    var hello = _HelloHandler()
    var good = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var second = _exchange(
        server,
        hello,
        good,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(second), 200)
    good.close()


def test_response_over_limit_is_500() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HugeHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET /big HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 500)
    client.close()


def test_direct_body_append_over_limit_is_500() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _DirectHugeHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET /big HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 500)
    client.close()


def test_admitted_body_reservation_blocks_second_client() raises:
    # Admission follows data: the client with headers buffered first
    # reserves its missing body bytes, so the second headers-only
    # client no longer fits and gets 503 while the first still
    # completes afterwards. The second verdict is collected BEFORE the
    # first body arrives, so completion order cannot free the budget
    # early and flip the outcome.
    var config = ServerConfig.default()
    config.total_buffer_budget = 16384 + 2 * H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _BodyCountHandler()
    var first = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var second = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var head = String(
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6000\r\n\r\n"
    )
    first.write_all(head.as_bytes(), Timeout.seconds(2))
    _tick_n(server, handler, 20)
    second.write_all(head.as_bytes(), Timeout.seconds(2))
    var second_out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = second.try_read(Span(tmp))
            for i in range(n):
                second_out.append(tmp[i])
            if _response_complete(second_out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(second_out), 503)
    var payload = String("b") * 6000
    first.write_all(payload.as_bytes(), Timeout.seconds(2))
    var first_out = List[Byte]()
    for _ in range(400):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = first.try_read(Span(tmp))
            for i in range(n):
                first_out.append(tmp[i])
            if _response_complete(first_out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(first_out), 200)
    assert_equal(_content_length_of(first_out), 4)
    _assert_body(first_out, String("6000"))
    first.close()
    second.close()


def test_small_budget_rejects_with_503() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 2048 + H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\n",
    )
    assert_equal(_status_of(out), 503)
    client.close()


def test_connection_close_roundtrip() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    )
    assert_equal(_status_of(out), 200)
    var text = String(from_utf8_lossy=Span(out)).lower()
    assert_true(text.find("connection: close") >= 0)
    _tick_n(server, handler, 50)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_head_omits_body_bytes() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "HEAD /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 404)
    # The hello handler only answers GET; HEAD falls to 404 with an
    # empty drained body on the wire.
    assert_equal(_content_length_of(out), 7)
    assert_equal(len(out), _header_end(out))
    var hello_only = _exchange(
        server,
        handler,
        client,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(hello_only), 200)
    client.close()


def test_chunked_echo_roundtrip() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        (
            "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding:"
            " chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        ),
    )
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    client.close()


def test_binary_body_roundtrip() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var head = _to_bytes(
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n\r\n"
    )
    head.append(Byte(0))
    head.append(Byte(13))
    head.append(Byte(10))
    head.append(Byte(255))
    head.append(Byte(0))
    head.append(Byte(65))
    client.write_all(Span(head), Timeout.seconds(2))
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    var end = _header_end(out)
    assert_equal(_content_length_of(out), 6)
    assert_equal(out[end + 0], Byte(0))
    assert_equal(out[end + 1], Byte(13))
    assert_equal(out[end + 2], Byte(10))
    assert_equal(out[end + 3], Byte(255))
    assert_equal(out[end + 5], Byte(65))
    client.close()


def test_max_connections_pauses_listener() raises:
    var config = ServerConfig.default()
    config.max_connections = 1
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var first = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 1)
    var second = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    _tick_n(server, handler, 20)
    # The listener is paused: the second client stays in the backlog.
    assert_equal(server.active_connections(), 1)
    var out = _exchange(
        server,
        handler,
        first,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 200)
    first.close()
    for _ in range(100):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if server.active_connections() == 0:
            break
    for _ in range(100):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if server.active_connections() == 1:
            break
    assert_equal(server.active_connections(), 1)
    var accepted = _exchange(
        server,
        handler,
        second,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(accepted), 200)
    second.close()


def test_slow_header_times_out() raises:
    var config = ServerConfig.default()
    config.header_deadline = Timeout.milliseconds(200)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String("GET /slow HTTP/1.1\r\nHost: x\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 1)
    sleep(0.4)
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_idle_connection_times_out() raises:
    var config = ServerConfig.default()
    config.idle_timeout = Timeout.milliseconds(200)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 1)
    sleep(0.4)
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_shutdown_drains_in_flight_and_exits() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var idle = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var busy = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 2)
    busy.write_all(
        String("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    server.request_shutdown()
    server.request_shutdown()
    var out = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    for _ in range(2000):
        var alive = server.tick(handler, Timeout.milliseconds(1))
        try:
            var n = busy.try_read(Span(tmp))
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
        if not alive:
            break
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    assert_equal(server.active_connections(), 0)
    assert_true(server.control.is_shutdown_requested())
    server.request_shutdown()
    idle.close()
    busy.close()


def test_local_address_reports_bound_port() raises:
    var bare = Server(ServerConfig.default())
    var missing = False
    try:
        _ = bare.local_address()
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_state())
        missing = True
    assert_true(missing)
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    assert_true(server.local_address().port != 0)


def test_serve_with_control_uses_caller_handle() raises:
    var server = Server(ServerConfig.default())
    var listener = listen_tcp("127.0.0.1:0")
    var handler = _HelloHandler()
    var control = ServerControl()
    control.request_shutdown()
    server.serve_with_control(listener^, handler, control)
    assert_true(control.is_shutdown_requested())
    assert_equal(server.active_connections(), 0)


def test_deadline_rearm_keeps_one_entry_per_connection() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    _tick_n(server, handler, 2)
    assert_equal(server.active_connections(), 1)
    var base = now_ns()
    for i in range(1000):
        server._conns[0].idle_at = base + 1_000_000_000 + i
        server._arm_deadline(0)
    assert_equal(len(server._deadline_heap), 1)
    server._conns[0].idle_at = NO_DEADLINE
    server._arm_deadline(0)
    assert_equal(len(server._deadline_heap), 0)
    server._conns[0].idle_at = base + 2_000_000_000
    server._arm_deadline(0)
    assert_equal(len(server._deadline_heap), 1)
    server._close_conn(0)
    assert_equal(len(server._deadline_heap), 0)
    client.close()


def test_deadline_close_and_slot_reuse_removes_old_entries() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _HelloHandler()
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var base = now_ns()
    for _ in range(20):
        var client = dial_tcp(address, Timeout.seconds(2))
        _tick_n(server, handler, 2)
        assert_equal(len(server._conns), 1)
        server._conns[0].idle_at = base + 10_000_000
        server._arm_deadline(0)
        server._conns[0].idle_at = base + 20_000_000
        server._arm_deadline(0)
        server._expire_deadlines(base + 10_000_000)
        assert_equal(server.active_connections(), 1)
        server._close_conn(0)
        assert_equal(len(server._deadline_heap), 0)
        client.close()


def test_deadline_updates_preserve_order_and_expiration() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _HelloHandler()
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var clients = List[TCPConn]()
    for _ in range(5):
        clients.append(dial_tcp(address, Timeout.seconds(2)))
    _tick_n(server, handler, 2)
    assert_equal(server.active_connections(), 5)
    var base = now_ns()
    for i in range(5):
        server._conns[i].idle_at = base + (i + 1) * 10_000_000
        server._arm_deadline(i)
    server._conns[0].idle_at = base + 60_000_000
    server._arm_deadline(0)
    server._conns[4].idle_at = base + 5_000_000
    server._arm_deadline(4)
    assert_equal(server._compute_timeout(base, None).value()._value, 5_000_000)
    server._close_conn(2)
    server._expire_deadlines(base + 5_000_000)
    assert_false(server._conns[4].active)
    assert_equal(server.active_connections(), 3)
    assert_equal(server._compute_timeout(base, None).value()._value, 20_000_000)
    server._expire_deadlines(base + 20_000_000)
    assert_false(server._conns[1].active)
    assert_true(server._conns[0].active)
    assert_true(server._conns[3].active)
    assert_equal(server._compute_timeout(base, None).value()._value, 40_000_000)
    server._expire_deadlines(base + 60_000_000)
    assert_equal(server.active_connections(), 0)
    assert_equal(len(server._deadline_heap), 0)
    for i in range(len(clients)):
        clients[i].close()


def test_expired_entry_rearms_current_connection_deadline() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    _tick_n(server, handler, 2)
    var base = now_ns()
    server._conns[0].idle_at = base + 10_000_000
    server._arm_deadline(0)
    server._conns[0].idle_at = base + 20_000_000
    server._expire_deadlines(base + 10_000_000)
    assert_equal(server.active_connections(), 1)
    assert_equal(server._compute_timeout(base, None).value()._value, 20_000_000)
    server._expire_deadlines(base + 20_000_000)
    assert_equal(server.active_connections(), 0)
    client.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
