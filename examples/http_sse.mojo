"""Server-Sent Events (SSE) minimal example using ResponseSender and pthread.

Demonstrates how to decouple an HTTP response from the event loop handler,
hand off streaming to an external background worker thread, and push SSE events
periodically while maintaining thread safety and cancellation checks.
"""

from std.ffi import c_int, c_size_t, c_ulong, external_call
from std.sys import size_of
from std.time import sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
)


@fieldwise_init
struct _SseWorkerContext:
    var sender_addr: Int
    var event_count: Int
    var interval_seconds: Float64
    var completed: Bool


def _sse_worker_thread(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx = arg.unsafe_bitcast[_SseWorkerContext]()
    var sender = ResponseSender(ctx[].sender_addr)

    try:
        var headers = Headers()
        headers.add(String("Content-Type"), String("text/event-stream"))
        headers.add(String("Cache-Control"), String("no-cache"))
        headers.add(String("Connection"), String("keep-alive"))

        sender.start(200, headers^)

        for i in range(ctx[].event_count):
            sleep(ctx[].interval_seconds)
            if sender.is_cancelled():
                break

            var event = (
                String('event: message\ndata: {"count": ')
                + String(i + 1)
                + String("}\n\n")
            )
            var sent = sender.send(event.as_bytes())
            if not sent:
                break

        sender.finish()
        ctx[].completed = True
    except:
        ctx[].completed = False
    return arg


struct SseHandler(Handler):
    var thread_handle_box: Pointer[UInt64, MutUntrackedOrigin]
    var worker_ctx_box: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self,
        thread_box: Pointer[UInt64, MutUntrackedOrigin],
        ctx_box: Pointer[Int, MutUntrackedOrigin],
    ):
        self.thread_handle_box = thread_box
        self.worker_ctx_box = ctx_box

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/events":
            var sender = writer.detach()
            var ctx_ptr = external_call[
                "malloc", Pointer[_SseWorkerContext, MutUntrackedOrigin]
            ](c_size_t(size_of[_SseWorkerContext]()))
            if Int(ctx_ptr) == 0:
                raise Error("malloc failed for SSE context")

            var sender_addr = sender._take()
            ctx_ptr.unsafe_write(
                _SseWorkerContext(
                    sender_addr=sender_addr,
                    event_count=3,
                    interval_seconds=1.0,
                    completed=False,
                )
            )
            self.worker_ctx_box[] = Int(ctx_ptr)

            var handle: UInt64 = 0
            var rc = external_call["pthread_create", c_int](
                Pointer(to=handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                _sse_worker_thread,
                ctx_ptr.unsafe_bitcast[Byte](),
            )
            if Int(rc) != 0:
                var s = ResponseSender(sender_addr)
                s.abort()
                external_call["free", NoneType](ctx_ptr)
                self.worker_ctx_box[] = 0
                return
            self.thread_handle_box[] = handle
        else:
            writer.set_status(404)
            writer.write_string("not found")


def _read_sse_stream[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    mut client: TCPConn,
    max_ticks: Int = 500,
) raises -> List[Byte]:
    var out = List[Byte]()
    var tmp = Array[Byte, 8192](fill=0)
    for _ in range(max_ticks):
        # Poll with 0.1s timeout to balance responsive ticking with worker sleep
        _ = server.tick(handler, Timeout.milliseconds(100))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            var s = String(from_utf8_lossy=Span(out))
            if s.find("0\r\n\r\n") >= 0:
                break
        except e:
            if e.kind == NetErrorKind.timeout():
                pass
            elif e.kind == NetErrorKind.closed():
                break
            else:
                raise e
    return out^


def main() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var thread_box = external_call[
        "malloc", Pointer[UInt64, MutUntrackedOrigin]
    ](c_size_t(size_of[UInt64]()))
    if Int(thread_box) == 0:
        raise Error("malloc failed for thread box")
    thread_box.unsafe_write(0)

    var ctx_box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    if Int(ctx_box) == 0:
        external_call["free", NoneType](thread_box)
        raise Error("malloc failed for ctx box")
    ctx_box.unsafe_write(0)

    var handler = SseHandler(thread_box, ctx_box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(5)
    )
    var resp_str = String()
    var run_error_msg = String()

    try:
        client.write_all(
            String(
                "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n"
            ).as_bytes(),
            Timeout.seconds(5),
        )
    except e:
        run_error_msg = String(e)

    if run_error_msg.byte_length() == 0:
        try:
            var raw_resp = _read_sse_stream(server, handler, client)
            resp_str = String(from_utf8_lossy=Span(raw_resp))
        except e:
            run_error_msg = String(e)

    # Join worker thread and cleanup allocations
    var join_failed = False
    var handle = thread_box[]
    if handle != 0:
        var rc = external_call["pthread_join", c_int](
            c_ulong(handle), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
        )
        if Int(rc) != 0:
            join_failed = True

    var worker_completed = True
    var ctx_addr = ctx_box[]
    if ctx_addr != 0:
        var ctx_ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=ctx_addr
        ).unsafe_bitcast[_SseWorkerContext]()
        worker_completed = ctx_ptr[].completed
        external_call["free", NoneType](ctx_ptr)

    external_call["free", NoneType](thread_box)
    external_call["free", NoneType](ctx_box)
    client.close()

    if run_error_msg.byte_length() > 0:
        raise Error(run_error_msg)
    if join_failed:
        raise Error("pthread_join failed")
    if not worker_completed:
        raise Error("SSE worker did not complete cleanly")

    if resp_str.find("HTTP/1.1 200 OK") < 0:
        raise Error("Expected 200 OK, got: " + resp_str)
    if resp_str.find("Content-Type: text/event-stream") < 0:
        raise Error("Expected text/event-stream header")
    if resp_str.find("Transfer-Encoding: chunked") < 0:
        raise Error("Expected chunked Transfer-Encoding")
    if resp_str.find('data: {"count": 1}') < 0:
        raise Error("Expected first SSE event")
    if resp_str.find('data: {"count": 2}') < 0:
        raise Error("Expected second SSE event")
    if resp_str.find('data: {"count": 3}') < 0:
        raise Error("Expected third SSE event")

    print("HTTP SSE succeeded")
