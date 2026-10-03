from std.ffi import c_int, external_call, get_errno
from std.tempfile import gettempdir
from std.testing import assert_equal
from std.time import perf_counter_ns

from net import Timeout, UnixConn, dial_unix, listen_unix


def _socket_path() raises -> String:
    var directory = gettempdir()
    if not directory:
        raise Error("no temporary directory is available")
    var process = external_call["getpid", c_int]()
    return String(
        t"{directory.value()}/net-mojo-{process}-{perf_counter_ns()}.sock"
    )


def _unlink(path: StringSlice):
    var owned_path = String(path)
    var c_path = owned_path.as_c_string_span()
    _ = external_call["unlink", c_int](c_path.ptr())


def _unlink_checked(path: StringSlice) raises:
    var owned_path = String(path)
    var c_path = owned_path.as_c_string_span()
    if external_call["unlink", c_int](c_path.ptr()) != 0:
        var error_number = get_errno().value
        raise Error(
            String(t"failed to remove Unix socket path (errno {error_number})")
        )


struct _PathCleanup(Movable):
    var path: String
    var armed: Bool

    def __init__(out self):
        self.path = String()
        self.armed = False

    def arm(mut self, path: StringSlice):
        self.path = String(path)
        self.armed = True

    def remove(mut self) raises:
        if not self.armed:
            raise Error("Unix socket path cleanup is not armed")
        self.armed = False
        _unlink_checked(self.path)

    def __deinit__(deinit self):
        if self.armed:
            _unlink(self.path)


def _assert_payload[
    received_origin: MutOrigin, expected_origin: ImmOrigin
](
    received: Span[mut=True, Byte, received_origin],
    expected: Span[Byte, expected_origin],
) raises:
    assert_equal(len(received), len(expected))
    for i in range(len(expected)):
        assert_equal(received[i], expected[i])


def _read_exact[
    origin: MutOrigin
](
    connection: UnixConn,
    buffer: Span[mut=True, Byte, origin],
    timeout: Timeout,
) raises:
    var offset = 0
    while offset < len(buffer):
        var count = connection.read(buffer[offset:], timeout.copy())
        if count == 0:
            raise Error("Unix stream ended before the payload was complete")
        offset += count


def main() raises:
    var path = _socket_path()
    var cleanup = _PathCleanup()
    var listener = listen_unix(path)
    cleanup.arm(path)
    var client = dial_unix(path, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var payload: Array[Byte, 9] = [
        Byte(ord("u")),
        Byte(ord("n")),
        Byte(ord("i")),
        Byte(ord("x")),
        Byte(ord("-")),
        Byte(ord("e")),
        Byte(ord("c")),
        Byte(ord("h")),
        Byte(ord("o")),
    ]

    client.write_all(Span(payload), Timeout.seconds(1))
    var server_buffer = Array[Byte, 9](fill=0)
    _read_exact(server, Span(server_buffer), Timeout.seconds(1))
    _assert_payload(Span(server_buffer), Span(payload))

    server.write_all(Span(server_buffer), Timeout.seconds(1))
    var client_buffer = Array[Byte, 9](fill=0)
    _read_exact(client, Span(client_buffer), Timeout.seconds(1))
    _assert_payload(Span(client_buffer), Span(payload))

    client.close()
    server.close()
    listener.close()
    cleanup.remove()
    print("Unix echo succeeded")
