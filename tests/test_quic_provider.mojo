from net._reactor import Reactor
from net.quic import QuicProvider, QuicUDPEndpoint
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.timeout import Timeout
from net.udp import dial_udp, listen_udp


struct _NoopHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        pass


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
    print("QUIC provider Mojo FFI: ok")
