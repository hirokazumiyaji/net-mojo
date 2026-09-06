from std.testing import assert_equal, assert_true, TestSuite

from net import SocketAddress, TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetError, NetErrorKind
from net.tcp import _dial_tcp_candidates
from net._sys.common import (
    ECONNREFUSED,
    ECONNRESET,
    EPIPE,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
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
        assert_true(error.has_errno(ECONNREFUSED))
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


def _write_ping_through_moved(var conn: TCPConn) raises -> TCPConn:
    var ping: Array[Byte, 4] = [9, 8, 7, 6]
    conn.write_all(Span(ping), Timeout.seconds(1))
    return conn^


def test_moved_connection_serves_io_across_function_boundary() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    client = _write_ping_through_moved(client^)
    var received = Array[Byte, 4](fill=0)
    assert_equal(server.read(Span(received), Timeout.seconds(1)), 4)
    assert_equal(received[0], Byte(9))
    assert_equal(received[3], Byte(6))
    client.close()
    server.close()
    listener.close()


def test_write_after_peer_close_reports_epipe_or_reset() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    server.close()
    # Small writes fit the kernel buffers even after FIN, so pump until
    # the peer's RST surfaces. The first write may succeed; a later one
    # must fail once the reset is processed.
    var chunk = Array[Byte, 65536](fill=1)
    var failed_errno: Int32 = 0
    var total = 0
    while total < 64 * 1024 * 1024:
        try:
            total += client.write(Span(chunk), Timeout.seconds(1))
        except error:
            assert_equal(error.kind, NetErrorKind.system_error())
            if error.errno:
                failed_errno = Int32(error.errno.value())
            break
    assert_true(failed_errno == EPIPE or failed_errno == ECONNRESET)
    client.close()
    listener.close()


def test_large_transfer_progresses_through_would_block() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    # Zero-timeout writes never wait: they fill the kernel buffers and
    # then surface EAGAIN as a timeout, proving the would-block branch
    # of _write_with_deadline executes with real progress before it.
    var chunk = Array[Byte, 65536](fill=7)
    var target = 8 * 1024 * 1024
    var total = 0
    var timed_out = False
    while total < target:
        try:
            total += client.write(Span(chunk), Timeout.nanoseconds(0))
        except error:
            assert_equal(error.kind, NetErrorKind.timeout())
            timed_out = True
            break
    assert_true(timed_out)
    assert_true(total > 0)
    assert_true(total < target)
    client.close()
    server.close()
    listener.close()


def test_partial_read_framing_across_writes() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var first: Array[Byte, 3] = [1, 2, 3]
    var second: Array[Byte, 3] = [4, 5, 6]
    client.write_all(Span(first), Timeout.seconds(1))
    client.write_all(Span(second), Timeout.seconds(1))
    var one = Array[Byte, 1](fill=0)
    var assembled = List[Byte]()
    for _ in range(6):
        assert_equal(server.read(Span(one), Timeout.seconds(1)), 1)
        assembled.append(one[0])
    for i in range(6):
        assert_equal(assembled[i], Byte(i + 1))
    client.close()
    server.close()
    listener.close()


def test_dial_falls_back_to_next_candidate() raises:
    var refused_holder = listen_tcp("127.0.0.1:0")
    var refused = refused_holder.local_address()
    refused_holder.close()
    var listener = listen_tcp("127.0.0.1:0")
    var good = listener.local_address()
    var candidates = List[SocketAddress]()
    candidates.append(refused.copy())
    candidates.append(good.copy())
    var deadline = _Deadline.from_timeout(Timeout.seconds(2))
    var client = _dial_tcp_candidates(candidates^, deadline)
    assert_equal(String(client.remote_address()), String(good))
    var server = listener.accept(Timeout.seconds(1))
    var sent: Array[Byte, 1] = [5]
    client.write_all(Span(sent), Timeout.seconds(1))
    var received = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(received), Timeout.seconds(1)), 1)
    assert_equal(received[0], Byte(5))
    client.close()
    server.close()
    listener.close()


def test_unreachable_dial_times_out_or_fails_fast() raises:
    try:
        _ = dial_tcp("192.0.2.1:80", Timeout.seconds(1))
    except error:
        assert_true(
            error.kind == NetErrorKind.timeout()
            or error.kind == NetErrorKind.system_error()
        )
        return
    raise Error("dial to TEST-NET-1 unexpectedly succeeded")


def test_accept_on_closed_listener_reports_closed() raises:
    var listener = listen_tcp("127.0.0.1:0")
    listener.close()
    try:
        _ = listener.accept(Timeout.seconds(1))
    except error:
        assert_equal(error.kind, NetErrorKind.closed())
        return
    raise Error("accept on closed listener unexpectedly succeeded")


def test_repeated_dial_close_reuses_descriptors() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var target = String(listener.local_address())
    var low = Int(Int32.MAX)
    var high = Int(Int32.MIN)
    for _ in range(30):
        var client = dial_tcp(target, Timeout.seconds(1))
        var fd = Int(client._fd.raw())
        if fd < low:
            low = fd
        if fd > high:
            high = fd
        var server = listener.accept(Timeout.seconds(1))
        client.close()
        server.close()
    assert_true(high - low < 10)
    listener.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
