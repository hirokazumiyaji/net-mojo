"""Move an owned streaming receiver into a WorkerPool job with bounded scratch."""

from std.time import perf_counter_ns, sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
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


@fieldwise_init
struct CountBodyJob(HandlerJob):
    var receiver: RequestBodyReceiver

    def run(mut self, mut sender: ResponseSender) raises:
        var total = 0
        var scratch = Array[Byte, 17](fill=0)
        while not sender.is_cancelled():
            var count = self.receiver.receive(Span(scratch), Timeout.seconds(2))
            if count == 0:
                var trailers = self.receiver.trailers()
                var result = trailers.get_first("X-Result")
                var body = List[Byte]()
                body.extend(
                    (
                        String(total)
                        + ":"
                        + (String(result.value()) if result else String("none"))
                    ).as_bytes()
                )
                sender.respond(body=body^)
                return
            total += count


@fieldwise_init
struct BodyHandler(Handler):
    var pool: Pointer[WorkerPool, MutUntrackedOrigin]

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/fast":
            writer.write_string("fast")
            return
        var body = req.body_reader()
        _ = writer.offload(self.pool[], CountBodyJob(body.detach()))


def _read_response(
    mut server: Server,
    mut handler: BodyHandler,
    mut client: TCPConn,
    expected: StringSlice,
) raises -> String:
    var bytes = List[Byte]()
    var scratch = Array[Byte, 4096](fill=0)
    var expires = perf_counter_ns() + 5_000_000_000
    while perf_counter_ns() < expires:
        _ = server.tick(handler, Timeout.milliseconds(10))
        try:
            var count = client.try_read(Span(scratch))
            bytes.extend(Span(scratch)[0:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
        var response = String(from_utf8_lossy=Span(bytes))
        if response.endswith(expected):
            if response.find("HTTP/1.1 200 OK") < 0:
                raise Error("streaming offload status mismatch")
            return response^
        sleep(0.001)
    raise Error("streaming offload response did not complete")


def main() raises:
    var pool = WorkerPool(WorkerPoolConfig(workers=1, queue_limit=8))
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 32
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = BodyHandler(
        Pointer[WorkerPool, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=pool))
        )
    )
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var upload = dial_tcp(address, Timeout.seconds(2))
    var sibling = dial_tcp(address, Timeout.seconds(2))
    upload.write_all(
        String(
            "POST /count HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding:"
            " chunked\r\nTrailer: X-Result\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    sibling.write_all(
        String("GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    _ = _read_response(server, handler, sibling, "\r\n\r\nfast")
    var wire = List[Byte]()
    wire.extend(String("2000\r\n").as_bytes())
    wire.extend(List[Byte](length=8192, fill=97))
    wire.extend(String("\r\n0\r\nX-Result: done\r\n\r\n").as_bytes())
    upload.write_all(Span(wire), Timeout.seconds(2))
    _ = _read_response(server, handler, upload, "\r\n\r\n8192:done")
    upload.close()
    sibling.close()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
    pool.shutdown()
    print("HTTP owned receiver offload succeeded")
