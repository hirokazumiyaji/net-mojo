"""Phase 4 server benchmark: throughput and idle scalability.

Measures the epoll/kqueue server (no poll fallback):
- Sequential keep-alive round-trips per second (small fixed response).
- Average nonblocking tick time with many idle keep-alive connections
  (proves ready-batch-only processing: idle conns cost no per-tick scan).

Run: `pixi run benchmark-http-server`.
"""

from std.ffi import c_int, external_call
from std.time import perf_counter_ns

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.http import (
    Handler,
    HandlerFactory,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerPool,
)


struct BenchHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/fixed":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        else:
            writer.set_status(404)
            writer.write_string("not found")


def _header_end(buf: List[Byte]) -> Int:
    var i = 0
    while i + 3 < len(buf):
        if (
            buf[i] == Byte(ord("\r"))
            and buf[i + 1] == Byte(ord("\n"))
            and buf[i + 2] == Byte(ord("\r"))
            and buf[i + 3] == Byte(ord("\n"))
        ):
            return i + 4
        i += 1
    return -1


def _content_length_of(buf: List[Byte]) -> Int:
    var end = _header_end(buf)
    if end < 0:
        return -1
    var head = String(from_utf8_lossy=Span(buf)[0:end]).lower()
    var needle = String("\r\ncontent-length:")
    var at = head.find(needle)
    if at < 0:
        return -1
    var value_start = at + len(needle.as_bytes())
    var value_end = value_start
    var head_bytes = head.as_bytes()
    while value_end < len(head_bytes) and (
        head_bytes[value_end] == Byte(ord(" "))
        or head_bytes[value_end] == Byte(ord("\t"))
    ):
        value_end += 1
    var digits_start = value_end
    while value_end < len(head_bytes) and (
        head_bytes[value_end] >= Byte(ord("0"))
        and head_bytes[value_end] <= Byte(ord("9"))
    ):
        value_end += 1
    if value_end == digits_start:
        return -1
    var value = 0
    for i in range(digits_start, value_end):
        value = value * 10 + Int(head_bytes[i] - Byte(ord("0")))
    return value


def _response_complete(buf: List[Byte]) -> Bool:
    """True once headers and the Content-Length body have fully arrived."""
    var end = _header_end(buf)
    if end < 0:
        return False
    var length = _content_length_of(buf)
    if length < 0:
        return False
    return len(buf) >= end + length


def _drain(
    mut server: Server,
    mut handler: BenchHandler,
    mut client: TCPConn,
    max_ticks: Int,
) raises -> List[Byte]:
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(max_ticks):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    return out^


@fieldwise_init
struct PoolBenchHandler(Handler):
    var worker_id: Int

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var value = UInt64(req.path.byte_length() + self.worker_id)
        for _ in range(200_000):
            value = value * UInt64(6364136223846793005) + UInt64(1)
        writer.write_string(String(value))


struct PoolBenchFactory(HandlerFactory):
    comptime HandlerType = PoolBenchHandler

    def __init__(out self):
        pass

    def build(mut self, worker_id: Int) raises -> PoolBenchHandler:
        return PoolBenchHandler(worker_id)


@fieldwise_init
struct PoolBenchContext(Movable):
    var pool: ServerPool
    var failed: Bool


def _pool_bench_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[PoolBenchContext]()
    var factory = PoolBenchFactory()
    try:
        context[].pool.serve(factory)
    except:
        context[].failed = True
    return arg


def _pool_round(mut clients: List[TCPConn]) raises:
    var request = String(
        "GET /cpu HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
    )
    for i in range(len(clients)):
        clients[i].write_all(request.as_bytes(), Timeout.seconds(10))
    for i in range(len(clients)):
        var response = List[Byte]()
        var buffer = Array[Byte, 1024](fill=0)
        while not _response_complete(response):
            var count = clients[i].read(Span(buffer), Timeout.seconds(10))
            if count == 0:
                raise Error("pool benchmark connection closed")
            for j in range(count):
                response.append(buffer[j])


