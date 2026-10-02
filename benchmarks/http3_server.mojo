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

from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp


def _fixed_body() -> String:
    return String(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )


def _json_body() -> String:
    # Same layout as benchmarks/http_go/main.go, padded to exactly 1024 B.
    var pad = String(
        '"pad":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",'
    )
    var body = (
        String("{")
        + String('"id":1234567890,')
        + String('"name":"net-mojo baseline payload",')
        + String(
            '"tags":["http","benchmark","baseline","mojo","go","server","api","test"],'
        )
        + String('"nested":{"a":1,"b":2,"c":3,"d":4,"e":5},')
        + pad
        + pad
        + pad
        + pad
        + pad
        + pad
        + pad
        + pad
        + String('"ok":true}')
    )
    var n = body.byte_length()
    if n < 1024:
        body = body + String(" ") * (1024 - n)
    return body^


struct BenchHandler(Handler):
    var fixed: String
    var json: String

    def __init__(out self) raises:
        self.fixed = _fixed_body()
        self.json = _json_body()

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.method == "GET" and req.path == "/fixed":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string(self.fixed)
            return
        if req.method == "GET" and req.path == "/json":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/json")
            )
            writer.write_string(self.json)
            return
        if req.method == "POST" and req.path == "/echo":
            var max_body = 1 << 20
            if len(req.body) > max_body:
                writer.set_status(413)
                writer.write_string("Content Too Large")
                return
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/octet-stream")
            )
            writer.write(Span(req.body))
            return
        writer.set_status(404)
        writer.write_string("not found")


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
