from std.testing import assert_equal
from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _ContractHandler(Handler):
    var requests: Int
    var shutdown: Bool

    def __init__(out self):
        self.requests = 0
        self.shutdown = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        if req.path == "/shutdown":
            self.shutdown = True
            writer.set_status(200)
            writer.set_should_close(True)
            writer.write_string("bye")
            return
        if req.path == "/echo":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.headers.add(String("X-Method"), req.method.copy())
            writer.headers.add(String("X-Path"), req.path.copy())
            writer.headers.add(String("X-Query"), req.query.copy())
            writer.write(Span(req.body))
            return
        if req.path == "/head":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string("hello head")
            return
        if req.path == "/no-content":
            writer.set_status(204)
            return
        if req.path == "/not-modified":
            writer.set_status(304)
            return
        if req.path == "/dup":
            writer.set_status(200)
            writer.headers.add(String("X-Dup"), String("one"))
            writer.headers.add(String("X-Dup"), String("two"))
            writer.write_string("ok")
            return
        if req.path == "/req-trailers":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            var seen = req.trailers.get_first("x-trailer-in")
            if seen:
                writer.write_string(String("trailer=") + seen.value())
            else:
                writer.write_string(String("trailer=missing"))
            return
        if req.path == "/resp-trailers":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string("with-trailers")
            writer.add_trailer(String("X-Trailer-Out"), String("ok"))
            return
        if req.path == "/boom":
            raise Error("intentional contract failure")
        if req.path == "/strip":
            writer.set_status(200)
            writer.headers.add(String("Connection"), String("close"))
            writer.headers.add(String("Keep-Alive"), String("timeout=5"))
            writer.write_string("stripped?")
            return
        if req.path == "/sibling":
            writer.set_status(200)
            writer.write_string("sibling ok")
            return
        writer.set_status(404)
        writer.write_string("missing")


def main() raises:
    var config = ServerConfig.default()
    config.max_body_bytes = 256
    var server = Server(config^)
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
    var handler = _ContractHandler()
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    while server.tick(handler, Timeout.seconds(2)):
        pass
    assert_equal(server.active_connections(), 0)
