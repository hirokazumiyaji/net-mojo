from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _AltSvcHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        writer.set_status(200)
        writer.set_should_close(True)
        if req.path == "/custom":
            writer.headers.add(String("Alt-Svc"), String('h3=":9443"; ma=60'))
        writer.write_string("alt-svc ok")


def main() raises:
    var config = ServerConfig.default()
    config.alt_svc = String('h3=":8443"; ma=86400')
    var server = Server(config^)
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "http/1.1",
        ),
    )
    print(String("READY ") + String(server.local_address().port))
    var handler = _AltSvcHandler()
    while handler.requests < 2:
        _ = server.tick(handler, Timeout.seconds(2))
    while server.active_connections() > 0:
        _ = server.tick(handler, Timeout.seconds(2))
