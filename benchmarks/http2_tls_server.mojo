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
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


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
