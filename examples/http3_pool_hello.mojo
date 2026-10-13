from net import listen_tcp
from net.http import HandlerFactory, ServerConfig, ServerPool
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext
from net.udp import listen_udp
from examples.http3_hello import HelloHandler, _bind_address


struct HelloFactory(HandlerFactory):
    comptime HandlerType = HelloHandler

    def __init__(out self):
        pass

    def build(mut self, worker_id: Int) raises -> HelloHandler:
        return HelloHandler()


def main() raises:
    var udp = listen_udp(_bind_address())
    var port = udp.local_address().port
    var tcp = listen_tcp(String("127.0.0.1:") + String(port))
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var endpoint = QuicUDPEndpoint(provider.server(quic_config^), udp^)
    var tls_context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )
    var config = ServerConfig.default()
    config.alt_svc = String('h3=":') + String(port) + String('"; ma=86400')
    var pool = ServerPool(config^)
    pool.add_quic_endpoint(endpoint^)
    pool.add_tls_listener(tcp^, tls_context^)
    print(String("READY ") + String(port))
    var factory = HelloFactory()
    pool.serve(factory)
