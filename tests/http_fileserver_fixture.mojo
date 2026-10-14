from std.ffi import external_call
from std.sys import argv
from std.testing import assert_equal

from net import Timeout, listen_tcp, listen_udp
from net.http import (
    FileServer,
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    file_server,
)
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext


struct _FixtureHandler(Handler):
    var files: FileServer
    var shutdown: Bool

    def __init__(out self, root: StringSlice) raises:
        self.files = file_server(root)
        self.shutdown = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/shutdown":
            self.shutdown = True
            writer.write_string("bye")
        elif req.path == "/alive":
            writer.write_string("ok")
        else:
            self.files.handle(req, writer)


def main() raises:
    var arguments = argv()
    var mode = arguments[1]
    var config = ServerConfig.default()
    config.max_response_body = 65536
    config.stream_queue_limit = 65536
    config.total_buffer_budget = 8 * 1024 * 1024
    config.detached_response_timeout = Timeout.seconds(120)
    config.write_deadline = Timeout.seconds(120)
    config.shutdown_grace = Timeout.seconds(2)
    config.http2_max_control_frames_per_second = 100000
    var server = Server(config^)
    var port: UInt16
    if mode == "h3":
        var listener = listen_udp("127.0.0.1:0")
        port = listener.local_address().port
        var provider = QuicProvider("build/quic/libnet_quic_provider")
        var quic_config = provider.server_config(
            "build/tls/test-cert.pem", "build/tls/test-key.pem"
        )
        server.add_quic_endpoint(
            QuicUDPEndpoint(provider.server(quic_config^), listener^)
        )
    elif mode == "tls":
        server.add_tls_listener(
            listen_tcp("127.0.0.1:0"),
            TLSContext.server(
                "build/tls/libnet_tls",
                "build/tls/test-cert.pem",
                "build/tls/test-key.pem",
                "h2,http/1.1",
            ),
        )
        port = server.local_address().port
    else:
        server.add_listener(listen_tcp("127.0.0.1:0"))
        port = server.local_address().port
    var handler = _FixtureHandler(arguments[2])
    print("READY " + String(port))
    _ = external_call["fflush", Int32](
        Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.milliseconds(10))
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
    assert_equal(server.active_connections(), 0)
    assert_equal(server._budget.used(), 0)
    print("DRAINED")
