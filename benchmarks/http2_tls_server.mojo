"""HTTPS + HTTP/2 benchmark server matching the Go baseline handlers.

Handlers (same shapes as `benchmarks/http_go/main.go`):
  - GET /fixed : 64 B `a` x 64, text/plain
  - GET /json  : exactly 1024 B application/json
  - POST /echo : echo request body (capped at 1 MiB)

Requires TLS + HPACK shims from `pixi run -e tls-http2 tls-build` and
`pixi run -e tls-http2 hpack-test`. Listen address is fixed at
`127.0.0.1:18443` so the load script can target it without argv parsing.

Build optimized: `mojo build -I . benchmarks/http2_tls_server.mojo -o ...`
"""

from net import listen_tcp
from benchmarks.http_handler import BenchHandler
from net.http import Server, ServerConfig
from net.tls import TLSContext


def main() raises:
    var config = ServerConfig.default()
    var server = Server(config^)
    var listener = listen_tcp("127.0.0.1:18443")
    var tls_context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "h2",
    )
    var handler = BenchHandler()
    print("http2_tls_server listening on 127.0.0.1:18443 proto=https+h2")
    print(
        "fixed=",
        handler.fixed.byte_length(),
        "B json=",
        handler.json.byte_length(),
        "B",
    )
    server.serve_tls(listener^, tls_context^, handler)
