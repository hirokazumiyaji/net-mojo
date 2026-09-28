from net import listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext
from net.udp import listen_udp


struct HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(200)
        writer.headers.add("Content-Type", "text/plain")
        writer.write_string("hello over http/3")


def main() raises:
    var udp = listen_udp("127.0.0.1:8443")
    var tcp = listen_tcp("127.0.0.1:8443")
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var endpoint = QuicUDPEndpoint(provider.server(quic_config^), udp^)
    var tls_context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "h2,http/1.1",
    )
    var server = Server(ServerConfig.default())
    server.add_quic_endpoint(endpoint^)
    var handler = HelloHandler()
    server.serve_tls(tcp^, tls_context^, handler)
