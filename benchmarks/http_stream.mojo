"""Benchmark for Phase E: concurrent detached streaming responses.

Measures:
- 100 concurrent detached SSE streams.
- Target generation rate of 50 events/sec per stream (20ms interval).
- Delivery latency from send() to client socket reception (p50, p90, p99).
- CPU utilization and aggregate event throughput.

Run: `pixi run benchmark-http-stream`.
"""

from std.ffi import c_int, c_size_t, c_ulong, external_call
from std.sys import size_of
from std.time import perf_counter_ns, sleep

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


def _quick_sort(mut list: List[Int], low: Int, high: Int):
    if low < high:
        var pivot = list[high]
        var i = low - 1
        for j in range(low, high):
            if list[j] <= pivot:
                i += 1
                var tmp = list[i]
                list[i] = list[j]
                list[j] = tmp
        var tmp = list[i + 1]
        list[i + 1] = list[high]
        list[high] = tmp
        var p = i + 1
        _quick_sort(list, low, p - 1)
        _quick_sort(list, p + 1, high)


def _sort_latencies(mut list: List[Int]):
    if len(list) > 1:
        _quick_sort(list, 0, len(list) - 1)


@fieldwise_init
struct _BenchWorkerContext:
    var sender_addr: Int
    var events_to_send: Int
    var interval_seconds: Float64
    var stream_id: Int
    var success_count: Int
    var done: Bool


def _bench_stream_worker_thread(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx = arg.unsafe_bitcast[_BenchWorkerContext]()
    var sender = ResponseSender(ctx[].sender_addr)

    try:
        var headers = Headers()
        headers.add(String("Content-Type"), String("text/event-stream"))
        headers.add(String("Cache-Control"), String("no-cache"))
        sender.start(200, headers^)

        for _ in range(ctx[].events_to_send):
            sleep(ctx[].interval_seconds)
            if sender.is_cancelled():
                break

            var now_ns = Int(perf_counter_ns())
            var msg = (
                String("event: msg\ndata: ") + String(now_ns) + String("\n\n")
            )
            var ok = sender.send(msg.as_bytes())
            if not ok:
                break
            ctx[].success_count += 1

        sender.finish()
        ctx[].done = True
    except:
        ctx[].done = False
    return arg


struct BenchStreamHandler(Handler):
    var sender_boxes: Pointer[Int, MutUntrackedOrigin]
    var next_idx: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self,
        boxes: Pointer[Int, MutUntrackedOrigin],
        idx_ptr: Pointer[Int, MutUntrackedOrigin],
    ):
        self.sender_boxes = boxes
        self.next_idx = idx_ptr

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/stream":
            var idx = self.next_idx[]
            self.next_idx[] = idx + 1
            var sender = writer.detach()
            var slot_ptr = _get_ptr(self.sender_boxes, idx)
            slot_ptr[] = sender._take()
        else:
            writer.set_status(404)
            writer.write_string("not found")


def _get_ptr[
    T: AnyType
](base: Pointer[T, MutUntrackedOrigin], i: Int) -> Pointer[
    T, MutUntrackedOrigin
]:
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(base) + i * size_of[T]()
    )


def _process_stream_buffer(
    mut buf: List[Byte],
    now_ns: Int,
    mut latencies: List[Int],
) -> Bool:
    var marker = "data: ".as_bytes()
    var marker_len = len(marker)
    var consumed_to = 0
    var has_stream_end = False

    var s = String(from_utf8_lossy=Span(buf))
    if s.find("0\r\n\r\n") >= 0:
        has_stream_end = True

    var j = 0
    while j + marker_len <= len(buf):
        var matched = True
        for m in range(marker_len):
            if buf[j + m] != marker[m]:
                matched = False
                break
        if matched:
            var num_start = j + marker_len
            var num_end = num_start
            while (
                num_end < len(buf)
                and buf[num_end] != Byte(ord("\n"))
                and buf[num_end] != Byte(ord("\r"))
            ):
                num_end += 1

            if num_end < len(buf):
                var val: Int = 0
                for p in range(num_start, num_end):
                    if buf[p] >= Byte(ord("0")) and buf[p] <= Byte(ord("9")):
                        val = val * 10 + Int(buf[p] - Byte(ord("0")))
                if val > 0 and val <= now_ns:
                    var lat_us = (now_ns - val) // 1000
                    if lat_us >= 0 and lat_us < 10000000:
                        latencies.append(lat_us)
                j = num_end + 1
                consumed_to = j
            else:
                break
        else:
            j += 1

    if consumed_to > 0:
        var remaining = List[Byte]()
        for k in range(consumed_to, len(buf)):
            remaining.append(buf[k])
        buf = remaining^

    return has_stream_end


