"""Production HTTP/1.1 benchmark entry point matching the Go/H2/H3 handlers."""

from benchmarks.http_handler import BenchHandler
from net import listen_tcp
from net.http import Server, ServerConfig


def main() raises:
    var server = Server(ServerConfig.default())
    var listener = listen_tcp("127.0.0.1:18081")
    var handler = BenchHandler()
    print("http1_server listening on 127.0.0.1:18081 proto=http/1.1")
    server.serve(listener^, handler)
