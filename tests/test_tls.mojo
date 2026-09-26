from std.ffi import c_int, external_call
from std.testing import assert_true, TestSuite

from net._sys.common import (
    AF_UNIX,
    SOCK_STREAM,
    _OwnedFD,
    _set_nonblocking_cloexec,
)
from net.tcp import TCPConn
from net.tls import TLSContext


@fieldwise_init
struct _TLSFDS(Movable):
    var client: _OwnedFD
    var server: _OwnedFD

    def take_client(mut self) -> TCPConn:
        return TCPConn(_OwnedFD(self.client._take()))

    def take_server(mut self) -> TCPConn:
        return TCPConn(_OwnedFD(self.server._take()))


def _tls_socket_pair() raises -> _TLSFDS:
    var raw = SIMD[DType.int32, 2](0)
    var result = external_call["socketpair", c_int](
        c_int(AF_UNIX),
        c_int(SOCK_STREAM),
        c_int(0),
        Pointer(to=raw).unsafe_bitcast[c_int](),
    )
    if result != 0:
        raise Error("socketpair failed")
    var pair = _TLSFDS(client=_OwnedFD(raw[0]), server=_OwnedFD(raw[1]))
    _set_nonblocking_cloexec(pair.client.raw())
    _set_nonblocking_cloexec(pair.server.raw())
    return pair^


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
    var pair = _tls_socket_pair()
    var client = pair.take_client()
    var server = pair.take_server()
    var tls = context.accept(server^)

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
