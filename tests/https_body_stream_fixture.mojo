from std.testing import assert_equal
from std.time import perf_counter_ns
from net import Timeout, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    Request,
    RequestBodyEndpoints,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.tls import TLSContext


struct _StreamingHandler(Handler):
    var endpoints: Optional[RequestBodyEndpoints]
    var calls: Int
    var cancelled: Int
    var count: Int
    var shutdown: Bool

    def __init__(out self):
        self.endpoints = None
        self.calls = 0
        self.cancelled = 0
        self.count = 0
        self.shutdown = False

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        writer.should_close = True
        if request.path == "/calls":
            writer.write_string(String(self.calls))
        elif request.path == "/bytes":
            writer.write_string(String(self.count))
        elif request.path == "/cancelled":
            writer.write_string(String(self.cancelled))
        elif request.path == "/shutdown":
            self.shutdown = True
            writer.write_string("shutdown")
        elif request.path == "/upload":
            assert_equal(Bool(self.endpoints), False)
            self.calls += 1
            self.count = 0
            self.endpoints = writer.detach_with_body(request)
        else:
            writer.status = 404

    def consume(mut self) raises:
        if not self.endpoints:
            return
        var buffer = Array[Byte, 1024](fill=0)
        while True:
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
                self.endpoints.value().sender.respond(
                    200, Headers(), body^, should_close=True
                )
                self.endpoints = None
                return
            for index in range(count):
                assert_equal(buffer[index], Byte(97))
            self.count += count


def main() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    config.shutdown_grace = Timeout.milliseconds(100)
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
    print("READY", server.local_address().port)
    var handler = _StreamingHandler()
    var deadline = Int(perf_counter_ns()) + 120_000_000_000
    while not handler.shutdown:
        if Int(perf_counter_ns()) >= deadline:
            raise Error("HTTPS body fixture timed out")
        _ = server.tick(handler, Timeout.milliseconds(1))
        handler.consume()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(1)):
        handler.consume()
    print("DONE")
