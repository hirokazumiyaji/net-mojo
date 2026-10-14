"""Request body counting fixture for throughput and server RSS measurements."""

from std.ffi import external_call
from std.sys import argv

from net import Timeout, listen_tcp, listen_udp
from net.http import (
    Handler,
    HandlerJob,
    Request,
    RequestBodyReceiver,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
    WorkerPool,
    WorkerPoolConfig,
)
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext


@fieldwise_init
struct _CountBody(HandlerJob):
    var receiver: RequestBodyReceiver

    def run(mut self, mut sender: ResponseSender) raises:
        var total = 0
        var scratch = Array[Byte, 65536](fill=0)
        while True:
            var count = self.receiver.receive(
                Span(scratch), Timeout.seconds(120)
            )
            if count == 0:
                var trailers = self.receiver.trailers()
                var result = trailers.get_first("X-Result")
                if not result or result.value() != "done":
                    raise Error("missing upload completion trailer")
                var body = List[Byte]()
                body.extend(String(total).as_bytes())
                sender.respond(body=body^)
                return
            total += count


@fieldwise_init
struct _Handler(Handler):
    var pool: Pointer[WorkerPool, MutUntrackedOrigin]
    var streaming: Bool
    var shutdown: Bool

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/shutdown":
            self.shutdown = True
            writer.write_string("stopping")
        elif req.path == "/upload":
            if self.streaming:
                var reader = req.body_reader()
                _ = writer.offload(self.pool[], _CountBody(reader.detach()))
            else:
                var result = req.trailers.get_first("X-Result")
                if not result or result.value() != "done":
                    raise Error("missing buffered completion trailer")
                writer.write_string(String(len(req.body)))
        else:
            writer.set_status(404)


def main() raises:
    var arguments = argv()
    var protocol = arguments[1]
    var streaming = arguments[2] == "streaming"
    var pool = WorkerPool(WorkerPoolConfig(workers=1, queue_limit=1))
    var config = ServerConfig.default()
    config.enable_request_body_streaming = streaming
    config.max_body_bytes = 65536 if streaming else Int(arguments[3])
    config.total_buffer_budget = 1024 * 1024 * 1024
    config.quic_receive_request_bytes = 512 * 1024 * 1024
    config.body_deadline = Timeout.seconds(120)
    config.detached_response_timeout = Timeout.seconds(120)
    config.shutdown_grace = Timeout.seconds(2)
    config.http2_max_control_frames_per_second = 100000
    var server = Server(config^)
    var address: String
    if protocol == "h3":
        var provider = QuicProvider("build/quic/libnet_quic_provider")
        var udp = listen_udp("127.0.0.1:0")
        address = String(udp.local_address())
        var native_config = provider.server_config(
            "build/tls/test-cert.pem", "build/tls/test-key.pem"
        )
        server.add_quic_endpoint(
            QuicUDPEndpoint(provider.server(native_config^), udp^)
        )
    else:
        var tcp = listen_tcp("127.0.0.1:0")
        address = String(tcp.local_address())
        if protocol == "h2":
            var tls = TLSContext.server(
                "build/tls/libnet_tls",
                "build/tls/test-cert.pem",
                "build/tls/test-key.pem",
                "h2",
            )
            server.add_tls_listener(tcp^, tls^)
        else:
            server.add_listener(tcp^)
    print("READY " + address)
    _ = external_call["fflush", Int32](
        Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    var handler = _Handler(
        Pointer[WorkerPool, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=pool))
        ),
        streaming,
        False,
    )
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.milliseconds(10))
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
    pool.shutdown()
