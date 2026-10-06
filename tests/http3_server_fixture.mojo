from std.testing import assert_true

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
from std.os import getenv


struct _Http3Handler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        assert_true(req.version == HttpVersion.http3())
        assert_true(req.authority == "localhost")
        assert_true(req.scheme == "https")
        if req.path == "/cancel-response":
            assert_true(req.method == "GET")
            assert_true(len(req.body) == 0)
            var body = List[Byte](length=2_000_000, fill=Byte(42))
            writer.write(Span(body))
            self.requests += 1
            return
        assert_true(req.method == "POST")
        assert_true(req.path == "/echo")
        assert_true(req.query == "source=quic")
        assert_true(len(req.body) == 4)
        writer.write_string("handled:")
        writer.write(Span(req.body))
        if len(req.trailers) > 0:
            assert_true(
                req.trailers.get_first("x-check") == Optional[String]("done")
            )
            writer.write_string(":done")
        self.requests += 1


def _expected_requests() -> Int:
    # Drivers use different completion totals, so each sets its own count.
    var raw = getenv("HTTP3_FIXTURE_EXPECT")
    var count = 0
    var digits = 0
    var buf = raw.as_bytes()
    for i in range(len(buf)):
        var b = Int(buf[i])
        if b < ord("0") or b > ord("9"):
            break
        count = count * 10 + (b - ord("0"))
        digits += 1
    if digits == 0:
        return 5
    return count


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var listener = listen_udp("127.0.0.1:0")
    var address = String(listener.local_address())
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server_config = ServerConfig.default()
    server_config.shutdown_grace = Timeout.milliseconds(500)
    server_config.max_response_body = 2_000_000
    var server = Server(server_config^)
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(config^), listener^)
    )
    var handler = _Http3Handler()
    print("READY " + address)
    # A completed request counts even when its response is later cancelled.
    var expected = _expected_requests()
    while handler.requests < expected:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    var running = True
    while running:
        running = server.tick(handler, Timeout.seconds(2))
