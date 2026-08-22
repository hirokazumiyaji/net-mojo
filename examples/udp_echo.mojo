from std.testing import assert_equal, assert_false

from net import Timeout, listen_udp


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
    var server = listen_udp("127.0.0.1:0")
    var client = listen_udp("127.0.0.1:0")
    var payload: Array[Byte, 8] = [
        Byte(ord("u")),
        Byte(ord("d")),
        Byte(ord("p")),
        Byte(ord("-")),
        Byte(ord("e")),
        Byte(ord("c")),
        Byte(ord("h")),
        Byte(ord("o")),
    ]

    assert_equal(
        client.send_to(
            Span(payload), server.local_address(), Timeout.seconds(1)
        ),
        len(payload),
    )
    var server_buffer = Array[Byte, 8](fill=0)
    var request = server.recv_from(Span(server_buffer), Timeout.seconds(1))
    assert_equal(request.count, len(payload))
    assert_false(request.truncated)
    _assert_payload(Span(server_buffer), Span(payload))

    assert_equal(
        server.send_to(Span(server_buffer), request.source, Timeout.seconds(1)),
        len(payload),
    )
    var client_buffer = Array[Byte, 8](fill=0)
    var response = client.recv_from(Span(client_buffer), Timeout.seconds(1))
    assert_equal(response.count, len(payload))
    assert_false(response.truncated)
    _assert_payload(Span(client_buffer), Span(payload))

    client.close()
    server.close()
    print("UDP echo succeeded")
