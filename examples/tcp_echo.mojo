from std.testing import assert_equal

from net import Timeout, dial_tcp, listen_tcp


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
    assert_equal(
        server.read(Span(server_buffer), Timeout.seconds(1)), len(payload)
    )
    _assert_payload(Span(server_buffer), Span(payload))

    server.write_all(Span(server_buffer), Timeout.seconds(1))
    var client_buffer = Array[Byte, 8](fill=0)
    assert_equal(
        client.read(Span(client_buffer), Timeout.seconds(1)), len(payload)
    )
    _assert_payload(Span(client_buffer), Span(payload))

    client.close()
    server.close()
    listener.close()
    print("TCP echo succeeded")
