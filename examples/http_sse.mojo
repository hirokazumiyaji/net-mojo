"""Stream Server-Sent Events through a bounded reusable WorkerPool."""

from std.time import sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Handler,
    HandlerJob,
    Headers,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
    WorkerPool,
    WorkerPoolConfig,
)


@fieldwise_init
struct SseJob(HandlerJob):
    var event_count: Int
    var interval_seconds: Float64

    def run(mut self, mut sender: ResponseSender) raises:
        var headers = Headers()
        headers.add("Content-Type", "text/event-stream")
        headers.add("Cache-Control", "no-cache")
        sender.start(200, headers^)
        for index in range(self.event_count):
            sleep(self.interval_seconds)
            if sender.is_cancelled():
                return
            var event = (
                String('event: message\ndata: {"count": ')
                + String(index + 1)
                + "}\n\n"
            )
            if not sender.send(event.as_bytes()):
                return
        sender.finish()


@fieldwise_init
struct SseHandler(Handler):
    var pool: Pointer[WorkerPool, MutUntrackedOrigin]

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/events":
            _ = writer.offload(self.pool[], SseJob(3, 0.02))
        else:
            writer.set_status(404)
            writer.write_string("not found")


def _read_sse_stream(
    mut server: Server, mut handler: SseHandler, mut client: TCPConn
) raises -> String:
    var bytes = List[Byte]()
    var scratch = Array[Byte, 8192](fill=0)
    for _ in range(200):
        _ = server.tick(handler, Timeout.milliseconds(10))
        try:
            var count = client.try_read(Span(scratch))
            bytes.extend(Span(scratch)[0:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
        var response = String(from_utf8_lossy=Span(bytes))
        if response.endswith("0\r\n\r\n"):
            return response^
    raise Error("SSE response did not complete")


def main() raises:
    var pool = WorkerPool(WorkerPoolConfig(workers=1, queue_limit=8))
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = SseHandler(
        Pointer[WorkerPool, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=pool))
        )
    )
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    client.write_all(
        String("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    var response = _read_sse_stream(server, handler, client)
    if (
        response.find("HTTP/1.1 200 OK") < 0
        or response.find("Content-Type: text/event-stream") < 0
        or response.find("Transfer-Encoding: chunked") < 0
    ):
        raise Error("SSE response headers mismatch")
    for count in range(1, 4):
        if response.find(String('data: {"count": ') + String(count) + "}") < 0:
            raise Error("SSE event missing")
    client.close()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
    pool.shutdown()
    print("HTTP SSE succeeded")
