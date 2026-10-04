from std.testing import assert_true, assert_false

from net._reactor import Reactor
from net.address import SocketAddress
from net.quic import QuicProvider, QuicUDPEndpoint
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.timeout import Timeout
from net.udp import dial_udp, listen_udp


struct _NoopHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        pass


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
    var endpoint = QuicUDPEndpoint(server^, listener^)
    var receiver = listen_udp("127.0.0.1:0")
    var destination = receiver.local_address()

    # Deterministic would-block via fault injection (no kernel queue
    # timing or TEST-NET routing dependency).
    _stage_pending_payload(endpoint, destination)
    assert_true(endpoint.wants_write())
    endpoint.inject_send_would_block_once()
    assert_false(endpoint.try_send())
    assert_true(endpoint.wants_write())
    # Immediate retry may succeed once the kernel drains; tolerate both
    # (still-pending with write interest, or delivered without it).
    if endpoint.try_send():
        assert_false(endpoint.wants_write())
    else:
        assert_true(endpoint.wants_write())
        # Wait for real writability and deliver the preserved datagram.
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
            assert_true(endpoint.wants_write())
        assert_true(delivered)
        assert_false(endpoint.wants_write())

    var received = Array[Byte, 16](fill=0)
    var result = receiver.recv_from(
        Span[mut=True](received), Timeout.seconds(1)
    )
    assert_true(result.count == 16)
    for i in range(16):
        assert_true(received[i] == Byte(0x40 + i))


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    assert_true(provider.version() == "0.29.3")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    assert_true(server.timeout_micros() == UInt64.MAX)
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
    assert_true(len(events) == 1)
    assert_true(events[0].token == token)
    assert_false(endpoint.try_receive())
    assert_false(endpoint.try_send())
    assert_false(endpoint.wants_write())

    var http_config = ServerConfig.default()
    http_config.shutdown_grace = Timeout.milliseconds(20)
    var http_server = Server(http_config^)
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
    assert_true(http_server.tick(handler, Timeout.seconds(1)))
    http_server.request_shutdown()
    var running = True
    for _ in range(100):
        running = http_server.tick(handler, Timeout.milliseconds(5))
        if not running:
            break
    assert_false(running)

    test_udp_send_backpressure_preserves_pending_datagram()
    print("QUIC provider Mojo FFI: ok")
