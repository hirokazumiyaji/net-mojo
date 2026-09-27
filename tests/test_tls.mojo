from std.testing import assert_true, TestSuite

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
