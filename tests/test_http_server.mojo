from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net._reactor import ReactorToken
from net._sys.common import _OwnedFD
from net.http._buffer import BufferBudget
from net.http._connection import HttpConnection
from net.http._deadline import now_ns
from net.http import (
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
)
from net.http._deadline import NO_DEADLINE, now_ns
from tests.support import _socket_pair, _tick_n


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
    config.total_buffer_budget = 12
    config.max_bytes_per_tick = 7
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _HelloHandler()
    var foreign = dial_tcp(address, Timeout.seconds(1))
    foreign.write_all("GET /".as_bytes(), Timeout.seconds(1))
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while server._budget.used != 5 and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server._budget.used, 5)
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
    assert_equal(server._budget.used, 12)
    assert_equal(String(from_utf8_lossy=Span(server._conns[1].buf)), "GET /ab")
    client.close()
    server._conns[1].bytes_this_tick = 0
    while not server._conns[1].read_eof and Int(perf_counter_ns()) < expires:
        server._pump_read(1, True, now_ns())
    assert_true(server._conns[1].read_eof)
    server._close_conn(1)
    assert_equal(server._budget.used, 5)

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
    assert_equal(server._budget.used, 12)
    server._conns[1].bytes_this_tick = 0
    while server._conns[1].active and Int(perf_counter_ns()) < expires:
        server._pump_read(1, True, now_ns())
    assert_false(server._conns[1].active)
    assert_true(server._conns[0].active)
    assert_equal(server._conns[0].buf.capacity(), 5)
    assert_equal(server._budget.used, 5)
    denied.close()
    foreign.close()
    server._close_conn(0)
    assert_equal(server._budget.used, 0)


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
    config.total_buffer_budget = 512
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
    assert_equal(server._budget.used, 8)
    assert_equal(server._conns[0].pending_offset, 1)
    for _ in range(2):
        server._conns[0].reset_tick()
        server._pump_send(0, True)
    assert_equal(server._budget.used, 0)
    assert_equal(server._conns[0].pending.capacity(), 0)
    assert_true(server._conns[0].active)
    server._send_error(0, 503)
    assert_equal(server._budget.used, server._conns[0].pending.capacity())
    assert_true(server._budget.used > len(server._conns[0].pending))
    var out = _drain_until_eof_driven(server, handler, client)
    assert_true(String(from_utf8_lossy=Span(out)).find("503") >= 0)
    assert_equal(server._budget.used, 0)
    assert_equal(server._conns[0].pending.capacity(), 0)
    client.close()
    var second = dial_tcp(address, Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(len(server._conns), 1)
    var queued = List[Byte](capacity=12)
    queued.append(42)
    assert_true(server._conns[0].set_pending(queued^, server._budget))
    server._close_conn(0)
    assert_equal(server._budget.used, 0)
    assert_equal(server._conns[0].pending.capacity(), 0)
    second.close()


def test_receive_compaction_consumption_close_and_slot_reuse() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 256
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
    server._conns[0].scanned_len = 8
    server._consume_receive(0, 5)
    assert_equal(server._budget.used, 8)
    assert_equal(server._conns[0].buf.capacity(), 8)
    assert_equal(len(server._conns[0].buf), 3)
    assert_equal(server._conns[0].buf[0], 5)
    assert_equal(server._conns[0].buf[2], 7)
    assert_equal(server._conns[0].scanned_len, 3)
    server._consume_receive(0, 3)
    assert_equal(server._budget.used, 0)
    assert_equal(server._conns[0].buf.capacity(), 0)
    assert_true(server._charge_read(0, 12))
    assert_equal(server._budget.used, 12)
    assert_true(server._charge_read(0, 96))
    var head = String(
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 40\r\n\r\n"
    )
    server._conns[0].append_bytes(head.as_bytes())
    server._pump_parse(0, handler, 0)
    assert_equal(server._conns[0].reserved, 0)
    assert_equal(server._conns[0].http1_body_reserved, 40)
    assert_equal(server._budget.used, 136)
    assert_true(server._budget.try_reserve(7))
    server._conns[0].reserved = 7
    server._close_conn(0)
    assert_equal(server._budget.used, 0)
    assert_equal(server._conns[0].http1_body_reserved, 0)
    assert_equal(server._conns[0].buf.capacity(), 0)
    client.close()
    var second = dial_tcp(String(address), Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(len(server._conns), 1)
    assert_true(server._conns[0].active)
    assert_equal(server._conns[0].reserved, 0)
    assert_equal(server._conns[0].buf.capacity(), 0)
    assert_equal(server._budget.used, 0)
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
        config.total_buffer_budget = limit
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
        assert_equal(server._budget.used, 0)
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
        self.workspace = writer._body_budget.value().total
        writer.write_string(String("a") * 64)
        if self.action == 1:
            raise Error("after body allocation")
        if self.action == 2:
            writer.body.reserve(1024)
            return
        if self.action == 3:
            writer.headers.add(String("Content-Length"), String("999"))
        writer.write_string(String("b") * 64)


struct _RequestWorkspaceHandler(Handler):
    var action: Int
    var workspace: Int

    def __init__(out self):
        self.action = 0
        self.workspace = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        assert_equal(req.body.capacity(), 5)
        self.workspace = writer._body_budget.value().total
        writer.write_string("reply")
        if self.action == 1:
            raise Error("after borrowed request")
        if self.action == 2:
            writer.headers.add(String("Content-Length"), String("999"))
        if self.action == 3:
            _ = writer.detach()


def _check_request_capacity_workspace(request: String) raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _RequestWorkspaceHandler()
    var waiting = dial_tcp(address, Timeout.seconds(1))
    waiting.write_all("GET /".as_bytes(), Timeout.seconds(1))
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while server._budget.used != 5 and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.milliseconds(1))
    assert_equal(server._budget.used, 5)
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
        assert_equal(server._budget.used, 5)
        client.close()
    server._close_conn(0)
    assert_equal(server._budget.used, 0)
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
    config.total_buffer_budget = 8192
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
    assert_equal(server._budget.used, 0)
    client.close()


def test_partial_chunked_body_does_not_reserve_decoded_allocation() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512
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
    assert_equal(server._budget.used, server._conns[0].buf.capacity())
    var out = _exchange(server, handler, client, "y!\r\n0\r\n\r\n")
    assert_equal(_status_of(out), 200)
    _assert_body(out, "body!")
    assert_equal(server._budget.used, 0)
    client.close()


def test_request_copy_peak_is_rejected_before_receiving_body() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 8192
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
    assert_equal(server._budget.used, 0)
    client.close()


def test_writer_workspace_returns_on_success_handler_and_encoder_errors() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var handler = _WorkspaceHandler()
    var waiting = dial_tcp(address, Timeout.seconds(1))
    waiting.write_all("GET /".as_bytes(), Timeout.seconds(1))
    _tick_n(server, handler, 2)
    assert_equal(server._budget.used, 5)
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
        assert_equal(server._budget.used, 5)
        client.close()
    server._close_conn(0)
    assert_equal(server._budget.used, 0)
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


def _bytes_of(data: StringSlice) -> List[Byte]:
    var out = List[Byte]()
    var bytes = data.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _header_end(buf: List[Byte]) -> Int:
    var i = 0
    while i + 3 < len(buf):
        if (
            buf[i] == Byte(ord("\r"))
            and buf[i + 1] == Byte(ord("\n"))
            and buf[i + 2] == Byte(ord("\r"))
            and buf[i + 3] == Byte(ord("\n"))
        ):
            return i + 4
        i += 1
    return -1


def _status_of(buf: List[Byte]) -> Int:
    if len(buf) < 12:
        return -1
    var code = 0
    for i in range(9, 12):
        var byte = buf[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return -1
        code = code * 10 + Int(byte - Byte(ord("0")))
    return code


def _content_length_of(buf: List[Byte]) -> Int:
    var end = _header_end(buf)
    if end < 0:
        return -1
    var head = String(from_utf8_lossy=Span(buf)[0:end]).lower()
    var needle = String("content-length:")
    var at = head.find(needle)
    if at < 0:
        return -1
    var value_start = at + len(needle.as_bytes())
    var value_end = value_start
    var head_bytes = head.as_bytes()
    while value_end < len(head_bytes) and (
        head_bytes[value_end] == Byte(ord(" "))
        or head_bytes[value_end] == Byte(ord("\t"))
    ):
        value_end += 1
    var digits_start = value_end
    while value_end < len(head_bytes) and (
        head_bytes[value_end] >= Byte(ord("0"))
        and head_bytes[value_end] <= Byte(ord("9"))
    ):
        value_end += 1
    if value_end == digits_start:
        return -1
    var value = 0
    for i in range(digits_start, value_end):
        value = value * 10 + Int(head_bytes[i] - Byte(ord("0")))
    return value


def _response_complete(buf: List[Byte]) -> Bool:
    var end = _header_end(buf)
    if end < 0:
        return False
    var length = _content_length_of(buf)
    if length < 0:
        return True
    return len(buf) >= end + length


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
    config.total_buffer_budget = 16384
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
    config.total_buffer_budget = 2048
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
    var head = _bytes_of(
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
