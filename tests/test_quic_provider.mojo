from net._reactor import Reactor
from net._sys.common import (
    SOL_SOCKET,
    SO_SNDBUF,
    _set_socket_option_int,
)
from net.address import SocketAddress
from net.error import NetErrorKind
from net.quic import QuicProvider, QuicUDPEndpoint
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.timeout import Timeout
from net.udp import UDPConn, dial_udp, listen_udp


struct _NoopHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        pass


def _shrink_send_buffer(mut socket: UDPConn) raises:
    # Small enough that a few large datagrams toward TEST-NET fill the
    # local UDP send queue on both Darwin and Linux runners.
    _set_socket_option_int(
        socket.raw_fd(),
        SOL_SOCKET,
        SO_SNDBUF,
        2048,
        "setsockopt(SO_SNDBUF)",
    )


def _fill_udp_send_queue(mut socket: UDPConn) raises -> Bool:
    """Push datagrams toward TEST-NET until `try_send_to` would-block."""
    var filler = Array[Byte, 1400](fill=0xAB)
    var blackhole = SocketAddress.parse("192.0.2.1:9")
    for _ in range(10_000):
        try:
            _ = socket.try_send_to(Span(filler), blackhole)
        except error:
            if error.kind == NetErrorKind.timeout():
                return True
            raise error^
    return False


def _stage_pending_payload(
    mut endpoint: QuicUDPEndpoint, destination: SocketAddress
) raises:
    var payload = Array[Byte, 16](fill=0)
    for i in range(len(payload)):
        payload[i] = Byte(0x40 + i)
    endpoint.stage_outgoing_datagram(Span(payload), destination)


def test_udp_send_backpressure_preserves_pending_datagram() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    var listener = listen_udp("0.0.0.0:0")
    _shrink_send_buffer(listener)
    var endpoint = QuicUDPEndpoint(server^, listener^)
    var receiver = listen_udp("127.0.0.1:0")
    var destination = receiver.local_address()

    var blocked = False
    for _ in range(64):
        _stage_pending_payload(endpoint, destination)
        assert endpoint.wants_write()
        if not _fill_udp_send_queue(endpoint._socket):
            raise Error("UDP send queue did not saturate toward TEST-NET")
        # Would-block must keep the staged datagram; a drop-without-retry
        # would clear write interest before the bytes leave.
        if not endpoint.try_send():
            assert endpoint.wants_write()
            assert not endpoint.try_send()
            assert endpoint.wants_write()
            blocked = True
            break
        # A rare race where the queue drained between fill and try_send:
        # consume the accidental delivery and retry saturation.
        var scratch = Array[Byte, 64](fill=0)
        try:
            _ = receiver.try_recv_from(Span[mut=True](scratch))
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
    assert blocked

    var reactor = Reactor()
    var token = reactor.register(
        endpoint.raw_fd(), readable=False, writable=True
    )
    var delivered = False
    for _ in range(200):
        var events = reactor.wait(Timeout.milliseconds(50))
        var writable = False
        for event in events:
            if event.token == token and event.writable:
                writable = True
                break
        if not writable:
            continue
        if endpoint.try_send():
            delivered = True
            break
        assert endpoint.wants_write()
    assert delivered
    assert not endpoint.wants_write()

    var received = Array[Byte, 16](fill=0)
    var result = receiver.recv_from(
        Span[mut=True](received), Timeout.seconds(1)
    )
    assert result.count == 16
    for i in range(16):
        assert received[i] == Byte(0x40 + i)


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    assert provider.version() == "0.29.3"
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    assert server.timeout_micros() == UInt64.MAX
    var packet = Array[Byte, 256](fill=0)
    _ = server.try_send_datagram(Span[mut=True](packet))
    server.on_timeout()

    var listener = listen_udp("127.0.0.1:0")
    var client_address = String(listener.local_address())
    var endpoint = QuicUDPEndpoint(server^, listener^)
    var reactor = Reactor()
    var token = reactor.register(endpoint.raw_fd())
    var client = dial_udp(client_address)
    var invalid_datagram = Array[Byte, 1](fill=Byte(0))
    _ = client.write(Span(invalid_datagram), Timeout.seconds(1))
    var events = reactor.wait(Timeout.seconds(1))
    assert len(events) == 1
    assert events[0].token == token
    assert not endpoint.try_receive()
    assert not endpoint.try_send()
    assert not endpoint.wants_write()

    var http_server = Server(ServerConfig.default())
    var server_listener = listen_udp("127.0.0.1:0")
    var server_address = String(server_listener.local_address())
    var config2 = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var protocol_server = provider.server(config2^)
    http_server.add_quic_endpoint(
        QuicUDPEndpoint(protocol_server^, server_listener^)
    )
    var udp_client = dial_udp(server_address)
    _ = udp_client.write(Span(invalid_datagram), Timeout.seconds(1))
    var handler = _NoopHandler()
    assert http_server.tick(handler, Timeout.seconds(1))
    http_server.request_shutdown()
    assert not http_server.tick(handler, Timeout.nanoseconds(0))

    test_udp_send_backpressure_preserves_pending_datagram()
    print("QUIC provider Mojo FFI: ok")
