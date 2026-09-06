from std.testing import assert_equal, assert_true, TestSuite

from net import Timeout, dial_tcp, listen_tcp
from net.error import NetError, NetErrorKind
from net._sys.common import (
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    _get_socket_option_int,
)
from tests.support import _assert_bytes_equal


def test_ipv4_loopback_round_trip_and_eof() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening_address = listener.local_address()
    assert_true(listening_address.port != 0)

    var client = dial_tcp(String(listening_address))
    var server = listener.accept(Timeout.seconds(1))
    assert_equal(client.remote_address(), listening_address)
    assert_equal(server.local_address(), listening_address)
    assert_equal(client.local_address(), server.remote_address())

    var ping: Array[Byte, 4] = [
        Byte(ord("p")),
        Byte(ord("i")),
        Byte(ord("n")),
        Byte(ord("g")),
    ]
    client.write_all(Span(ping))
    var received_ping = Array[Byte, 4](fill=0)
    assert_equal(server.read(Span(received_ping), Timeout.seconds(1)), 4)
    _assert_bytes_equal(Span(received_ping), Span(ping))

    var pong: Array[Byte, 4] = [
        Byte(ord("p")),
        Byte(ord("o")),
        Byte(ord("n")),
        Byte(ord("g")),
    ]
    server.write_all(Span(pong))
    var received_pong = Array[Byte, 4](fill=0)
    assert_equal(client.read(Span(received_pong), Timeout.seconds(1)), 4)
    _assert_bytes_equal(Span(received_pong), Span(pong))

    client.shutdown(False, True)
    var eof_buffer = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(eof_buffer), Timeout.seconds(1)), 0)


def test_ipv6_loopback_and_v6only() raises:
    var v6only: Int
    var written: Int
    var read_count: Int
    var received_byte: Byte
    try:
        var listener = listen_tcp("[::1]:0")
        v6only = Int(
            _get_socket_option_int(
                listener._fd.raw(), IPPROTO_IPV6, IPV6_V6ONLY
            )
        )
        var client = dial_tcp(String(listener.local_address()))
        var server = listener.accept(Timeout.seconds(1))
        var sent = Array[Byte, 1](fill=91)
        written = client.write(Span(sent))
        var received = Array[Byte, 1](fill=0)
        read_count = server.read(Span(received), Timeout.seconds(1))
        received_byte = received[0]
    except error:
        if error.kind == NetErrorKind.unsupported():
            return
        raise error^
    assert_equal(v6only, 1)
    assert_equal(written, 1)
    assert_equal(read_count, 1)
    assert_equal(received_byte, Byte(91))


def test_accept_timeout() raises:
    var listener = listen_tcp("127.0.0.1:0")
    try:
        _ = listener.accept(Timeout.milliseconds(5))
    except error:
        assert_equal(error.kind, NetErrorKind.timeout())
        return
    raise Error("accept unexpectedly succeeded")


def test_read_timeout() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()))
    var server = listener.accept(Timeout.seconds(1))
    var buffer = Array[Byte, 1](fill=0)
    var timed_out = False
    try:
        _ = server.read(Span(buffer), Timeout.milliseconds(5))
    except error:
        if error.kind != NetErrorKind.timeout():
            raise error^
        timed_out = True
    assert_true(timed_out)
    assert_true(client.local_address().port != 0)


def test_connection_refusal() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var address = String(listener.local_address())
    listener.close()
    try:
        _ = dial_tcp(address, Timeout.seconds(1))
    except error:
        assert_equal(error.kind, NetErrorKind.system_error())
        return
    raise Error("connection unexpectedly succeeded")


def test_write_all_transfers_large_buffer() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()))
    var server = listener.accept(Timeout.seconds(1))
    var sent = Array[Byte, 4096](fill=0)
    for i in range(len(sent)):
        sent[i] = Byte(i % 251)
    client.write_all(Span(sent), Timeout.seconds(1))

    var received = Array[Byte, 4096](fill=0)
    var offset = 0
    while offset < len(received):
        offset += server.read(Span(received)[offset:], Timeout.seconds(1))
    _assert_bytes_equal(Span(received), Span(sent))


def test_second_close_reports_closed() raises:
    var listener = listen_tcp("127.0.0.1:0")
    listener.close()
    try:
        listener.close()
    except error:
        assert_equal(error.kind, NetErrorKind.closed())
        return
    raise Error("second close unexpectedly succeeded")


def test_dial_rejects_port_zero() raises:
    try:
        _ = dial_tcp("127.0.0.1:0")
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
        return
    raise Error("dial accepted port zero")


def test_listen_rejects_invalid_backlog() raises:
    try:
        _ = listen_tcp("127.0.0.1:0", backlog=0)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        return
    raise Error("listen accepted an invalid backlog")


def test_listen_rejects_backlog_above_int32() raises:
    try:
        _ = listen_tcp("127.0.0.1:0", backlog=Int(Int32.MAX) + 1)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        return
    raise Error("listen accepted an oversized backlog")


def test_zero_length_read_and_write_return_zero() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()))
    var server = listener.accept(Timeout.seconds(1))
    var empty = Array[Byte, 0](fill=0)
    assert_equal(client.write(Span(empty), Timeout.nanoseconds(0)), 0)
    assert_equal(server.read(Span(empty), Timeout.nanoseconds(0)), 0)
    assert_true(client.local_address().port != 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
