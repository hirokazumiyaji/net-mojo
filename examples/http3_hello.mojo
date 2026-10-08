from std.os import getenv

from net import listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext
from net.udp import listen_udp


struct HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(200)
        writer.headers.add("Content-Type", "text/plain")
        writer.write_string("hello over http/3")


def _bind_address() -> String:
    var env = getenv("HELLO_ADDRESS")
    if env.byte_length() == 0:
        return String("127.0.0.1:8443")
    return env^


def main() raises:
    var address = _bind_address()
    var udp = listen_udp(address)
    var port = udp.local_address().port
    var tcp = listen_tcp(String("127.0.0.1:") + String(port))
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var endpoint = QuicUDPEndpoint(provider.server(quic_config^), udp^)
    var tls_context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "h2,http/1.1",
    )
    # Opt-in Alt-Svc so HTTPS clients discover the same-origin HTTP/3 UDP port.
    # Leave alt_svc empty when no QUIC endpoint is attached.
    var config = ServerConfig.default()
    config.alt_svc = String('h3=":') + String(port) + String('"; ma=86400')
    var server = Server(config^)
    server.add_quic_endpoint(endpoint^)
    print(String("READY ") + String(port))
    var handler = HelloHandler()
    server.serve_tls(tcp^, tls_context^, handler)
