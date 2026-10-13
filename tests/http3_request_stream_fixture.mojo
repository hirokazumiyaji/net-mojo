from std.testing import assert_equal
from std.ffi import external_call
from net import Timeout
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    Request,
    RequestBodyEndpoints,
    RequestBodyReceiver,
    ResponseWriter,
    Server,
    ServerConfig,
)


struct _StreamingHandler(Handler):
    var endpoints: Optional[RequestBodyEndpoints]
    var input_count: Int
    var calls: Int
    var cancelled: Int
    var count: Int
    var shutdown: Bool
    var paused: Bool
    var early: Bool
    var done: Int
    var standalone: Optional[RequestBodyReceiver]

    def __init__(out self):
        self.endpoints = None
        self.input_count = 0
        self.calls = 0
        self.cancelled = 0
        self.count = 0
        self.shutdown = False
        self.paused = False
        self.early = False
        self.done = 0
        self.standalone = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        writer.should_close = True
        if request.path == "/inputs":
            writer.write_string(String(self.input_count))
        elif request.path == "/detached-only":
            var sender = writer.detach()
            var body = List[Byte]("detached".as_bytes())
            sender.respond(200, Headers(), body^)
        elif request.path == "/calls":
            writer.write_string(String(self.calls))
        elif request.path == "/bytes":
            writer.write_string(String(self.count))
        elif request.path == "/cancelled":
            writer.write_string(String(self.cancelled))
        elif request.path == "/done":
            writer.write_string(String(self.done))
        elif request.path == "/pause":
            self.paused = True
            writer.write_string("paused")
        elif request.path == "/resume":
            self.paused = False
            writer.write_string("resumed")
        elif request.path == "/ignored":
            writer.write_string("ignored")
        elif request.path == "/shutdown":
            self.shutdown = True
            writer.write_string("shutdown")
        elif request.path == "/standalone":
            var reader = request.body_reader()
            self.standalone = reader.detach()
            self.calls += 1
            self.count = 0
            writer.write_string("early")
        elif request.path == "/upload" or request.path == "/early":
            assert_equal(Bool(self.endpoints), False)
            self.calls += 1
            self.count = 0
            self.endpoints = writer.detach_with_body(request)
            self.early = request.path == "/early"
            if self.early:
                var body = List[Byte]("early".as_bytes())
                self.endpoints.value().sender.respond(200, Headers(), body^)
        else:
            writer.status = 404

    def consume(mut self) raises:
        if self.paused:
            return
        var buffer = Array[Byte, 1024](fill=0)
        if self.standalone:
            while True:
                var count: Int
                try:
                    count = self.standalone.value().receive(
                        Span(buffer), Timeout.nanoseconds(0)
                    )
                except error:
                    if error.kind == NetErrorKind.timeout():
                        return
                    raise error^
                if count == 0:
                    self.done += 1
                    self.standalone = None
                    return
                self.count += count
        if not self.endpoints:
            return
        while True:
            assert_equal(
                self.endpoints.value().receiver._pipe.pending_bytes() <= 4096,
                True,
            )
            var count: Int
            try:
                count = self.endpoints.value().receiver.receive(
                    Span(buffer), Timeout.nanoseconds(0)
                )
            except error:
                if error.kind == NetErrorKind.timeout():
                    return
                if (
                    error.kind != NetErrorKind.cancelled()
                    and error.kind != NetErrorKind.closed()
                ):
                    raise error^
                self.cancelled += 1
                self.endpoints = None
                return
            if count == 0:
                var trailers = self.endpoints.value().receiver.trailers()
                var finish = trailers.get_first("X-Finish")
                var result = (
                    String(self.count)
                    + String(":")
                    + (finish.value().copy() if finish else String("none"))
                )
                var body = List[Byte]()
                body.extend(result.as_bytes())
                if not self.early:
                    self.endpoints.value().sender.respond(200, Headers(), body^)
                self.done += 1
                self.endpoints = None
                return
            for index in range(count):
                assert_equal(buffer[index], Byte(97))
            self.count += count


def main() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    config.total_buffer_budget = 16384
    config.max_headers_bytes = 65536
    config.max_trailer_bytes = 65536
    config.body_deadline = Timeout.milliseconds(700)
    config.detached_response_timeout = Timeout.seconds(10)
    config.shutdown_grace = Timeout.milliseconds(500)
    var server = Server(config^)
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var listener = listen_udp("127.0.0.1:0")
    var address = String(listener.local_address())
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(quic_config^), listener^)
    )
    print("READY " + address)
    _ = external_call["fflush", Int32](
        Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    var handler = _StreamingHandler()
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.milliseconds(10))
        handler.consume()
        handler.input_count = len(server._http3_inputs)
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        handler.consume()
        handler.input_count = len(server._http3_inputs)
    handler.endpoints = None
    assert_equal(server._budget.used(), 0)