def _pool_clients(address: String) raises -> List[TCPConn]:
    var clients = List[TCPConn]()
    for _ in range(32):
        clients.append(dial_tcp(address, Timeout.seconds(5)))
    return clients^


def _benchmark_pool(workers: Int) raises:
    var pool = ServerPool(ServerConfig.default(), workers=workers)
    var control = pool.control()
    var listener = listen_tcp("127.0.0.1:0")
    var address = String(listener.local_address())
    pool.add_listener(listener^)
    var context = PoolBenchContext(pool^, False)
    var thread: UInt64 = 0
    var started = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _pool_bench_entry,
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    if started != 0:
        raise Error("pool benchmark pthread_create failed")
    var failure = String()
    try:
        var clients = _pool_clients(address)
        for _ in range(5):
            _pool_round(clients)
        var start = perf_counter_ns()
        var batches = 50
        for _ in range(batches):
            _pool_round(clients)
        var elapsed = Int(perf_counter_ns()) - Int(start)
        print(
            "pool workers:",
            workers,
            "connections:",
            len(clients),
            "requests/s:",
            Float64(batches * len(clients)) * 1e9 / Float64(elapsed),
        )
        for i in range(len(clients)):
            clients[i].close()
    except error:
        failure = String(error)
    control.request_shutdown()
    var joined = external_call["pthread_join", c_int](
        thread,
        Optional[
            Pointer[Pointer[Byte, MutUntrackedOrigin], MutUntrackedOrigin]
        ](None),
    )
    if joined != 0 or context.failed:
        raise Error("pool benchmark worker failed")
    if failure:
        raise Error(failure)


def main() raises:
    var config = ServerConfig.default()
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var addr = String("127.0.0.1:") + String(port)
    var handler = BenchHandler()

    # A: sequential round-trips on one keep-alive connection.
    var client = dial_tcp(addr, Timeout.seconds(2))
    var request = String(
        "GET /fixed HTTP/1.1\r\nHost: example.com\r\nConnection:"
        " keep-alive\r\n\r\n"
    ).as_bytes()
    # Warmup.
    for _ in range(20):
        client.write_all(request, Timeout.seconds(2))
        var warm = _drain(server, handler, client, 300)
        if len(warm) == 0:
            raise Error("warmup round-trip failed")
    var rounds = 500
    var start = perf_counter_ns()
    for _ in range(rounds):
        client.write_all(request, Timeout.seconds(2))
        var body = _drain(server, handler, client, 300)
        if len(body) == 0:
            raise Error("benchmark round-trip failed")
    var elapsed_ns = Int(perf_counter_ns()) - Int(start)
    var rps = Float64(rounds) * 1e9 / Float64(elapsed_ns)
    print("sequential keep-alive round-trips:", rounds)
    print("elapsed (ms):", Float64(elapsed_ns) / 1e6)
    print("round-trips/s:", rps)
    client.close()

    # B: idle scalability — N idle keep-alive conns, nonblocking ticks.
    var idle_conns = 1000
    var holders = List[TCPConn]()
    var batch = 50
    var dialed = 0
    while dialed < idle_conns:
        var n = batch
        if dialed + n > idle_conns:
            n = idle_conns - dialed
        for _ in range(n):
            var c = dial_tcp(addr, Timeout.seconds(5))
            holders.append(c^)
        dialed += n
        for _ in range(10):
            _ = server.tick(handler, Timeout.nanoseconds(0))
    print("idle connections accepted:", server.active_connections())
    var ticks = 50
    var tick_start = perf_counter_ns()
    for _ in range(ticks):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    var tick_ns = Int(perf_counter_ns()) - Int(tick_start)
    print("nonblocking ticks:", ticks)
    print(
        "avg tick (us) with",
        idle_conns,
        "idle:",
        Float64(tick_ns) / Float64(ticks) / 1e3,
    )
    for i in range(len(holders)):
        try:
            holders[i].close()
        except e:
            _ = e
    # Drain the closes.
    for _ in range(50):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    print("active after close:", server.active_connections())
    _benchmark_pool(1)
    _benchmark_pool(2)
    _benchmark_pool(4)
    print("benchmark-http-server done")
