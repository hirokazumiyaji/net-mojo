"""Equal handler work for the HTTP/1, HTTP/2 and HTTP/3 benchmarks."""

from net.http import Handler, Request, ResponseWriter


def _fixed_body() -> String:
    return String(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )


def _json_body() -> String:
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
