from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _ShutdownHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        writer.set_status(200)
        writer.write_string("drained")


def main() raises:
    var server = Server(ServerConfig.default())
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
    var handler = _ShutdownHandler()
    while handler.requests == 0:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    while server.tick(handler, Timeout.seconds(2)):
        pass
