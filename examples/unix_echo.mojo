from std.ffi import c_int, external_call
from std.tempfile import gettempdir
from std.testing import assert_equal
from std.time import perf_counter_ns

from net import Timeout, dial_unix, listen_unix


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
    var c_path = owned_path.as_c_string_slice()
    _ = external_call["unlink", c_int](c_path.unsafe_ptr())


struct _PathCleanup(Movable):
    var path: String

    def __init__(out self, path: StringSlice):
        self.path = String(path)

    def __deinit__(deinit self):
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


def main() raises:
    var path = _socket_path()
    _unlink(path)
    var cleanup = _PathCleanup(path)
    var listener = listen_unix(path)
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
    assert_equal(
        server.read(Span(server_buffer), Timeout.seconds(1)), len(payload)
    )
    _assert_payload(Span(server_buffer), Span(payload))

    server.write_all(Span(server_buffer), Timeout.seconds(1))
    var client_buffer = Array[Byte, 9](fill=0)
    assert_equal(
        client.read(Span(client_buffer), Timeout.seconds(1)), len(payload)
    )
    _assert_payload(Span(client_buffer), Span(payload))

    client.close()
    server.close()
    listener.close()
    _unlink(path)
    _ = cleanup.path
    print("Unix echo succeeded")
