from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.http._http2.hpack import Http2HpackInflater
from net.tls import TLSContext


struct _OneRequestHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        writer.set_status(200)
        writer.headers.add(String("Content-Type"), String("text/plain"))
        writer.set_should_close(True)
        writer.write_string("packaged http/2 ok")


def _check_hpack_provider() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var block: List[Byte] = [Byte(0x82), Byte(0x86), Byte(0x84)]
    var output = Array[Byte, 128](fill=0)
    var result = inflater.decode(Span(block), 1024, 8, Span(output))
    if not result.is_success() or result.field_count != 3:
        raise Error("packaged HTTP/2 HPACK provider failed")


def main() raises:
    var config = ServerConfig.default()
    if config.max_http2_streams_per_connection <= 0:
        raise Error("packaged HTTP/2 server configuration failed")
    _check_hpack_provider()
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
    var handler = _OneRequestHandler()
    while handler.requests < 1:
        _ = server.tick(handler, Timeout.seconds(2))
    while server.active_connections() > 0:
        _ = server.tick(handler, Timeout.seconds(2))
