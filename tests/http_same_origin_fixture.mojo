from std.os import getenv
from std.testing import assert_true

from net import Timeout, listen_tcp, listen_udp
from net.http import (
    Handler,
    HttpVersion,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext


struct _SameOriginHandler(Handler):
    var authority: String
    var http1_requests: Int
    var http3_requests: Int
    var stopping: Bool

    def __init__(out self, var authority: String):
        self.authority = authority^
        self.http1_requests = 0
        self.http3_requests = 0
        self.stopping = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        assert_true(req.method == "GET")
        assert_true(req.scheme == "https")
        assert_true(req.authority == self.authority)
        assert_true(req.path == "/hello" or req.path == "/shutdown")
        if req.version == HttpVersion.http11():
            self.http1_requests += 1
        else:
            assert_true(req.version == HttpVersion.http3())
            self.http3_requests += 1
        writer.headers.add("Content-Type", "text/plain")
        writer.write_string("same-origin:" + req.path)
        if req.path == "/shutdown":
            self.stopping = True


def main() raises:
    var dual = getenv("NET_SAME_ORIGIN_MODE") == "dual"
    var listener = listen_tcp("127.0.0.1:0")
    var address = listener.local_address()
    var config = ServerConfig.default()
    config.shutdown_grace = Timeout.milliseconds(500)
    if dual:
        config.alt_svc = 'h3=":' + String(address.port) + '"; ma=60'
    var server = Server(config^)
    if dual:
        var provider = QuicProvider("build/quic/libnet_quic_provider")
        var quic_config = provider.server_config(
            "build/tls/test-cert.pem", "build/tls/test-key.pem"
        )
        server.add_quic_endpoint(
            QuicUDPEndpoint(
                provider.server(quic_config^), listen_udp(String(address))
            )
        )
    server.add_tls_listener(
        listener^,
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2,http/1.1",
        ),
    )
    print("READY " + String(address.port))
    var handler = _SameOriginHandler("localhost:" + String(address.port))
    while not handler.stopping:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    while server.tick(handler, Timeout.seconds(2)):
        pass
    assert_true(handler.http1_requests == 2)
    assert_true(handler.http3_requests == Int(dual))
    print("DRAINED " + String(handler.http1_requests + handler.http3_requests))
