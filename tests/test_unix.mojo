from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite
from std.tempfile import gettempdir
from std.time import perf_counter_ns

from net import Timeout, UnixAddress, dial_unix, listen_unix
from net.error import NetErrorKind
from net._sys.common import AF_UNIX, UNIX_PATH_MAX, _unix_address_to_raw
from tests.support import _assert_bytes_equal


def _unique_path(suffix: StringSlice) raises -> String:
    var directory = gettempdir()
    if not directory:
        raise Error("no temporary directory is available")
    var directory_path = directory.value()
    var process = external_call["getpid", c_int]()
    return String(t"{directory_path}/nm-{process}-{perf_counter_ns()}-{suffix}")


def _unlink(path: StringSlice):
    var owned_path = String(path)
    var c_path = owned_path.as_c_string_span()
    _ = external_call["unlink", c_int](c_path.ptr())


def _exists(path: StringSlice) -> Bool:
    var owned_path = String(path)
    var c_path = owned_path.as_c_string_span()
    return external_call["access", c_int](c_path.ptr(), c_int(0)) == 0


struct _PathCleanup(Movable):
    var path: String

    def __init__(out self, path: String):
        self.path = String(path)

    def __deinit__(deinit self):
        _unlink(self.path)


def _repeated_ascii(length: Int) -> String:
    var bytes = List[Byte]()
    for _ in range(length):
        bytes.append(Byte(ord("a")))
    return String(from_utf8_lossy=Span(bytes))


def _assert_invalid_path(path: StringSlice) raises:
    try:
        _ = UnixAddress.parse(path)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
        return
    raise Error("UnixAddress accepted an invalid path")


def test_unix_address_rejects_empty_path() raises:
    _assert_invalid_path("")


def test_unix_address_rejects_embedded_nul() raises:
    _assert_invalid_path("a\0b")


def test_unix_address_enforces_platform_byte_limit() raises:
    var maximum = _repeated_ascii(UNIX_PATH_MAX)
    assert_equal(UnixAddress.parse(maximum).path, maximum)
    _assert_invalid_path(_repeated_ascii(UNIX_PATH_MAX + 1))


def test_unix_address_value_traits() raises:
    var left = UnixAddress.parse("/tmp/net-mojo-value")
    var right = left.copy()
    assert_equal(left, right)
    assert_equal(hash(left), hash(right))
    assert_equal(String(left), "/tmp/net-mojo-value")


def test_unix_raw_address_has_exact_nul_terminated_length() raises:
    var raw = _unix_address_to_raw("abc")
    assert_equal(raw.length, UInt32(6))
    var pointer = raw.unsafe_ptr()
    comptime if CompilationTarget.is_macos():
        assert_equal(pointer[unsafe_offset=0], Byte(6))
        assert_equal(pointer[unsafe_offset=1], Byte(AF_UNIX))
    else:
        assert_equal(pointer[unsafe_offset=0], Byte(AF_UNIX))
        assert_equal(pointer[unsafe_offset=1], Byte(0))
    assert_equal(pointer[unsafe_offset=2], Byte(ord("a")))
    assert_equal(pointer[unsafe_offset=3], Byte(ord("b")))
    assert_equal(pointer[unsafe_offset=4], Byte(ord("c")))
    assert_equal(pointer[unsafe_offset=5], Byte(0))
    assert_equal(pointer[unsafe_offset=6], Byte(0))
    assert_true(raw.length < UInt32(128))


def test_unix_loopback_round_trip_and_eof() raises:
    var path = _unique_path("round")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    var client = dial_unix(path, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var ping: Array[Byte, 4] = [
        Byte(ord("p")),
        Byte(ord("i")),
        Byte(ord("n")),
        Byte(ord("g")),
    ]
    client.write_all(Span(ping), Timeout.seconds(1))
    var received_ping = Array[Byte, 4](fill=0)
    assert_equal(server.read(Span(received_ping), Timeout.seconds(1)), 4)
    _assert_bytes_equal(Span(received_ping), Span(ping))

    var pong: Array[Byte, 4] = [
        Byte(ord("p")),
        Byte(ord("o")),
        Byte(ord("n")),
        Byte(ord("g")),
    ]
    server.write_all(Span(pong), Timeout.seconds(1))
    var received_pong = Array[Byte, 4](fill=0)
    assert_equal(client.read(Span(received_pong), Timeout.seconds(1)), 4)
    _assert_bytes_equal(Span(received_pong), Span(pong))

    client.close()
    var eof_buffer = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(eof_buffer), Timeout.seconds(1)), 0)
    server.close()
    listener.close()
    assert_true(_exists(path))
    _unlink(path)
    _ = cleanup.path


