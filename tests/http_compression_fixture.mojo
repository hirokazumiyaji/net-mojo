from std.ffi import external_call
from net import Timeout, listen_tcp, listen_udp
from net.http import (
    CompressionConfig,
    CompressionHandler,
    CompressingSender,
    Headers,
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext


@fieldwise_init
struct _StreamingResponse(Movable):
    var sender: CompressingSender
    var remaining: Int
    var wants_trailers: Bool
    var finish_started: Bool
    var random: Bool
    var random_state: UInt64


struct _Handler(Handler):
    var shutdown: Bool
    var streams: List[_StreamingResponse]

    def __init__(out self):
        self.shutdown = False
        self.streams = List[_StreamingResponse]()

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/shutdown":
            self.shutdown = True
            writer.write_string("stopping")
            return
        if req.path.startswith("/stream"):
            var cfg = CompressionConfig.default()
            cfg.buffer_size = 32
            var path: Optional[String] = Optional[String](
                "build/compression/libnet_zlib"
            )
            if req.path == "/stream-disabled":
                path = None
            var sender = writer.detach_compressed(req, cfg^, path^)
            var headers = Headers()
            headers.add("Content-Type", "text/plain")
            headers.add("Vary", "Origin")
            headers.add("ETag", '"source"')
            var total = (
                4 if req.path == "/stream-tiny"
                or req.path == "/stream-known-small" else 4096
            )
            if req.path.startswith("/stream-known") or req.method == "HEAD":
                headers.add("Content-Length", String(total))
            if req.method == "HEAD":
                total = 0
            sender.start(200, headers^)
            self.streams.append(
                _StreamingResponse(
                    sender^,
                    total,
                    req.path.endswith("trailers"),
                    False,
                    req.path == "/stream-random",
                    UInt64(123456789),
                )
            )
            return
        writer.headers.add("Content-Type", "text/plain")
        writer.headers.add("Vary", "Origin")
        if req.path == "/head":
            writer.headers.add("Content-Length", "4096")
            return
        if req.path == "/empty":
            writer.set_status(204)
            return
        if req.path == "/partial":
            writer.set_status(206)
        if req.path == "/mime":
            writer.headers.clear()
            writer.headers.add("Content-Type", "image/png")
        if req.path == "/encoded":
            writer.headers.add("Content-Encoding", "br")
        if req.path == "/expansion":
            var data = List[Byte](length=8192, fill=0)
            var state = UInt64(123456789)
            for i in range(len(data)):
                state = state * UInt64(6364136223846793005) + 1
                data[i] = Byte(state >> 56)
            writer.write(Span(data))
            return
        var size = 4 if req.path == "/small" else 4096
        var body = List[Byte](length=size, fill=Byte(65))
        writer.write(Span(body))
        if req.path == "/length":
            writer.headers.add("Content-Length", String(size))
        if req.path == "/trailers":
            writer.add_trailer("x-digest", "ok")

    def advance(mut self) raises:
        var index = 0
        while index < len(self.streams):
            if self.streams[index].sender.is_cancelled():
                _ = self.streams.pop(index)
                continue
            while self.streams[index].remaining > 0:
                var count = min(8, self.streams[index].remaining)
                var bytes = List[Byte](length=count, fill=Byte(65))
                var candidate = self.streams[index].random_state
                if self.streams[index].random:
                    for i in range(count):
                        candidate = candidate * UInt64(6364136223846793005) + 1
                        bytes[i] = Byte(candidate >> 56)
                if not self.streams[index].sender.send(Span(bytes)):
                    break
                self.streams[index].random_state = candidate
                self.streams[index].remaining -= count
            if self.streams[index].remaining > 0:
                index += 1
                continue
            var trailers = Headers()
            if (
                not self.streams[index].finish_started
                and self.streams[index].wants_trailers
            ):
                trailers.add("x-digest", "ok")
            self.streams[index].finish_started = True
            if self.streams[index].sender.finish(trailers^):
                _ = self.streams.pop(index)
            else:
                index += 1


def main() raises:
    var config = ServerConfig.default()
    config.max_response_body = 8192
    config.stream_queue_limit = 8
    config.shutdown_grace = Timeout.milliseconds(500)
    var server = Server(config^)
    var tcp = listen_tcp("127.0.0.1:0")
    var tcp_address = String(tcp.local_address())
    server.add_tls_listener(
        tcp^,
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2,http/1.1",
        ),
    )
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var udp = listen_udp("127.0.0.1:0")
    var udp_address = String(udp.local_address())
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(quic_config^), udp^)
    )
    var handler = CompressionHandler[_Handler](
        _Handler(),
        CompressionConfig.default(),
        Optional[String]("build/compression/libnet_zlib"),
    )
    print("READY " + tcp_address + " " + udp_address)
    _ = external_call["fflush", Int32](
        Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    while not handler.inner.shutdown:
        _ = server.tick(handler, Timeout.milliseconds(10))
        handler.inner.advance()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
