from std.testing import assert_equal
from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _IntegrationHandler(Handler):
    var shutdown: Bool

    def __init__(out self):
        self.shutdown = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/shutdown":
            self.shutdown = True
            writer.set_status(200)
            writer.set_should_close(True)
            writer.write_string("bye")
            return
        if req.path == "/trigger-shutdown":
            self.shutdown = True
            writer.set_status(200)
            writer.write_string("shutdown requested")
            return
        if req.path == "/echo":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write(Span(req.body))
            return
        if req.path == "/large":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/octet-stream")
            )
            var size = 128 * 1024
            var buf = List[Byte](capacity=size)
            for i in range(size):
                buf.append(Byte(97 + (i % 26)))
            writer.write(Span(buf))
            return
        if req.path == "/sibling":
            writer.set_status(200)
            writer.write_string("sibling ok")
            return
        writer.set_status(404)
        writer.write_string("missing")


def main() raises:
    var config = ServerConfig.default()
    config.max_body_bytes = 2 * 1024 * 1024
    var server = Server(config^)
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2",
        ),
    )
    print(String("READY ") + String(server.local_address().port))
    var handler = _IntegrationHandler()
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    while server.tick(handler, Timeout.seconds(2)):
        pass
    assert_equal(server.active_connections(), 0)
