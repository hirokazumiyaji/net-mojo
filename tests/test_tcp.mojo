from std.testing import assert_equal, assert_true, TestSuite

from net import Timeout, dial_tcp, listen_tcp
from net.error import NetError, NetErrorKind
from net._sys.common import (
    IPPROTO_IPV6,
    IPPROTO_TCP,
    IPV6_V6ONLY,
    SOL_SOCKET,
    SO_KEEPALIVE,
    SO_RCVBUF,
    SO_SNDBUF,
    TCP_KEEPIDLE,
    TCP_KEEPINTVL,
    TCP_NODELAY,
    _get_linger,
    _get_socket_option_int,
)
from net._stream import _WriteAllStep, _write_all_loop
from net.timeout import _Deadline
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


def test_wildcard_listen_accepts_ipv4() raises:
    var listener = listen_tcp(":0")
    var listening = listener.local_address()
    if listening.ip.is_ipv6():
        var v6only = Int(
            _get_socket_option_int(
                listener._fd.raw(), IPPROTO_IPV6, IPV6_V6ONLY
            )
        )
        assert_equal(v6only, 0)
    var port = listening.port
    var client = dial_tcp(String(t"127.0.0.1:{port}"), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var sent = Array[Byte, 1](fill=77)
    assert_equal(client.write(Span(sent), Timeout.seconds(1)), 1)
    var received = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(received), Timeout.seconds(1)), 1)
    assert_equal(received[0], Byte(77))


def test_wildcard_ipv6_only_option() raises:
    var listening_port: UInt16
    var v6only_value: Int
    var was_v6: Bool
    try:
        var listener = listen_tcp(":0", ipv6_only=True)
        v6only_value = Int(
            _get_socket_option_int(
                listener._fd.raw(), IPPROTO_IPV6, IPV6_V6ONLY
            )
        )
        var listening = listener.local_address()
        listening_port = listening.port
        was_v6 = listening.ip.is_ipv6()
    except error:
        if error.kind == NetErrorKind.unsupported():
            return
        raise error^
    assert_true(was_v6)
    assert_equal(v6only_value, 1)
    assert_true(listening_port != 0)


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


@fieldwise_init
struct _PartialWriteStep(Copyable, _WriteAllStep):
    var calls: Int
    var expected_offset: Int
    var offsets_are_correct: Bool
    var deadline_is_shared: Bool
    var expected_expiration: Optional[Int]

    def write(
        mut self, offset: Int, remaining: Int, deadline: _Deadline
    ) raises NetError -> Int:
        if offset != self.expected_offset:
            self.offsets_are_correct = False
        if deadline._expires_at != self.expected_expiration:
            self.deadline_is_shared = False
        self.calls += 1
        var written = 3 if remaining > 3 else remaining
        self.expected_offset += written
        return written


def test_write_all_advances_partial_progress_with_one_deadline() raises:
    var deadline = _Deadline.from_timeout(Timeout.seconds(1))
    var write_step = _PartialWriteStep(
        calls=0,
        expected_offset=0,
        offsets_are_correct=True,
        deadline_is_shared=True,
        expected_expiration=deadline._expires_at,
    )
    _write_all_loop(10, deadline, write_step)
    assert_equal(write_step.calls, 4)
    assert_equal(write_step.expected_offset, 10)
    assert_true(write_step.offsets_are_correct)
    assert_true(write_step.deadline_is_shared)


def test_no_delay_defaults_to_enabled_and_toggles() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    # NOTE: macOS reports boolean options as nonzero flag bits
    # (TCP_NODELAY -> 4), so enabled means != 0 portably.
    assert_true(
        _get_socket_option_int(client._fd.raw(), IPPROTO_TCP, TCP_NODELAY) != 0
    )
    assert_true(
        _get_socket_option_int(server._fd.raw(), IPPROTO_TCP, TCP_NODELAY) != 0
    )
    client.set_no_delay(False)
    assert_equal(
        _get_socket_option_int(client._fd.raw(), IPPROTO_TCP, TCP_NODELAY),
        0,
    )
    client.set_no_delay(True)
    assert_true(
        _get_socket_option_int(client._fd.raw(), IPPROTO_TCP, TCP_NODELAY) != 0
    )
    client.close()
    server.close()
    listener.close()


def test_keep_alive_toggle_and_period() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    assert_equal(
        _get_socket_option_int(client._fd.raw(), SOL_SOCKET, SO_KEEPALIVE),
        0,
    )
    client.set_keep_alive(True)
    # NOTE: macOS reports SO_KEEPALIVE as the nonzero flag bit (8).
    assert_true(
        _get_socket_option_int(client._fd.raw(), SOL_SOCKET, SO_KEEPALIVE) != 0
    )
    client.set_keep_alive_period(Timeout.seconds(30))
    assert_true(
        _get_socket_option_int(client._fd.raw(), SOL_SOCKET, SO_KEEPALIVE) != 0
    )
    assert_equal(
        _get_socket_option_int(client._fd.raw(), IPPROTO_TCP, TCP_KEEPIDLE),
        30,
    )
    assert_equal(
        _get_socket_option_int(client._fd.raw(), IPPROTO_TCP, TCP_KEEPINTVL),
        30,
    )
    client.set_keep_alive(False)
    assert_equal(
        _get_socket_option_int(client._fd.raw(), SOL_SOCKET, SO_KEEPALIVE),
        0,
    )
    client.close()
    server.close()
    listener.close()


def test_socket_buffers_round_up() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    client.set_read_buffer(65536)
    assert_true(
        _get_socket_option_int(client._fd.raw(), SOL_SOCKET, SO_RCVBUF) >= 65536
    )
    client.set_write_buffer(65536)
    assert_true(
        _get_socket_option_int(client._fd.raw(), SOL_SOCKET, SO_SNDBUF) >= 65536
    )
    try:
        client.set_read_buffer(0)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
    else:
        raise Error("set_read_buffer accepted zero")
    client.close()
    server.close()
    listener.close()


def test_linger_enable_disable_and_rejects_overflow() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    client.set_linger(-1)
    assert_equal(_get_linger(client._fd.raw()).onoff, 0)
    client.set_linger(0)
    var immediate = _get_linger(client._fd.raw())
    assert_equal(immediate.onoff, 1)
    assert_equal(immediate.seconds, 0)
    client.set_linger(5)
    var delayed = _get_linger(client._fd.raw())
    assert_equal(delayed.onoff, 1)
    assert_equal(delayed.seconds, 5)
    try:
        client.set_linger(Int(Int32.MAX) + 1)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
    else:
        raise Error("set_linger accepted an oversized period")
    client.close()
    server.close()
    listener.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
