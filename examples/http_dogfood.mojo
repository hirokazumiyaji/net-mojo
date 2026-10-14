from std.os import getenv
from std.time import perf_counter_ns

from net import listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig


struct DogfoodHandler(Handler):
    var started_ns: Int
    var requests: UInt64

    def __init__(out self):
        self.started_ns = Int(perf_counter_ns())
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        if req.method == "GET" or req.method == "HEAD":
            if req.path == "/json":
                writer.headers.add("Content-Type", "application/json")
                writer.write_string(
                    '{"message":"hello, mojo http json","ok":true}'
                )
                return
            if req.path == "/metrics":
                var uptime = (
                    Int(perf_counter_ns()) - self.started_ns
                ) // 1_000_000_000
                writer.headers.add("Content-Type", "text/plain; version=0.0.4")
                writer.write_string(
                    "# HELP net_mojo_uptime_seconds Time since process"
                    " startup.\n# TYPE net_mojo_uptime_seconds"
                    " gauge\nnet_mojo_uptime_seconds "
                    + String(uptime)
                    + "\n# HELP net_mojo_requests_total Requests handled by"
                    " this process.\n# TYPE net_mojo_requests_total"
                    " counter\nnet_mojo_requests_total "
                    + String(self.requests)
                    + "\n"
                )
                return
        elif req.method == "POST" and req.path == "/echo":
            writer.headers.add("Content-Type", "application/octet-stream")
            writer.write(Span(req.body))
            return
        writer.set_status(404)
        writer.write_string("not found")


def main() raises:
    var address = String("127.0.0.1:8080")
    var configured = getenv("DOGFOOD_ADDRESS")
    if configured.byte_length() > 0:
        address = configured^
    var server = Server(ServerConfig.default())
    var listener = listen_tcp(address)
    print("dogfood listening on", listener.local_address())
    var handler = DogfoodHandler()
    server.serve(listener^, handler)
