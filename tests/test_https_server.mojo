from std.testing import assert_equal, assert_true, TestSuite
from std.time import sleep, perf_counter_ns

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net._reactor import ReactorToken
from net.http._deadline import now_ns
from net.http._connection import (
    HttpConnection,
    READ_BUFFER_SIZE,
    H1_ERROR_CAPACITY,
)
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSConnection, TLSContext
from tests.support import _tick_n


struct _HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(200)
        writer.write_string("hello")


def _tls_context() raises -> TLSContext:
    return TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )


def _try_read[capacity: Int](mut client: TCPConn) raises -> Optional[Int]:
    var response = Array[Byte, capacity](fill=0)
    try:
        return Optional[Int](client.try_read(Span(response)))
    except e:
        _ = e
        return None


def test_https_read_into_preserves_want_read_buffer_and_retry_length() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(
        String("127.0.0.1:") + String(listener.local_address().port),
        Timeout.seconds(1),
    )
    var accepted = listener.accept(Timeout.seconds(1))
    var context = _tls_context()
    var tls = context.accept(accepted^)
    var conn = HttpConnection(
        ReactorToken(0, 0), None, Optional[TLSConnection](tls^), 0, -1, -1
    )
    var buffer_address = Int(conn.tls_read_buffer.unsafe_ptr())
    var scratch = Array[Byte, 3](fill=42)
    for _ in range(2):
        var blocked = False
        try:
            _ = conn.try_read_into(Span(scratch))
        except e:
            assert_equal(e.kind, NetErrorKind.timeout())
            blocked = True
        assert_true(blocked)
        assert_true(conn.tls_read_would_block)
        assert_true(not conn.tls_read_wants_write)
        assert_equal(conn.tls_read_retry_length, 3)
        assert_equal(conn.tls_read_buffer.capacity(), READ_BUFFER_SIZE)
        assert_equal(Int(conn.tls_read_buffer.unsafe_ptr()), buffer_address)
        assert_equal(scratch[0], 42)
    conn.close()
    client.close()


def test_https_server_rejects_plaintext_before_http_parsing() raises:
    var server = Server(ServerConfig.default())
    server.add_tls_listener(listen_tcp("127.0.0.1:0"), _tls_context())
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    var handler = _HelloHandler()
    client.write_all(
        String("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )

    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 0)
    var count = _try_read[128](client)
    assert_true(not count or count.value() == 0)


def test_https_server_closes_connections_after_handshake_deadline() raises:
    var config = ServerConfig.default()
    config.tls_handshake_timeout = Timeout.milliseconds(100)
    config.total_buffer_budget = 8192 + H1_ERROR_CAPACITY
    var server = Server(config^)
    server.add_tls_listener(listen_tcp("127.0.0.1:0"), _tls_context())
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    var handler = _HelloHandler()

    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 1)
    sleep(0.2)
    _tick_n(server, handler, 1)
    assert_equal(server.active_connections(), 0)
    var count = _try_read[1](client)
    assert_true(not count or count.value() == 0)
    client.close()

    var retry = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 1)
    retry.close()
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 0)


def test_https_emergency_admission_accounts_tls_store_and_alt_svc() raises:
    for admitted in [False, True]:
        var config = ServerConfig.default()
        config.alt_svc = (
            String('h3=":8443"; x="') + String("a") * 300 + String('"')
        )
        var error_capacity = (
            H1_ERROR_CAPACITY + 11 + config.alt_svc.byte_length()
        )
        config.total_buffer_budget = (
            READ_BUFFER_SIZE + error_capacity + 5 - Int(not admitted)
        )
        var server = Server(config^)
        var observer = server._budget.copy()
        assert_true(observer.try_reserve(5))
        server.add_tls_listener(listen_tcp("127.0.0.1:0"), _tls_context())
        var client = dial_tcp(
            String("127.0.0.1:") + String(server.local_address().port),
            Timeout.seconds(1),
        )
        var accepted = False
        var expires = Int(perf_counter_ns()) + 2_000_000_000
        while not accepted and Int(perf_counter_ns()) < expires:
            server._accept_pending(now_ns())
            if admitted:
                accepted = server.active_connections() == 1
            else:
                var observed = _try_read[1](client)
                accepted = observed and observed.value() == 0
        assert_true(accepted)
        assert_equal(server.active_connections(), Int(admitted))
        assert_equal(
            observer.used(),
            5 + (READ_BUFFER_SIZE + error_capacity) * Int(admitted),
        )
        if admitted:
            assert_equal(
                server._conns[0].tls_read_buffer.capacity(), READ_BUFFER_SIZE
            )
            assert_equal(
                server._conns[0]._error_wire.capacity(), error_capacity
            )
            assert_equal(server._conns[0]._error_ticket.amount, error_capacity)
            server._close_conn(0)
            assert_equal(server._conns[0].tls_read_buffer.capacity(), 0)
            assert_equal(server._conns[0]._error_wire.capacity(), 0)
        client.close()
        _ = server^
        assert_equal(observer.used(), 5)
        observer.release(5)
        assert_equal(observer.used(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
