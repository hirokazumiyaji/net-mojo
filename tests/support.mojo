from std.ffi import external_call, c_int, c_uint, c_ulong
from std.testing import assert_equal

from net import Timeout
from net._sys.common import (
    AF_UNIX,
    F_GETFD,
    SOCK_STREAM,
    _OwnedFD,
    _fcntl,
    _set_nonblocking_cloexec,
)
from net.http import Handler, Server


def _assert_bytes_equal[
    left_origin: MutOrigin, right_origin: ImmOrigin
](
    left: Span[mut=True, Byte, left_origin], right: Span[Byte, right_origin]
) raises:
    assert_equal(len(left), len(right))
    for i in range(len(left)):
        assert_equal(left[i], right[i])


comptime _SIGALRM: Int32 = 14


def _join_thread(handle: UInt64) raises:
    """Joins a helper thread spawned with `pthread_create`.

    Every test-spawned thread must be joined before the spawning
    function returns: the thread only touches stack memory that dies
    with the test's frame, so an unjoined thread would race the
    frame's destruction. All thread entries use bounded waits, so a
    join always terminates.
    """
    var rc = external_call["pthread_join", c_int](
        c_ulong(handle), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    if Int(rc) != 0:
        raise Error("pthread_join failed")


def _noop_sigalrm_handler(sig: Int32):
    pass


def _arm_eintr_probe() raises:
    """Installs a no-op SIGALRM handler that lets blocking syscalls fail
    with EINTR instead of killing the process.

    `siginterrupt(..., 1)` disables SA_RESTART portably so the
    interruption is actually delivered as EINTR on both targets.
    Pair with `_disarm_alarm()` before the test ends.
    """
    _ = external_call["signal", c_int](c_int(_SIGALRM), _noop_sigalrm_handler)
    var intr = external_call["siginterrupt", c_int](c_int(_SIGALRM), c_int(1))
    if Int(intr) != 0:
        raise Error("siginterrupt failed")


def _sound_alarm(seconds: Int):
    _ = external_call["alarm", c_uint](c_uint(seconds))


def _disarm_alarm():
    _ = external_call["alarm", c_uint](c_uint(0))


def _count_open_fds() -> Int:
    """Counts open descriptors by probing 0..<getdtablesize with fcntl.

    Single-threaded use only. Used as a leak detector: count before
    and after repeated dial/close cycles with a warm-up in between.
    """
    var limit = Int(external_call["getdtablesize", c_int]())
    if limit < 0:
        return -1
    if limit > 65536:
        limit = 65536
    var count = 0
    for fd in range(limit):
        if _fcntl(c_int(fd), c_int(F_GETFD), c_int(0)) != -1:
            count += 1
    return count


@fieldwise_init
struct _SocketPair(Movable):
    var first: _OwnedFD
    var second: _OwnedFD


def _socket_pair() raises -> _SocketPair:
    var raw = SIMD[DType.int32, 2](0)
    var result = external_call["socketpair", c_int](
        c_int(AF_UNIX),
        c_int(SOCK_STREAM),
        c_int(0),
        Pointer(to=raw).unsafe_bitcast[c_int](),
    )
    if result != 0:
        raise Error("socketpair failed")
    var pair = _SocketPair(first=_OwnedFD(raw[0]), second=_OwnedFD(raw[1]))
    _set_nonblocking_cloexec(pair.first.raw())
    _set_nonblocking_cloexec(pair.second.raw())
    return pair^


def _tick_n[H: Handler](mut server: Server, mut handler: H, n: Int) raises:
    for _ in range(n):
        _ = server.tick(handler, Timeout.nanoseconds(0))


def _to_bytes(data: StringSlice) -> List[Byte]:
    return List[Byte](data.as_bytes())


def _header_end(buf: List[Byte]) -> Int:
    var i = 0
    while i + 3 < len(buf):
        if (
            buf[i] == Byte(ord("\r"))
            and buf[i + 1] == Byte(ord("\n"))
            and buf[i + 2] == Byte(ord("\r"))
            and buf[i + 3] == Byte(ord("\n"))
        ):
            return i + 4
        i += 1
    return -1


def _status_of(buf: List[Byte]) -> Int:
    if len(buf) < 12:
        return -1
    var code = 0
    for i in range(9, 12):
        var byte = buf[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return -1
        code = code * 10 + Int(byte - Byte(ord("0")))
    return code


def _content_length_of(buf: List[Byte]) -> Int:
    var end = _header_end(buf)
    if end < 0:
        return -1
    var head = String(from_utf8_lossy=Span(buf)[0:end]).lower()
    var needle = String("\r\ncontent-length:")
    var at = head.find(needle)
    if at < 0:
        return -1
    var value_start = at + len(needle.as_bytes())
    var value_end = value_start
    var head_bytes = head.as_bytes()
    while value_end < len(head_bytes) and (
        head_bytes[value_end] == Byte(ord(" "))
        or head_bytes[value_end] == Byte(ord("\t"))
    ):
        value_end += 1
    var digits_start = value_end
    while value_end < len(head_bytes) and (
        head_bytes[value_end] >= Byte(ord("0"))
        and head_bytes[value_end] <= Byte(ord("9"))
    ):
        value_end += 1
    if value_end == digits_start:
        return -1
    var value = 0
    for i in range(digits_start, value_end):
        value = value * 10 + Int(head_bytes[i] - Byte(ord("0")))
    return value


def _response_complete(buf: List[Byte], expect_body: Bool = True) -> Bool:
    var end = _header_end(buf)
    if end < 0:
        return False
    if not expect_body:
        return True
    var length = _content_length_of(buf)
    if length < 0:
        return True
    return len(buf) >= end + length


@fieldwise_init
struct _MalformedCase(Copyable, Movable):
    var name: String
    var raw: String
    var status: Int


def _malformed_corpus() -> List[_MalformedCase]:
    var cases = List[_MalformedCase]()
    cases.append(
        _MalformedCase(
            "bare_lf_request_line",
            String("GET /a HTTP/1.1\nHost: h\n\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "bare_cr_in_header_value",
            String("GET /a HTTP/1.1\r\nHost: h\r\nX-A: 1\r2\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "nul_in_header_value",
            String("GET /a HTTP/1.1\r\nHost: h\r\nX-A: a\x00b\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "bad_header_field_name",
            String("GET /a HTTP/1.1\r\nHost: h\r\nBad Header: 1\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "space_before_colon",
            String("GET /a HTTP/1.1\r\nHost: h\r\nX-A : 1\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "obs_fold_header",
            String("GET /a HTTP/1.1\r\nHost: h\r\nX-A: 1\r\n 2\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "missing_host",
            String("GET /a HTTP/1.1\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "duplicate_host",
            String("GET /a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "empty_host",
            String("GET /a HTTP/1.1\r\nHost:\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "host_with_space",
            String("GET /a HTTP/1.1\r\nHost: a b\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "duplicate_same_content_length",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n"
                "Content-Length: 3\r\n\r\nabc"
            ),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "content_length_and_transfer_encoding",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n"
                "Transfer-Encoding: chunked\r\n\r\n"
            ),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "non_numeric_content_length",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 12x\r\n\r\n"
            ),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "unknown_transfer_encoding",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\n"
            ),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "bad_chunk_size_hex",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
                " chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n"
            ),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "bad_chunk_extension_quoted",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
                ' chunked\r\n\r\n5;e="a\\\r"\r\nhello\r\n0\r\n\r\n'
            ),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "unsupported_http_version",
            String("GET /a HTTP/2.0\r\nHost: h\r\n\r\n"),
            505,
        )
    )
    cases.append(
        _MalformedCase(
            "unknown_http_version_shape",
            String("GET /a HTTP/foo\r\nHost: h\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "fragment_in_target",
            String("GET /a#frag HTTP/1.1\r\nHost: h\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "request_target_over_limit",
            String("GET /")
            + String("a") * 8200
            + String(" HTTP/1.1\r\nHost: h\r\n\r\n"),
            414,
        )
    )
    cases.append(
        _MalformedCase(
            "header_bytes_over_limit",
            String("GET /a HTTP/1.1\r\nHost: h\r\nX-Big: ")
            + String("y") * 33000
            + String("\r\n\r\n"),
            431,
        )
    )
    cases.append(
        _MalformedCase(
            "connect_rejected",
            String("CONNECT h:443 HTTP/1.1\r\nHost: h\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "upgrade_rejected",
            String("GET /a HTTP/1.1\r\nHost: h\r\nUpgrade: h2c\r\n\r\n"),
            400,
        )
    )
    cases.append(
        _MalformedCase(
            "unknown_expectation",
            String(
                "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nExpect:"
                " 418-teapot\r\n\r\nabc"
            ),
            417,
        )
    )
    return cases^


def _append_hpack_field(mut wire: List[Byte], name: String, value: String):
    var name_bytes = name.as_bytes()
    var value_bytes = value.as_bytes()
    wire.append(Byte((len(name_bytes) >> 24) & 0xFF))
    wire.append(Byte((len(name_bytes) >> 16) & 0xFF))
    wire.append(Byte((len(name_bytes) >> 8) & 0xFF))
    wire.append(Byte(len(name_bytes) & 0xFF))
    wire.append(Byte((len(value_bytes) >> 24) & 0xFF))
    wire.append(Byte((len(value_bytes) >> 16) & 0xFF))
    wire.append(Byte((len(value_bytes) >> 8) & 0xFF))
    wire.append(Byte(len(value_bytes) & 0xFF))
    wire.extend(name_bytes)
    wire.extend(value_bytes)
