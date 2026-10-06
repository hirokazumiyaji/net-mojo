"""Production HTTP/1.1 benchmark entry point matching the Go/H2/H3 handlers."""

from benchmarks.http_handler import BenchHandler
from benchmarks._process_resources import print_fd_limits
from net import Timeout, listen_tcp
from net.http import Server, ServerConfig


def main() raises:
    print_fd_limits()
    var config = ServerConfig.default()
    config.idle_timeout = Timeout.seconds(3600)
    print(
        "http1 benchmark idle_timeout_seconds=3600 max_connections=",
        config.max_connections,
        "total_buffer_budget=",
        config.total_buffer_budget,
    )
    var server = Server(config^)
    var listener = listen_tcp("127.0.0.1:18081")
    var handler = BenchHandler()
    print("http1_server listening on 127.0.0.1:18081 proto=http/1.1")
    server.serve(listener^, handler)
