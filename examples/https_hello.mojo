from std.os import getenv

from net import listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(200)
        writer.write_string("hello over https")


def _bind_address() -> String:
    var env = getenv("HELLO_ADDRESS")
    if env.byte_length() == 0:
        return String("127.0.0.1:8443")
    return env^


def main() raises:
    var server = Server(ServerConfig.default())
    var listener = listen_tcp(_bind_address())
    print(String("READY ") + String(listener.local_address().port))
    var tls_context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )
    var handler = HelloHandler()
    server.serve_tls(
        listener^,
        tls_context^,
        handler,
    )
