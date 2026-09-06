from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net import Timeout, dial_udp, listen_udp
from net._sys.common import (
    ECONNREFUSED,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    _get_socket_option_int,
)
from net.error import NetErrorKind
from tests.support import _assert_bytes_equal


def _assert_invalid_state(error_kind: NetErrorKind) raises:
    assert_equal(error_kind, NetErrorKind.invalid_state())


def test_unconnected_ipv4_preserves_payload_and_source() raises:
    var receiver = listen_udp("127.0.0.1:0")
    var sender = listen_udp("127.0.0.1:0")
    var payload: Array[Byte, 4] = [10, 20, 30, 40]
    assert_equal(
        sender.send_to(
            Span(payload), receiver.local_address(), Timeout.seconds(1)
        ),
        4,
    )

    var received = Array[Byte, 4](fill=0)
    var result = receiver.recv_from(Span(received), Timeout.seconds(1))
    assert_equal(result.count, 4)
    assert_equal(result.source, sender.local_address())
    assert_false(result.truncated)
    _assert_bytes_equal(Span(received), Span(payload))


def test_empty_datagram_is_success() raises:
    var receiver = listen_udp("127.0.0.1:0")
    var sender = listen_udp("127.0.0.1:0")
    var empty = Array[Byte, 0](fill=0)
    assert_equal(sender.send_to(Span(empty), receiver.local_address()), 0)

    var received = Array[Byte, 1](fill=99)
    var result = receiver.recv_from(Span(received), Timeout.seconds(1))
    assert_equal(result.count, 0)
    assert_false(result.truncated)
    assert_equal(result.source, sender.local_address())
    assert_equal(received[0], Byte(99))


def test_oversized_datagram_reports_truncation() raises:
    var receiver = listen_udp("127.0.0.1:0")
    var sender = listen_udp("127.0.0.1:0")
    var payload = Array[Byte, 32](fill=0)
    for i in range(len(payload)):
        payload[i] = Byte(i)
    assert_equal(sender.send_to(Span(payload), receiver.local_address()), 32)

    var received = Array[Byte, 8](fill=0)
    var result = receiver.recv_from(Span(received), Timeout.seconds(1))
    assert_equal(result.count, 8)
    assert_true(result.truncated)
    for i in range(len(received)):
        assert_equal(received[i], Byte(i))


def test_connected_ipv4_read_and_write() raises:
    var server = listen_udp("127.0.0.1:0")
    var client = dial_udp(String(server.local_address()), Timeout.seconds(1))
    var request: Array[Byte, 3] = [7, 8, 9]
    assert_equal(client.write(Span(request), Timeout.seconds(1)), 3)

    var received_request = Array[Byte, 3](fill=0)
    var request_result = server.recv_from(
        Span(received_request), Timeout.seconds(1)
    )
    assert_equal(request_result.count, 3)
    _assert_bytes_equal(Span(received_request), Span(request))

    var response: Array[Byte, 2] = [42, 43]
    assert_equal(
        server.send_to(
            Span(response), request_result.source, Timeout.seconds(1)
        ),
        2,
    )
    var received_response = Array[Byte, 2](fill=0)
    assert_equal(client.read(Span(received_response), Timeout.seconds(1)), 2)
    _assert_bytes_equal(Span(received_response), Span(response))
    assert_equal(client.remote_address(), server.local_address())


def test_mode_mismatches_are_rejected() raises:
    var unconnected = listen_udp("127.0.0.1:0")
    var connected = dial_udp(
        String(unconnected.local_address()), Timeout.seconds(1)
    )
    var destination = unconnected.local_address()
    unconnected.close()
    connected.close()
    var payload: Array[Byte, 1] = [1]
    var buffer = Array[Byte, 1](fill=0)

    try:
        _ = unconnected.write(Span(payload))
    except error:
        _assert_invalid_state(error.kind)
    else:
        raise Error("unconnected write unexpectedly succeeded")

    try:
        _ = unconnected.read(Span(buffer))
    except error:
        _assert_invalid_state(error.kind)
    else:
        raise Error("unconnected read unexpectedly succeeded")

    try:
        _ = connected.send_to(Span(payload), destination)
    except error:
        _assert_invalid_state(error.kind)
    else:
        raise Error("connected send_to unexpectedly succeeded")

    try:
        _ = connected.recv_from(Span(buffer))
    except error:
        _assert_invalid_state(error.kind)
    else:
        raise Error("connected recv_from unexpectedly succeeded")


