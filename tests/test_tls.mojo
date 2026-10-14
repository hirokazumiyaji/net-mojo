from std.testing import assert_equal, assert_true, TestSuite

from net import Timeout, dial_tcp, listen_tcp
from net.http import Server, ServerConfig
from net.http._connection import PROTOCOL_HTTP2, STATE_TLS_SHUTDOWN
from net.http._deadline import now_ns
from net.http._http2.request_session import Http2RequestSession
from net._sys.common import _OwnedFD
from net.tcp import TCPConn
from net.tls import TLSContext
from tests.support import _socket_pair


def test_tls_context_loads_server_certificate_and_alpn() raises:
    var context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )


def test_tls_context_rejects_key_that_does_not_match_certificate() raises:
    var failed = False
    try:
        _ = TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/wrong-key.pem",
            "http/1.1",
        )
    except error:
        failed = True
    assert_true(failed)


def test_tls_handshake_waits_for_input_and_rejects_non_tls_bytes() raises:
    var context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )
    var pair = _socket_pair()
    var client = TCPConn(_OwnedFD(pair.first._take()))
    var server = TCPConn(_OwnedFD(pair.second._take()))
    var tls = context.accept(server^)

    var empty = Array[Byte, 0](fill=0)
    var empty_read = tls.try_read(Span(empty))
    var empty_write = tls.try_write(Span(empty))
    assert_true(empty_read.progress.is_complete())
    assert_true(empty_write.progress.is_complete())
    assert_true(empty_read.count == 0)
    assert_true(empty_write.count == 0)

    var progress = tls.handshake()
    assert_true(progress.is_wants_read())

    client.write_all(String("not a TLS record").as_bytes())
    var failed = False
    try:
        _ = tls.handshake()
    except error:
        failed = True
    assert_true(failed)


def test_http2_tls_shutdown_deadline_closes_before_session_expiry() raises:
    var server = Server(ServerConfig.default())
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2",
        ),
    )
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    var expires = now_ns() + 2_000_000_000
    while server.active_connections() == 0 and now_ns() < expires:
        server._accept_pending(now_ns())
    assert_equal(server.active_connections(), 1)
    assert_true(Bool(server._conns[0].tls))
    server._conns[0].http2_session = Http2RequestSession(
        "build/http2/libnet_hpack", 4, 1024
    )
    server._conns[0].protocol = PROTOCOL_HTTP2
    server._conns[0].state = STATE_TLS_SHUTDOWN
    server._conns[0].tls_shutdown_at = now_ns() - 1
    server._arm_deadline(0)
    server._expire_deadlines(now_ns())
    assert_equal(server.active_connections(), 0)
    assert_equal(len(server._deadline_heap), 0)
    client.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
