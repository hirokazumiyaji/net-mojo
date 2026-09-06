from std.ffi import c_int, c_ulong, external_call
from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from net import SocketAddress, TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetError, NetErrorKind
from net.tcp import _dial_tcp_candidates
from net._stream import _read_with_deadline
from net._sys.common import (
    ECONNREFUSED,
    ECONNRESET,
    EPIPE,
    FD_CLOEXEC,
    F_GETFD,
    F_GETFL,
    IPPROTO_IPV6,
    IPPROTO_TCP,
    IPV6_V6ONLY,
    O_NONBLOCK,
    SOL_SOCKET,
    SO_KEEPALIVE,
    SO_RCVBUF,
    SO_SNDBUF,
    TCP_KEEPIDLE,
    TCP_KEEPINTVL,
    TCP_NODELAY,
    _fcntl,
    _get_linger,
    _get_socket_option_int,
)
from net.timeout import _Deadline
from tests.support import (
    _arm_eintr_probe,
    _assert_bytes_equal,
    _disarm_alarm,
    _join_thread,
    _sound_alarm,
)


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


def test_accept_with_address_returns_peer_without_getpeername() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var accepted = listener.accept_with_address(Timeout.seconds(1))
    # NOTE: compare via String rendering of bound vars. Passing
    # SocketAddress values (fields or call temporaries) straight into
    # generic assert_equal misreads the second argument in-suite (same
    # Mojo 1.0 temporary-lifetime family as #18); String comparisons
    # evaluate correctly.
    var peer_side = accepted.address.copy()
    var client_side = client.local_address()
    assert_equal(String(peer_side), String(client_side))
    assert_equal(String(accepted.conn.local_address()), String(listening))
    assert_equal(String(accepted.conn.remote_address()), String(client_side))

    var ping: Array[Byte, 4] = [
        Byte(ord("p")),
        Byte(ord("i")),
        Byte(ord("n")),
        Byte(ord("g")),
    ]
    client.write_all(Span(ping), Timeout.seconds(1))
    var received = Array[Byte, 4](fill=0)
    assert_equal(accepted.conn.read(Span(received), Timeout.seconds(1)), 4)
    _assert_bytes_equal(Span(received), Span(ping))

    client.close()
    accepted.conn.close()
    listener.close()


def test_sockets_are_nonblocking_and_cloexec() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    for fd in [client._fd.raw(), server._fd.raw(), listener._fd.raw()]:
        var flags = _fcntl(c_int(fd), c_int(F_GETFL), c_int(0))
        assert_true((flags & O_NONBLOCK) != 0)
        var descriptor = _fcntl(c_int(fd), c_int(F_GETFD), c_int(0))
        assert_true((descriptor & FD_CLOEXEC) != 0)
    client.close()
    server.close()
    listener.close()


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


def test_explicit_backlog_serves_a_connection() raises:
    var listener = listen_tcp("127.0.0.1:0", backlog=1)
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var sent: Array[Byte, 1] = [7]
    client.write_all(Span(sent), Timeout.seconds(1))
    var received = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(received), Timeout.seconds(1)), 1)
    assert_equal(received[0], Byte(7))
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


@fieldwise_init
struct _DrainCtx(Copyable, Movable):
    var fd: Int
    var want: Int
    var got: Int
    var sum: Int
    var err: Int
    var deadline: _Deadline


def _drain_entry(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var cp = arg.unsafe_bitcast[_DrainCtx]()
    var fd = Int32(cp[].fd)
    var deadline = cp[].deadline.copy()
    var buf = Array[Byte, 65536](fill=0)
    while cp[].got < cp[].want:
        try:
            var n = _read_with_deadline(fd, Span(buf), deadline)
            if n == 0:
                break
            var chunk_sum = 0
            for i in range(n):
                chunk_sum += Int(buf[i])
            cp[].got = cp[].got + n
            cp[].sum = cp[].sum + chunk_sum
            sleep(0.005)
        except e:
            cp[].err = -1
            break
    return arg


def test_threaded_slow_reader_drains_large_transfer() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var total = 1024 * 1024
    var ctx = _DrainCtx(
        Int(server._fd.raw()),
        total,
        0,
        0,
        0,
        _Deadline.from_timeout(Timeout.seconds(15)),
    )
    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _drain_entry,
        Pointer(to=ctx).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    var payload = Array[Byte, 1024 * 1024](fill=0)
    var expected_sum = 0
    for i in range(len(payload)):
        payload[i] = Byte(i % 251)
        expected_sum += Int(payload[i])
    client.write_all(Span(payload), Timeout.seconds(15))
    _join_thread(handle)
    assert_equal(ctx.err, 0)
    assert_equal(ctx.got, total)
    assert_equal(ctx.sum, expected_sum)
    client.close()
    server.close()
    listener.close()


def test_real_signal_eintr_retries_to_deadline() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    # SIGALRM fires 1s into a 3s blocking read with no data coming.
    # The EINTR must be retried internally: the read survives to its
    # deadline and reports a timeout instead of a system error.
    _arm_eintr_probe()
    _sound_alarm(1)
    var buf = Array[Byte, 64](fill=0)
    var start = Int(perf_counter_ns())
    try:
        _ = server.read(Span(buf), Timeout.seconds(3))
    except e:
        assert_equal(e.kind, NetErrorKind.timeout())
    var elapsed_ms = (Int(perf_counter_ns()) - start) // 1_000_000
    _disarm_alarm()
    assert_true(elapsed_ms >= 2500)
    client.close()
    server.close()
    listener.close()


@fieldwise_init
struct _CancelCtx(Copyable, Movable):
    var fd: Int
    var result: Int
    var deadline: _Deadline


def _cancel_reader_entry(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var cp = arg.unsafe_bitcast[_CancelCtx]()
    var buf = Array[Byte, 64](fill=0)
    try:
        cp[].result = _read_with_deadline(
            Int32(cp[].fd), Span(buf), cp[].deadline.copy()
        )
    except e:
        cp[].result = -99
    return arg


def test_shutdown_from_main_releases_blocked_reader() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    # The helper thread blocks in read with no data coming. shutdown
    # from this thread must release it promptly with EOF, proving the
    # cancellation path of #19 without threads owning connections:
    # only the raw fd number crosses the thread boundary.
    var ctx = _CancelCtx(
        Int(server._fd.raw()),
        -999,
        _Deadline.from_timeout(Timeout.seconds(5)),
    )
    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _cancel_reader_entry,
        Pointer(to=ctx).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    sleep(0.3)
    var start = Int(perf_counter_ns())
    client.shutdown(False, True)
    _join_thread(handle)
    var waited_ms = (Int(perf_counter_ns()) - start) // 1_000_000
    assert_equal(ctx.result, 0)
    assert_true(waited_ms < 2000)
    client.close()
    server.close()
    listener.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
