from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _FloodHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        writer.set_status(200)
        writer.write_string("flood-ok")
        writer.write(Span(req.body))


def main() raises:
    # Low reset budget so RST-storm regression completes in one tumbling window.
    var config = ServerConfig.default()
    config.http2_max_new_streams_per_second = 2
    config.http2_max_resets_per_second = 2
    config.http2_max_control_frames_per_second = 1000
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
    var handler = _FloodHandler()
    # Wait for the first client so we do not exit before peers connect.
    while server.active_connections() == 0:
        _ = server.tick(handler, Timeout.seconds(2))
    # Conn A may complete one request before the storm; Conn B must still
    # succeed. Keep ticking while any connection is alive so the sibling
    # response can flush after GOAWAY drains Conn A (Linux CI previously
    # hit BrokenPipe when the server stopped accepting work too early).
    while handler.requests < 2 or server.active_connections() > 0:
        _ = server.tick(handler, Timeout.milliseconds(100))
