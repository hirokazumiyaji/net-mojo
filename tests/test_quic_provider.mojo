from net._reactor import Reactor
from net.quic import QuicProvider, QuicUDPEndpoint
from net.timeout import Timeout
from net.udp import dial_udp, listen_udp


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
    print("QUIC provider Mojo FFI: ok")
