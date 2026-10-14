"""Copy a buffered request into a reusable worker and keep the loop responsive."""

from std.time import sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Handler,
    HandlerJob,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
    WorkerPool,
    WorkerPoolConfig,
)


@fieldwise_init
struct EchoJob(HandlerJob):
    var body: List[Byte]

    def run(mut self, mut sender: ResponseSender) raises:
        sleep(0.05)
        if sender.is_cancelled():
            return
        var body = self.body^
        self.body = List[Byte]()
        sender.respond(body=body^)


@fieldwise_init
struct OffloadHandler(Handler):
    var pool: Pointer[WorkerPool, MutUntrackedOrigin]

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/echo":
            _ = writer.offload(self.pool[], EchoJob(req.body.copy()))
        elif req.path == "/fast":
            writer.write_string("fast\n")
        else:
            writer.set_status(404)


def _read_response(
    mut server: Server,
    mut handler: OffloadHandler,
    mut client: TCPConn,
    expected: StringSlice,
) raises -> String:
    var bytes = List[Byte]()
    var scratch = Array[Byte, 4096](fill=0)
    for _ in range(200):
        _ = server.tick(handler, Timeout.milliseconds(10))
        try:
            var count = client.try_read(Span(scratch))
            bytes.extend(Span(scratch)[0:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
        var response = String(from_utf8_lossy=Span(bytes))
        if response.endswith(expected):
            return response^
    raise Error("offload response did not complete")


def main() raises:
    var pool = WorkerPool(WorkerPoolConfig(workers=2, queue_limit=8))
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = OffloadHandler(
        Pointer[WorkerPool, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=pool))
        )
    )
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var heavy = dial_tcp(address, Timeout.seconds(2))
    var fast = dial_tcp(address, Timeout.seconds(2))
    heavy.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length:"
            " 5\r\n\r\nhello"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    fast.write_all(
        String("GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    var fast_response = _read_response(server, handler, fast, "\r\n\r\nfast\n")
    var heavy_response = _read_response(server, handler, heavy, "\r\n\r\nhello")
    if (
        fast_response.find("HTTP/1.1 200 OK") < 0
        or heavy_response.find("HTTP/1.1 200 OK") < 0
    ):
        raise Error("offload response status mismatch")
    heavy.close()
    fast.close()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
    pool.shutdown()
    print("HTTP worker offload succeeded")
