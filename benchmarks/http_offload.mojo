"""Compare loop and WorkerPool latency for sixteen concurrent 100ms jobs.

Reports measurements for blocking sleep and CPU work without pass/fail thresholds.
Run: pixi run benchmark-http-offload.
"""

from std.ffi import c_int, c_ulong, external_call
from std.time import perf_counter_ns, sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net._actor import PthreadMutex
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


def _work(cpu: Bool):
    if cpu:
        var expires = perf_counter_ns() + 100_000_000
        while perf_counter_ns() < expires:
            pass
    else:
        sleep(0.1)


@fieldwise_init
struct HeavyJob(HandlerJob):
    var cpu: Bool

    def run(mut self, mut sender: ResponseSender) raises:
        _work(self.cpu)
        if sender.is_cancelled():
            return
        var body = List[Byte]()
        body.extend(String("heavy\n").as_bytes())
        sender.respond(body=body^)


@fieldwise_init
struct BenchHandler(Handler):
    var pool: Pointer[WorkerPool, MutUntrackedOrigin]
    var offload: Bool
    var cpu: Bool

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/heavy":
            if self.offload:
                _ = writer.offload(self.pool[], HeavyJob(self.cpu))
            else:
                _work(self.cpu)
                writer.write_string("heavy\n")
        else:
            writer.write_string("fast\n")


def _sort(mut values: List[Int]):
    for index in range(1, len(values)):
        var value = values[index]
        var position = index
        while position > 0 and values[position - 1] > value:
            values[position] = values[position - 1]
            position -= 1
        values[position] = value


@fieldwise_init
struct _ClientState(Movable):
    var mutex: PthreadMutex
    var clients: List[TCPConn]
    var starts: List[Int]
    var latencies: List[Int]
    var sibling_latency: Int
    var complete: Bool
    var error: String

    def __deinit__(deinit self):
        self.mutex.destroy()


def _measure_clients(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var state = arg.unsafe_bitcast[_ClientState]()
    var buffers = List[List[Byte]]()
    var complete = List[Bool]()
    for _ in range(17):
        buffers.append(List[Byte]())
        complete.append(False)
    var remaining = 17
    var scratch = Array[Byte, 4096](fill=0)
    try:
        while remaining > 0:
            if perf_counter_ns() - state[].starts[0] > 10_000_000_000:
                raise Error("benchmark responses did not complete")
            for index in range(17):
                if complete[index]:
                    continue
                try:
                    var count = state[].clients[index].try_read(Span(scratch))
                    buffers[index].extend(Span(scratch)[0:count])
                except error:
                    if error.kind != NetErrorKind.timeout():
                        raise error^
                var response = String(from_utf8_lossy=Span(buffers[index]))
                var expected = String(
                    "\r\n\r\nheavy\n"
                ) if index < 16 else String("\r\n\r\nfast\n")
                if response.endswith(expected):
                    if response.find("HTTP/1.1 200 OK") < 0:
                        raise Error("benchmark response status mismatch")
                    var elapsed = perf_counter_ns() - state[].starts[index]
                    if index < 16:
                        state[].latencies.append(elapsed)
                    else:
                        state[].sibling_latency = elapsed
                    complete[index] = True
                    remaining -= 1
            if remaining > 0:
                sleep(0.0001)
    except error:
        state[].error = String(error)
    state[].mutex.lock()
    state[].complete = True
    state[].mutex.unlock()
    return arg


def _run(cpu: Bool, offload: Bool) raises:
    var pool = WorkerPool(WorkerPoolConfig(workers=4, queue_limit=16))
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = BenchHandler(
        Pointer[WorkerPool, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=pool))
        ),
        offload,
        cpu,
    )
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var clients = List[TCPConn]()
    var starts = List[Int]()
    for _ in range(17):
        var client = dial_tcp(address, Timeout.seconds(5))
        clients.append(client^)
    for _ in range(4):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    var started = perf_counter_ns()
    for index in range(17):
        var path = String("/heavy") if index < 16 else String("/fast")
        starts.append(perf_counter_ns())
        var request = "GET " + path + " HTTP/1.1\r\nHost: localhost\r\n\r\n"
        clients[index].write_all(request.as_bytes(), Timeout.seconds(5))
    var state = _ClientState(
        PthreadMutex._uninitialized(),
        clients^,
        starts^,
        List[Int](),
        0,
        False,
        String(),
    )
    state.mutex._initialize()
    var thread: UInt64 = 0
    var create_result = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _measure_clients,
        Pointer(to=state).unsafe_bitcast[Byte](),
    )
    if create_result != 0:
        raise Error("benchmark client thread creation failed")
    var loop_error = String()
    try:
        while True:
            state.mutex.lock()
            var complete = state.complete
            state.mutex.unlock()
            if complete:
                break
            _ = server.tick(handler, Timeout.nanoseconds(1_000_000))
    except error:
        loop_error = String(error)
    var join_result = external_call["pthread_join", c_int](
        c_ulong(thread), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    if join_result != 0:
        raise Error("benchmark client thread join failed")
    if loop_error.byte_length() > 0:
        raise Error(loop_error)
    if state.error.byte_length() > 0:
        raise Error(state.error)
    var elapsed = perf_counter_ns() - started
    _sort(state.latencies)
    print(
        "workload:",
        "cpu" if cpu else "sleep",
        "mode:",
        "offload" if offload else "loop",
        "requests: 16 workers: 4 duration/job: 100ms",
    )
    print("elapsed ms:", Float64(elapsed) / 1e6)
    print(
        "heavy latency ms p50/p90/p99:",
        Float64(state.latencies[7]) / 1e6,
        Float64(state.latencies[14]) / 1e6,
        Float64(state.latencies[15]) / 1e6,
    )
    print("sibling latency ms:", Float64(state.sibling_latency) / 1e6)
    for index in range(len(state.clients)):
        state.clients[index].close()
    server.request_shutdown()
    while server.tick(handler, Timeout.milliseconds(10)):
        pass
    pool.shutdown()


def main() raises:
    for cpu in [False, True]:
        _run(cpu, False)
        _run(cpu, True)
