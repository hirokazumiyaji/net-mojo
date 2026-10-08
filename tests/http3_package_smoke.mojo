from net import Timeout
from net.http import (
    Handler,
    HttpVersion,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp


struct _OneRequestHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.version != HttpVersion.http3():
            raise Error("packaged HTTP/3 handler received wrong version")
        self.requests += 1
        writer.set_status(200)
        writer.headers.add(String("Content-Type"), String("text/plain"))
        writer.write_string("packaged http/3 ok")


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    if provider.version() != "0.29.3":
        raise Error("packaged HTTP/3 provider version mismatch")
    var listener = listen_udp("127.0.0.1:0")
    var address = String(listener.local_address())
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server_config = ServerConfig.default()
    server_config.shutdown_grace = Timeout.milliseconds(500)
    var server = Server(server_config^)
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(quic_config^), listener^)
    )
    print("READY " + address)
    var handler = _OneRequestHandler()
    while handler.requests < 1:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    var running = True
    while running:
        running = server.tick(handler, Timeout.seconds(2))
