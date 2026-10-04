from std.testing import assert_equal, assert_true
from net.http._connection import PROTOCOL_HTTP2
from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _OneRequestHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        writer.set_status(200)
        writer.headers.add(String("X-Request-Scheme"), req.scheme.copy())
        writer.set_should_close(True)
        writer.write_string("hello over https")
        writer.write(Span(req.body))


def main() raises:
    var server = Server(ServerConfig.default())
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2,http/1.1",
        ),
    )
    print(String("READY ") + String(server.local_address().port))
    var handler = _OneRequestHandler()
    var h2_checked = False
    while handler.requests < 6:
        _ = server.tick(handler, Timeout.seconds(2))
        for idx in range(len(server._conns)):
            if (
                server._conns[idx].active
                and server._conns[idx].protocol == PROTOCOL_HTTP2
            ):
                assert_equal(server._conns[idx]._error_wire.capacity(), 0)
                assert_equal(server._conns[idx]._error_ticket.amount, 0)
                h2_checked = True
    assert_true(h2_checked)
    while server.active_connections() > 0:
        _ = server.tick(handler, Timeout.seconds(2))
