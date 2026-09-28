from net.http import Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var udp = listen_udp("127.0.0.1:0")
    var endpoint = QuicUDPEndpoint(provider.server(config^), udp^)
    var server = Server(ServerConfig.default())
    server.add_quic_endpoint(endpoint^)
    if provider.version() != "0.29.3":
        raise Error("packaged HTTP/3 provider version mismatch")
    print("packaged HTTP/3 provider succeeded")
