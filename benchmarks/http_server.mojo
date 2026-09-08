"""Phase 4 server benchmark: throughput and idle scalability.

Measures the epoll/kqueue server (no poll fallback):
- Sequential keep-alive round-trips per second (small fixed response).
- Average nonblocking tick time with many idle keep-alive connections
  (proves ready-batch-only processing: idle conns cost no per-tick scan).

Run: `pixi run benchmark-http-server`.
"""

from std.time import perf_counter_ns

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig


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
            if len(out) >= 200:
                # One small response fits well within 200B; stop early.
                var text = String(from_utf8_lossy=Span(out))
                if text.find("Content-Length:") >= 0 and text.find("aaaa") >= 0:
                    break
        except e:
            _ = e
            continue
    return out^


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
    print("benchmark-http-server done")
