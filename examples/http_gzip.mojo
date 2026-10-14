from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    CompressionConfig,
    CompressionHandler,
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)


def _json_body() -> String:
    var body = String('{"items":[')
    for i in range(128):
        if i > 0:
            body += ","
        body += '{"id":' + String(i) + ',"description":"public example data"}'
    body += "]}"
    return body^


struct JsonHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.method != "GET" or req.path != "/json":
            writer.set_status(404)
            return
        writer.headers.add("Content-Type", "application/json")
        writer.write_string(_json_body())


def _round_trip[
    H: Handler
](mut server: Server, mut app: H, encoding: StringSlice) raises -> List[Byte]:
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(2))
    var request = (
        String("GET /json HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: ")
        + String(encoding)
        + "\r\nConnection: close\r\n\r\n"
    )
    client.write_all(request.as_bytes(), Timeout.seconds(2))
    var response = List[Byte]()
    var scratch = Array[Byte, 8192](fill=0)
    var closed = False
    for _ in range(300):
        _ = server.tick(app, Timeout.milliseconds(1))
        try:
            var count = client.try_read(Span(scratch))
            if count == 0:
                closed = True
                break
            for i in range(count):
                response.append(scratch[i])
        except error:
            _ = error
    client.close()
    if not closed:
        raise Error("gzip example response did not complete")
    return response^


def main() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var app = CompressionHandler[JsonHandler](
        JsonHandler(),
        CompressionConfig.default(),
        Optional[String]("build/compression/libnet_zlib"),
    )
    var compressed = _round_trip(server, app, "gzip")
    var text = String(from_utf8_lossy=Span(compressed))
    var body_offset = text.find("\r\n\r\n") + 4
    if (
        not text.startswith("HTTP/1.1 200 OK")
        or text.find("Content-Encoding: gzip") < 0
    ):
        raise Error("gzip response headers mismatch")
    if body_offset < 4 or len(compressed) < body_offset + 2:
        raise Error("gzip response body missing")
    if compressed[body_offset] != Byte(0x1F) or compressed[
        body_offset + 1
    ] != Byte(0x8B):
        raise Error("gzip response magic mismatch")
    var wire_size = len(compressed) - body_offset
    var source_size = _json_body().byte_length()
    if wire_size >= source_size:
        raise Error("public JSON response was not compressed")
    var identity = _round_trip(server, app, "gzip;q=0")
    var identity_text = String(from_utf8_lossy=Span(identity))
    if (
        identity_text.find("Content-Encoding:") >= 0
        or identity_text.find(_json_body()) < 0
    ):
        raise Error("identity negotiation did not preserve JSON")
    print(
        "gzip JSON example succeeded: "
        + String(source_size)
        + " source bytes, "
        + String(wire_size)
        + " gzip bytes"
    )
