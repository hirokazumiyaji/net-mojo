from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)

from net.error import NetErrorKind
from net import dial_tcp, listen_tcp, listen_udp
from net.timeout import Timeout, _Deadline
from tests.support import _count_open_fds, _socket_pair
from net._sys.readiness import (
    _decode_gen_low,
    _decode_slot,
    _encode_token,
    _EventQueue,
    _verify_readiness_abi,
)
from net._sys.common import (
    AF_INET,
    EAGAIN,
    EINPROGRESS,
    EINTR,
    EWOULDBLOCK,
    FD_CLOEXEC,
    F_GETFD,
    SOCK_STREAM,
    _CONNECT_FAILED,
    _CONNECT_PENDING,
    _CONNECT_SUCCEEDED,
    _OwnedFD,
    _accept_status,
    _connect_attempt_allowed,
    _connect_disposition,
    _default_listen_backlog,
    _parse_backlog_limit,
    _recv_from_status,
    _recv_status,
    _send_status,
    _socket,
    _wait_readable,
    _wait_writable,
)


def _test_fcntl[
    *types: Intable
](fd: c_int, command: c_int, *args: *types) -> c_int:
    return external_call["fcntl", c_int, num_fixed_args=2](
        fd, command, args.get_loaded_kgen_pack()
    )


def test_descriptor_lifecycle_and_readiness() raises:
    var pair = _socket_pair()
    assert_true(pair.first.is_valid())
    assert_true(pair.second.is_valid())
    assert_true(
        _wait_writable(
            pair.first.raw(),
            _Deadline.from_timeout(Timeout.seconds(1)),
        )
    )
    assert_false(
        _wait_readable(
            pair.first.raw(),
            _Deadline.from_timeout(Timeout.nanoseconds(0)),
        )
    )
    pair.second.close()
    assert_false(pair.second.is_valid())


def test_move_transfers_descriptor() raises:
    var source = _socket(AF_INET, SOCK_STREAM, 0)
    var raw = source.raw()
    var moved = source^
    assert_equal(moved.raw(), raw)
    var flags = _test_fcntl(c_int(moved.raw()), c_int(F_GETFD), c_int(0))
    assert_true(flags >= 0)
    assert_true(moved.is_valid())


def test_take_invalidates_source() raises:
    var source = _socket(AF_INET, SOCK_STREAM, 0)
    var raw = source._take()
    assert_false(source.is_valid())
    var reclaimed = _OwnedFD(raw)
    assert_true(reclaimed.is_valid())


def test_double_close_reports_closed() raises:
    var pair = _socket_pair()
    pair.first.close()
    try:
        pair.first.close()
    except error:
        assert_equal(error.kind, NetErrorKind.closed())
        return
    raise Error("double close succeeded")


def test_socket_sets_close_on_exec() raises:
    var socket = _socket(AF_INET, SOCK_STREAM, 0)
    var raw = socket.raw()
    var flags = _test_fcntl(c_int(raw), c_int(F_GETFD), c_int(0))
    assert_true(flags >= 0)
    assert_true((flags & FD_CLOEXEC) != 0)
    assert_true(socket.is_valid())


def test_sent_byte_makes_peer_readable() raises:
    var pair = _socket_pair()
    var payload = Array[Byte, 1](fill=42)
    var send_status = _send_status(pair.first.raw(), Span(payload))
    assert_equal(send_status.error_number, 0)
    assert_equal(send_status.value, 1)
    assert_true(
        _wait_readable(
            pair.second.raw(),
            _Deadline.from_timeout(Timeout.seconds(1)),
        )
    )
    var received = Array[Byte, 1](fill=0)
    var recv_status = _recv_status(pair.second.raw(), Span(received))
    assert_equal(recv_status.error_number, 0)
    assert_equal(recv_status.value, 1)
    assert_equal(received[0], Byte(42))
    assert_true(pair.first.is_valid())


def test_poll_timeout_uses_remaining_deadline() raises:
    var pair = _socket_pair()
    var deadline = _Deadline.from_timeout(Timeout.milliseconds(5))
    assert_false(_wait_readable(pair.first.raw(), deadline))
    assert_true(deadline.remaining_milliseconds() <= 1)
    assert_true(pair.second.is_valid())


def test_connect_disposition_retries_interruption_on_the_same_socket() raises:
    assert_equal(_connect_disposition(0), _CONNECT_SUCCEEDED)
    assert_equal(_connect_disposition(EINPROGRESS), _CONNECT_PENDING)
    assert_equal(_connect_disposition(EINTR), _CONNECT_PENDING)
    assert_equal(_connect_disposition(1), _CONNECT_FAILED)


def test_connect_attempt_allows_only_the_first_expired_attempt() raises:
    var deadline = _Deadline.from_timeout(Timeout.nanoseconds(0))
    assert_true(_connect_attempt_allowed(False, deadline))
    assert_false(_connect_attempt_allowed(True, deadline))


def test_nonblocking_recv_returns_errno_status_without_throwing() raises:
    var pair = _socket_pair()
    var buffer = Array[Byte, 1](fill=0)
    var status = _recv_status(pair.first.raw(), Span(buffer))
    assert_true(pair.first.is_valid())
    assert_equal(status.value, -1)
    assert_true(
        status.error_number == EAGAIN or status.error_number == EWOULDBLOCK
    )


def test_nonblocking_accept_returns_errno_status_without_throwing() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var status = _accept_status(listener._fd.raw())
    assert_true(listener._fd.is_valid())
    assert_false(status.fd.is_valid())
    assert_true(
        status.error_number == EAGAIN or status.error_number == EWOULDBLOCK
    )


