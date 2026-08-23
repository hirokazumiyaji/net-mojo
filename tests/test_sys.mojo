from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from net.error import NetErrorKind
from net import listen_tcp, listen_udp
from net.timeout import Timeout, _Deadline
from net._sys.common import (
    AF_INET,
    AF_UNIX,
    EAGAIN,
    EINPROGRESS,
    EINTR,
    EWOULDBLOCK,
    FD_CLOEXEC,
    F_GETFD,
    SOCK_STREAM,
    _CONNECT_FAILED,
    _CONNECT_PENDING,
    _CONNECT_RETRY,
    _CONNECT_SUCCEEDED,
    _OwnedFD,
    _accept_status,
    _connect_attempt_allowed,
    _connect_disposition,
    _recv_from_status,
    _recv_status,
    _recv,
    _send,
    _set_nonblocking_cloexec,
    _socket,
    _wait_readable,
    _wait_writable,
)


@fieldwise_init
struct _TestSocketPair(Movable):
    var first: _OwnedFD
    var second: _OwnedFD


def _test_fcntl[
    *types: Intable
](fd: c_int, command: c_int, *args: *types) -> c_int:
    return external_call["fcntl", c_int, num_fixed_args=2](
        fd, command, args.get_loaded_kgen_pack()
    )


def _test_socket_pair() raises -> _TestSocketPair:
    var raw = SIMD[DType.int32, 2](0)
    var result = external_call["socketpair", c_int](
        c_int(AF_UNIX),
        c_int(SOCK_STREAM),
        c_int(0),
        Pointer(to=raw).unsafe_bitcast[c_int](),
    )
    if result != 0:
        raise Error("socketpair failed")
    var pair = _TestSocketPair(first=_OwnedFD(raw[0]), second=_OwnedFD(raw[1]))
    _set_nonblocking_cloexec(pair.first.raw())
    _set_nonblocking_cloexec(pair.second.raw())
    return pair^


def test_descriptor_lifecycle_and_readiness() raises:
    var pair = _test_socket_pair()
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
    var pair = _test_socket_pair()
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
    var pair = _test_socket_pair()
    var payload = Array[Byte, 1](fill=42)
    assert_equal(_send(pair.first.raw(), Span(payload)), 1)
    assert_true(
        _wait_readable(
            pair.second.raw(),
            _Deadline.from_timeout(Timeout.seconds(1)),
        )
    )
    var received = Array[Byte, 1](fill=0)
    assert_equal(_recv(pair.second.raw(), Span(received)), 1)
    assert_equal(received[0], Byte(42))
    assert_true(pair.first.is_valid())


def test_poll_timeout_uses_remaining_deadline() raises:
    var pair = _test_socket_pair()
    var deadline = _Deadline.from_timeout(Timeout.milliseconds(5))
    assert_false(_wait_readable(pair.first.raw(), deadline))
    assert_true(deadline.remaining_milliseconds() <= 1)
    assert_true(pair.second.is_valid())


def test_connect_disposition_keeps_interruption_distinct_from_pending() raises:
    assert_equal(_connect_disposition(0), _CONNECT_SUCCEEDED)
    assert_equal(_connect_disposition(EINPROGRESS), _CONNECT_PENDING)
    assert_equal(_connect_disposition(EINTR), _CONNECT_RETRY)
    assert_equal(_connect_disposition(1), _CONNECT_FAILED)


def test_connect_attempt_allows_only_the_first_expired_attempt() raises:
    var deadline = _Deadline.from_timeout(Timeout.nanoseconds(0))
    assert_true(_connect_attempt_allowed(False, deadline))
    assert_false(_connect_attempt_allowed(True, deadline))


def test_nonblocking_recv_returns_errno_status_without_throwing() raises:
    var pair = _test_socket_pair()
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
