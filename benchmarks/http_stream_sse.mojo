"""Detached HTTP/2 and HTTP/3 SSE producer for the measurement driver."""

from std.ffi import external_call
from std.sys import CompilationTarget

from net import Timeout, listen_tcp, listen_udp
from net.http import (
    Handler,
    Headers,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext


def _clock_ns() raises -> Int:
    comptime clock = 6 if CompilationTarget.is_macos() else 1
    var value = Array[Int64, 2](fill=0)
    if (
        external_call["clock_gettime", Int32](Int32(clock), Pointer(to=value))
        != 0
    ):
        raise Error("benchmark monotonic clock failed")
    return Int(value[0]) * 1_000_000_000 + Int(value[1])


@fieldwise_init
struct _Stream(Movable):
    var sender: ResponseSender
    var started: Int
    var sequence: Int


struct _Handler(Handler):
    var streams: List[_Stream]
    var shutdown: Bool

    def __init__(out self):
        self.streams = List[_Stream]()
        self.shutdown = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/shutdown":
            self.shutdown = True
            writer.write_string("stopping")
            return
        if req.path == "/clock":
            var value = String(_clock_ns())
            writer.write_string(value)
            return
        if req.path != "/events":
            writer.set_status(404)
            return
        var sender = writer.detach()
        var headers = Headers()
        headers.add("content-type", "text/event-stream")
        headers.add("cache-control", "no-cache")
        sender.start(200, headers^)
        self.streams.append(_Stream(sender^, _clock_ns(), 0))

    def advance(mut self) raises:
        var now = _clock_ns()
        var index = 0
        while index < len(self.streams):
            if self.streams[index].sender.is_cancelled():
                raise Error("SSE benchmark response was cancelled")
            while self.streams[index].sequence < 1000:
                var sequence = self.streams[index].sequence
                var planned = self.streams[index].started + sequence * 1_000_000
                if planned > now:
                    break
                var event = (
                    String("data: ")
                    + String(sequence)
                    + " "
                    + String(planned)
                    + "\n\n"
                )
                if not self.streams[index].sender.send(event.as_bytes()):
                    break
                self.streams[index].sequence += 1
            if self.streams[index].sequence == 1000:
                self.streams[index].sender.finish()
                _ = self.streams.pop(index)
            else:
                index += 1


def main() raises:
    var config = ServerConfig.default()
    config.max_http2_streams_per_connection = 128
    config.stream_queue_limit = 65536
    config.detached_response_timeout = Timeout.seconds(30)
    config.shutdown_grace = Timeout.milliseconds(500)
    config.max_bytes_per_tick = 65536
    var server = Server(config^)
    var tcp = listen_tcp("127.0.0.1:0")
    var tcp_address = String(tcp.local_address())
    var tls = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "h2",
    )
    server.add_tls_listener(tcp^, tls^)
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var udp = listen_udp("127.0.0.1:0")
    var udp_address = String(udp.local_address())
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(quic_config^), udp^)
    )
    print("READY " + tcp_address + " " + udp_address)
    _ = external_call["fflush", Int32](
        Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    var handler = _Handler()
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.milliseconds(1))
        handler.advance()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
