from net import Timeout
from net.http import Handler, HttpVersion, Request, ResponseWriter, Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp


struct _Http3Handler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        assert req.version == HttpVersion.http3()
        assert req.method == "POST"
        assert req.path == "/echo"
        assert req.query == "source=quic"
        assert req.authority == "localhost"
        assert req.scheme == "https"
        assert len(req.body) == 4
        writer.write_string("handled:")
        writer.write(Span(req.body))
        if len(req.trailers) > 0:
            assert req.trailers.get_first("x-check") == Optional[String]("done")
            writer.write_string(":done")
        self.requests += 1


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var listener = listen_udp("127.0.0.1:0")
    var address = String(listener.local_address())
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server_config = ServerConfig.default()
    server_config.shutdown_grace = Timeout.milliseconds(500)
    var server = Server(server_config^)
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(config^), listener^)
    )
    var handler = _Http3Handler()
    print("READY " + address)
    # Completions expected from scripts/test_http3_server.py:
    # reordered POST, two reset-storm siblings, trailers POST, final POST.
    # Cancelled / reset streams do not increment this counter.
    while handler.requests < 5:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    var running = True
    while running:
        running = server.tick(handler, Timeout.seconds(2))