def main() raises:
    var num_streams = 100
    var events_per_stream = 50
    # 20ms interval = 50 events/sec per stream
    var event_interval = 0.020

    print("=== HTTP Detached Streaming Benchmark ===")
    print("Concurrent streams:", num_streams)
    print("Events per stream:", events_per_stream)
    print("Target stream rate: 50 events/sec (interval: 20ms)")
    print("Total events:", num_streams * events_per_stream)

    var config = ServerConfig.default()
    config.max_connections = 2000
    config.stream_queue_limit = 2 * 1024 * 1024
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var addr_str = String("127.0.0.1:") + String(port)

    # Allocate storage for sender addresses and tracking
    var boxes_size = c_size_t(num_streams * size_of[Int]())
    var sender_boxes = external_call[
        "malloc", Pointer[Int, MutUntrackedOrigin]
    ](boxes_size)
    if Int(sender_boxes) == 0:
        raise Error("malloc failed for sender_boxes")
    for i in range(num_streams):
        _get_ptr(sender_boxes, i).unsafe_write(0)

    var idx_ptr = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    if Int(idx_ptr) == 0:
        external_call["free", NoneType](sender_boxes)
        raise Error("malloc failed for idx_ptr")
    idx_ptr.unsafe_write(0)

    var handler = BenchStreamHandler(sender_boxes, idx_ptr)

    # Dial 100 client connections and initiate streaming requests
    var clients = List[TCPConn]()
    var req_bytes = String(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection:"
        " keep-alive\r\n\r\n"
    ).as_bytes()

    for _ in range(num_streams):
        var c = dial_tcp(addr_str, Timeout.seconds(5))
        c.write_all(req_bytes, Timeout.seconds(5))
        clients.append(c^)

    # Tick server until all 100 requests are detached
    var detach_ticks = 0
    while idx_ptr[] < num_streams and detach_ticks < 1000:
        _ = server.tick(handler, Timeout.milliseconds(5))
        detach_ticks += 1

    if idx_ptr[] < num_streams:
        raise Error("Failed to detach all connections")

    # Prepare thread contexts and spawn 100 worker threads
    var ctx_array = external_call[
        "malloc", Pointer[_BenchWorkerContext, MutUntrackedOrigin]
    ](c_size_t(num_streams * size_of[_BenchWorkerContext]()))
    if Int(ctx_array) == 0:
        raise Error("malloc failed for ctx_array")

    var threads = external_call["malloc", Pointer[UInt64, MutUntrackedOrigin]](
        c_size_t(num_streams * size_of[UInt64]())
    )
    if Int(threads) == 0:
        raise Error("malloc failed for threads")

    for i in range(num_streams):
        _get_ptr(threads, i).unsafe_write(0)

    var cpu_start = external_call["clock", c_ulong]()
    var bench_start = perf_counter_ns()

    for i in range(num_streams):
        var s_addr = _get_ptr(sender_boxes, i)[]
        var ctx_p = _get_ptr(ctx_array, i)
        ctx_p.unsafe_write(
            _BenchWorkerContext(
                sender_addr=s_addr,
                events_to_send=events_per_stream,
                interval_seconds=event_interval,
                stream_id=i,
                success_count=0,
                done=False,
            )
        )
        var handle: UInt64 = 0
        var rc = external_call["pthread_create", c_int](
            Pointer(to=handle),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _bench_stream_worker_thread,
            ctx_p.unsafe_bitcast[Byte](),
        )
        if Int(rc) != 0:
            var s = ResponseSender(s_addr)
            s.abort()
            for prev in range(i):
                var h = _get_ptr(threads, prev)[]
                if h != 0:
                    _ = external_call["pthread_join", c_int](
                        c_ulong(h),
                        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                    )
            for rem in range(i + 1, num_streams):
                var rem_addr = _get_ptr(sender_boxes, rem)[]
                if rem_addr != 0:
                    var rem_s = ResponseSender(rem_addr)
                    rem_s.abort()
            raise Error("pthread_create failed")
        _get_ptr(threads, i).unsafe_write(handle)

    # Event loop & client consumption
    var latencies = List[Int]()
    var finished_streams = 0
    var stream_finished = List[Bool]()
    var remainders = List[List[Byte]]()
    for _ in range(num_streams):
        stream_finished.append(False)
        remainders.append(List[Byte]())

    var read_buf = Array[Byte, 8192](fill=0)
    var bench_deadline_ns = (
        Int(perf_counter_ns()) + 30 * 1000 * 1000 * 1000
    )  # 30 second deadline

    while finished_streams < num_streams:
        if Int(perf_counter_ns()) > bench_deadline_ns:
            raise Error(
                "Benchmark timed out after 30 seconds waiting for all streams"
                " to finish"
            )

        # Tick the event loop to flush detached sender messages to sockets
        _ = server.tick(handler, Timeout.milliseconds(2))

        var now = Int(perf_counter_ns())
        for i in range(num_streams):
            if stream_finished[i]:
                continue

            try:
                var n = clients[i].try_read(Span(read_buf))
                if n > 0:
                    for k in range(n):
                        remainders[i].append(read_buf[k])
                    var is_ended = _process_stream_buffer(
                        remainders[i], now, latencies
                    )
                    if is_ended:
                        stream_finished[i] = True
                        finished_streams += 1
                elif n == 0:
                    _ = _process_stream_buffer(remainders[i], now, latencies)
                    stream_finished[i] = True
                    finished_streams += 1
            except e:
                if e.kind == NetErrorKind.closed():
                    _ = _process_stream_buffer(remainders[i], now, latencies)
                    stream_finished[i] = True
                    finished_streams += 1
                elif e.kind == NetErrorKind.timeout():
                    pass

    var bench_end = perf_counter_ns()
    var cpu_end = external_call["clock", c_ulong]()

    # Join all threads
    for i in range(num_streams):
        var handle = _get_ptr(threads, i)[]
        if handle != 0:
            _ = external_call["pthread_join", c_int](
                c_ulong(handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )

    var wall_seconds = Float64(Int(bench_end) - Int(bench_start)) / 1e9
    var cpu_seconds = Float64(Int(cpu_end) - Int(cpu_start)) / 1000000.0
    var cpu_percent = (cpu_seconds / wall_seconds) * 100.0
    var total_events = len(latencies)
    var throughput = Float64(total_events) / wall_seconds

    _sort_latencies(latencies)

    var p50 = 0
    var p90 = 0
    var p99 = 0
    if total_events > 0:
        p50 = latencies[Int(Float64(total_events) * 0.50)]
        p90 = latencies[Int(Float64(total_events) * 0.90)]
        p99 = latencies[Int(Float64(total_events) * 0.99)]

    print("--- Results ---")
    print("Elapsed wall time (s):", wall_seconds)
    print("CPU time (s):", cpu_seconds)
    print("CPU utilization (%):", cpu_percent)
    print("Total events measured:", total_events)
    print("Aggregate throughput (events/s):", throughput)
    print("Latency p50 (us):", p50)
    print("Latency p90 (us):", p90)
    print("Latency p99 (us):", p99)
    print("Latency p50 (ms):", Float64(p50) / 1000.0)
    print("Latency p99 (ms):", Float64(p99) / 1000.0)

    # Cleanup
    for i in range(num_streams):
        clients[i].close()

    external_call["free", NoneType](sender_boxes)
    external_call["free", NoneType](idx_ptr)
    external_call["free", NoneType](ctx_array)
    external_call["free", NoneType](threads)
    print("Benchmark completed successfully.")