def test_existing_regular_file_is_preserved() raises:
    var path = _unique_path("file")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    with open(path, "w"):
        pass
    try:
        _ = listen_unix(path)
    except error:
        assert_equal(error.kind, NetErrorKind.system_error())
        assert_true(_exists(path))
        _unlink(path)
        _ = cleanup.path
        return
    raise Error("listen_unix replaced an existing regular file")


def test_duplicate_listen_does_not_remove_first_socket() raises:
    var path = _unique_path("duplicate")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    var rejected = False
    try:
        _ = listen_unix(path)
    except error:
        assert_equal(error.kind, NetErrorKind.system_error())
        rejected = True
    assert_true(rejected)
    assert_true(_exists(path))

    var client = dial_unix(path, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var sent = Array[Byte, 1](fill=73)
    assert_equal(client.write(Span(sent)), 1)
    var received = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(received), Timeout.seconds(1)), 1)
    assert_equal(received[0], Byte(73))
    client.close()
    server.close()
    listener.close()
    _unlink(path)
    _ = cleanup.path


def test_unix_accept_timeout() raises:
    var path = _unique_path("accept")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    var timed_out = False
    try:
        _ = listener.accept(Timeout.milliseconds(5))
    except error:
        assert_equal(error.kind, NetErrorKind.timeout())
        timed_out = True
    assert_true(timed_out)
    listener.close()
    _unlink(path)
    _ = cleanup.path


def test_unix_read_timeout() raises:
    var path = _unique_path("read")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    var client = dial_unix(path, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var buffer = Array[Byte, 1](fill=0)
    var timed_out = False
    try:
        _ = server.read(Span(buffer), Timeout.milliseconds(5))
    except error:
        assert_equal(error.kind, NetErrorKind.timeout())
        timed_out = True
    assert_true(timed_out)
    client.close()
    server.close()
    listener.close()
    _unlink(path)
    _ = cleanup.path


def test_unix_write_after_peer_close_does_not_terminate_process() raises:
    var path = _unique_path("sigpipe")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    var client = dial_unix(path, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    server.close()

    var eof_buffer = Array[Byte, 1](fill=0)
    assert_equal(client.read(Span(eof_buffer), Timeout.seconds(1)), 0)
    var sent = Array[Byte, 1](fill=1)
    var failed = False
    for _ in range(4):
        try:
            _ = client.write(Span(sent), Timeout.seconds(1))
        except error:
            assert_equal(error.kind, NetErrorKind.system_error())
            failed = True
            break
    assert_true(failed)
    client.close()
    listener.close()
    _unlink(path)
    _ = cleanup.path


def test_unix_listen_rejects_invalid_backlog() raises:
    var path = _unique_path("backlog")
    _unlink(path)
    try:
        _ = listen_unix(path, backlog=0)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
    else:
        raise Error("listen_unix accepted backlog zero")
    try:
        _ = listen_unix(path, backlog=Int(Int32.MAX) + 1)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        return
    raise Error("listen_unix accepted an oversized backlog")


def test_unix_public_functions_validate_path_before_socket() raises:
    try:
        _ = dial_unix("")
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
    else:
        raise Error("dial_unix accepted an empty path")
    try:
        _ = listen_unix("a\0b")
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
        return
    raise Error("listen_unix accepted an embedded NUL")


def test_unix_second_close_reports_closed() raises:
    var path = _unique_path("close")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    listener.close()
    try:
        listener.close()
    except error:
        assert_equal(error.kind, NetErrorKind.closed())
        assert_true(_exists(path))
        _unlink(path)
        _ = cleanup.path
        return
    raise Error("UnixListener second close unexpectedly succeeded")


def test_zero_timeout_allows_immediate_unix_connect() raises:
    var path = _unique_path("zero-timeout")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    var client = dial_unix(path, Timeout.nanoseconds(0))
    var server = listener.accept(Timeout.seconds(1))
    assert_true(_exists(path))
    client.close()
    server.close()
    listener.close()
    _unlink(path)
    _ = cleanup.path


def test_unix_addresses_and_half_close() raises:
    var path = _unique_path("addrs")
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
    assert_equal(String(listener.local_address()), path)
    var client = dial_unix(path, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    # The accepted socket reports the bound path; the dial side was
    # never bound, so its own addresses are unavailable.
    assert_equal(String(server.local_address()), path)
    try:
        _ = client.local_address()
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
    else:
        raise Error("unbound Unix client reported a local address")
    try:
        _ = server.remote_address()
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
    else:
        raise Error("server reported an address for an unbound peer")
    # Half-close sends EOF without closing the descriptor.
    client.shutdown(False, True)
    var eof_buffer = Array[Byte, 1](fill=0)
    assert_equal(server.read(Span(eof_buffer), Timeout.seconds(1)), 0)
    client.close()
    server.close()
    listener.close()
    _unlink(path)
    _ = cleanup.path


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