def test_recv_from_timeout_is_an_error() raises:
    var receiver = listen_udp("127.0.0.1:0")
    var buffer = Array[Byte, 1](fill=0)
    try:
        _ = receiver.recv_from(Span(buffer), Timeout.milliseconds(5))
    except error:
        assert_equal(error.kind, NetErrorKind.timeout())
        return
    raise Error("recv_from unexpectedly succeeded")


def test_closed_udp_rejects_io() raises:
    var socket = listen_udp("127.0.0.1:0")
    socket.close()
    var buffer = Array[Byte, 1](fill=0)
    try:
        _ = socket.recv_from(Span(buffer))
    except error:
        assert_equal(error.kind, NetErrorKind.closed())
        return
    raise Error("closed UDP socket accepted I/O")


def test_dial_rejects_port_zero() raises:
    try:
        _ = dial_udp("127.0.0.1:0")
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
        return
    raise Error("dial_udp accepted port zero")


def test_zero_timeout_allows_immediate_udp_connect() raises:
    var server = listen_udp("127.0.0.1:0")
    var server_address = server.local_address()
    var client = dial_udp(String(server_address), Timeout.nanoseconds(0))
    assert_equal(client.remote_address(), server_address)
    assert_true(server.local_address().port != 0)


def test_ipv6_loopback_when_available() raises:
    var v6only: Int
    var sent_count: Int
    var received_count: Int
    var was_truncated: Bool
    var source_matches: Bool
    var first_byte: Byte
    var second_byte: Byte
    try:
        var receiver = listen_udp("[::1]:0")
        v6only = Int(
            _get_socket_option_int(
                receiver._fd.raw(), IPPROTO_IPV6, IPV6_V6ONLY
            )
        )
        var sender = listen_udp("[::1]:0")
        var payload: Array[Byte, 2] = [81, 82]
        sent_count = sender.send_to(Span(payload), receiver.local_address())
        var received = Array[Byte, 2](fill=0)
        var result = receiver.recv_from(Span(received), Timeout.seconds(1))
        received_count = result.count
        was_truncated = result.truncated
        source_matches = result.source == sender.local_address()
        first_byte = received[0]
        second_byte = received[1]
    except error:
        if error.kind == NetErrorKind.unsupported():
            return
        raise error^
    assert_equal(v6only, 1)
    assert_equal(sent_count, 2)
    assert_equal(received_count, 2)
    assert_false(was_truncated)
    assert_true(source_matches)
    assert_equal(first_byte, Byte(81))
    assert_equal(second_byte, Byte(82))


def test_wildcard_listen_receives_ipv4() raises:
    from net.address import SocketAddress

    var receiver = listen_udp(":0")
    var bound = receiver.local_address()
    if bound.ip.is_ipv6():
        var v6only = Int(
            _get_socket_option_int(
                receiver._fd.raw(), IPPROTO_IPV6, IPV6_V6ONLY
            )
        )
        assert_equal(v6only, 0)
    var port = bound.port
    var destination = SocketAddress.parse(String(t"127.0.0.1:{port}"))
    var sender = listen_udp("127.0.0.1:0")
    var payload: Array[Byte, 2] = [11, 22]
    assert_equal(
        sender.send_to(Span(payload), destination, Timeout.seconds(1)), 2
    )
    var received = Array[Byte, 2](fill=0)
    var result = receiver.recv_from(Span(received), Timeout.seconds(1))
    assert_equal(result.count, 2)
    assert_false(result.truncated)
    assert_equal(received[0], Byte(11))
    assert_equal(received[1], Byte(22))


def test_connected_udp_surfaces_icmp_refusal() raises:
    var refused_holder = listen_udp("127.0.0.1:0")
    var refused = String(refused_holder.local_address())
    refused_holder.close()
    var client = dial_udp(refused, Timeout.seconds(1))
    var probe: Array[Byte, 1] = [1]
    try:
        _ = client.write(Span(probe), Timeout.seconds(1))
    except error:
        # The refusal may already surface on the send path.
        assert_true(error.has_errno(ECONNREFUSED))
        client.close()
        return
    var buffer = Array[Byte, 1](fill=0)
    try:
        _ = client.read(Span(buffer), Timeout.seconds(1))
    except error:
        assert_true(error.has_errno(ECONNREFUSED))
        client.close()
        return
    raise Error("expected ECONNREFUSED from refused UDP peer")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
