"""HTTP/3 (QUIC ALPN h3) benchmark server matching the Go/H2 handlers.

Handlers (same shapes as `benchmarks/http_go/main.go` / `http2_tls_server.mojo`):
  - GET /fixed : 64 B `a` x 64, text/plain
  - GET /json  : exactly 1024 B application/json
  - POST /echo : echo request body (capped at 1 MiB)

Requires the quiche provider from `pixi run -e tls-http3 quic-build` and
TLS certs from `pixi run -e tls-http3 tls-build`. Listen address is fixed at
UDP `127.0.0.1:18453` so the load script can target it without argv parsing.

Build optimized: `mojo build -I . benchmarks/http3_server.mojo -o ...`
"""

from benchmarks.http_handler import BenchHandler
from net.http import Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var listener = listen_udp("127.0.0.1:18453")
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var endpoint = QuicUDPEndpoint(provider.server(quic_config^), listener^)
    var server = Server(ServerConfig.default())
    server.add_quic_endpoint(endpoint^)
    var handler = BenchHandler()
    print("http3_server listening on udp://127.0.0.1:18453 proto=h3")
    print(
        "fixed=",
        handler.fixed.byte_length(),
        "B json=",
        handler.json.byte_length(),
        "B",
    )
    while True:
        _ = server.tick(handler, None)
