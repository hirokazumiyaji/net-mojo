from std.testing import assert_equal

from net import TCPConn, Timeout, dial_tcp, listen_tcp


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
    connection: TCPConn,
    buffer: Span[mut=True, Byte, origin],
    timeout: Timeout,
) raises:
    var offset = 0
    while offset < len(buffer):
        var count = connection.read(buffer[offset:], timeout.copy())
        if count == 0:
            raise Error("TCP stream ended before the payload was complete")
        offset += count


def main() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var payload: Array[Byte, 8] = [
        Byte(ord("t")),
        Byte(ord("c")),
        Byte(ord("p")),
        Byte(ord("-")),
        Byte(ord("e")),
        Byte(ord("c")),
        Byte(ord("h")),
        Byte(ord("o")),
    ]

    client.write_all(Span(payload), Timeout.seconds(1))
    var server_buffer = Array[Byte, 8](fill=0)
    _read_exact(server, Span(server_buffer), Timeout.seconds(1))
    _assert_payload(Span(server_buffer), Span(payload))

    server.write_all(Span(server_buffer), Timeout.seconds(1))
    var client_buffer = Array[Byte, 8](fill=0)
    _read_exact(client, Span(client_buffer), Timeout.seconds(1))
    _assert_payload(Span(client_buffer), Span(payload))

    client.close()
    server.close()
    listener.close()
    print("TCP echo succeeded")