def test_nonblocking_recvmsg_returns_errno_status_without_throwing() raises:
    var socket = listen_udp("127.0.0.1:0")
    var buffer = Array[Byte, 1](fill=0)
    var status = _recv_from_status(socket._fd.raw(), Span(buffer))
    assert_true(socket._fd.is_valid())
    assert_equal(status.count, -1)
    assert_true(
        status.error_number == EAGAIN or status.error_number == EWOULDBLOCK
    )


def test_backlog_limit_parser_accepts_plain_integers() raises:
    var sized = _parse_backlog_limit("4096\n")
    if not sized:
        raise Error("parser rejected a valid backlog value")
    assert_equal(sized.value(), 4096)
    var plain = _parse_backlog_limit("128")
    if not plain:
        raise Error("parser rejected a valid backlog value")
    assert_equal(plain.value(), 128)


def test_backlog_limit_parser_rejects_garbage() raises:
    var cases = ["", "   \n", "0", "-1", "12a4", "abc", "4294967296"]
    for text in cases:
        var parsed = _parse_backlog_limit(text)
        if parsed:
            raise Error("parser accepted a garbage backlog value")


def test_default_backlog_is_a_stable_valid_listen_size() raises:
    var first = _default_listen_backlog()
    var second = _default_listen_backlog()
    assert_true(first >= 1)
    assert_true(first <= Int(Int32.MAX))
    assert_equal(first, second)


def test_open_fd_count_returns_to_baseline() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var target = String(listener.local_address())
    # Warm-up absorbs one-time runtime allocations before measuring.
    for _ in range(3):
        var warm_client = dial_tcp(target, Timeout.seconds(1))
        var warm_server = listener.accept(Timeout.seconds(1))
        warm_client.close()
        warm_server.close()
    var before = _count_open_fds()
    assert_true(before > 0)
    for _ in range(20):
        var client = dial_tcp(target, Timeout.seconds(1))
        var server = listener.accept(Timeout.seconds(1))
        client.close()
        server.close()
    var after = _count_open_fds()
    assert_equal(before, after)
    listener.close()


def test_readiness_abi_sizes_offsets_and_token_roundtrip() raises:
    from std.sys import align_of, size_of

    import net._sys.darwin as darwin
    import net._sys.linux as linux
    from net._sys.readiness import _Timespec

    _verify_readiness_abi()
    assert_equal(size_of[_Timespec](), 16)
    assert_equal(align_of[_Timespec](), 8)
    # Offset checks via raw byte writes: each field lands where C expects.
    var ts = _Timespec(tv_sec=Int64(0x0102030405060708), tv_nsec=Int64(0))
    var ts_bytes = Pointer(to=ts).unsafe_bitcast[UInt8]()
    assert_equal(ts_bytes[unsafe_offset=0], 8)
    assert_equal(ts_bytes[unsafe_offset=7], 1)
    comptime if CompilationTarget.is_macos():
        assert_equal(size_of[darwin._Kevent](), 32)
        assert_equal(align_of[darwin._Kevent](), 8)
        var kev = darwin._Kevent(
            ident=UInt64(0x0807060504030201),
            filter=Int16(-1),
            flags=UInt16(5),
            fflags=UInt32(0),
            data=Int64(0),
            udata=UInt64(0),
        )
        var kev_bytes = Pointer(to=kev).unsafe_bitcast[UInt8]()
        assert_equal(kev_bytes[unsafe_offset=0], 1)
        assert_equal(kev_bytes[unsafe_offset=7], 8)
        assert_equal(kev_bytes[unsafe_offset=8], 255)
        assert_equal(kev_bytes[unsafe_offset=10], 5)
    else:
        comptime if linux._EPOLL_PACKED:
            # x86-64 packed layout: events@0, data@4, size 12.
            assert_equal(size_of[linux._EpollEventPacked](), 12)
            assert_equal(align_of[linux._EpollEventPacked](), 4)
            var ev = linux._EpollEventPacked(
                events=UInt32(0x04030201),
                data_lo=UInt32(0x04030201),
                data_hi=UInt32(0x08070605),
            )
            var ev_bytes = Pointer(to=ev).unsafe_bitcast[UInt8]()
            assert_equal(ev_bytes[unsafe_offset=0], 1)
            assert_equal(ev_bytes[unsafe_offset=3], 4)
            assert_equal(ev_bytes[unsafe_offset=4], 1)
            assert_equal(ev_bytes[unsafe_offset=11], 8)
        else:
            # aarch64 natural layout: events@0, 4B padding, data@8, size 16.
            assert_equal(size_of[linux._EpollEventAligned](), 16)
            assert_equal(align_of[linux._EpollEventAligned](), 8)
            var ev = linux._EpollEventAligned(
                events=UInt32(0x04030201),
                _reserved=0,
                data=UInt64(0x0807060504030201),
            )
            var ev_bytes = Pointer(to=ev).unsafe_bitcast[UInt8]()
            assert_equal(ev_bytes[unsafe_offset=0], 1)
            assert_equal(ev_bytes[unsafe_offset=3], 4)
            assert_equal(ev_bytes[unsafe_offset=8], 1)
            assert_equal(ev_bytes[unsafe_offset=15], 8)
    # Event token round-trip: slot and generation survive the kernel u64.
    var wire = _encode_token(12345, UInt64(0xABCDEF12))
    assert_equal(_decode_slot(wire), 12345)
    assert_equal(_decode_gen_low(wire), UInt64(0xABCDEF12))


def test_event_queue_fd_leak() raises:
    for _ in range(3):
        var warm = _EventQueue()
        _ = warm.raw_fd()
    var before = _count_open_fds()
    assert_true(before > 0)
    for _ in range(20):
        var queue = _EventQueue()
        _ = queue.raw_fd()
    var after = _count_open_fds()
    assert_equal(before, after)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
