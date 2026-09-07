from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig


def _json_body() -> String:
    var body = String('{"message":"hello, mojo http json","ok":true,"data":[')
    for i in range(64):
        if i > 0:
            body += ","
        body += '{"id":' + String(i) + ',"tag":"item-' + String(i) + '"}'
    body += "]}"
    return body^


struct JsonHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.method == "GET" and req.path == "/json":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/json")
            )
            writer.write_string(_json_body())
        elif req.method == "POST" and req.path == "/echo":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/octet-stream")
            )
            for i in range(len(req.body)):
                writer.body.append(req.body[i])
        else:
            writer.set_status(404)
            writer.write_string("not found")


def _round_trip(
    mut server: Server,
    mut handler: JsonHandler,
    client: TCPConn,
    request: String,
    max_ticks: Int = 300,
) raises -> List[Byte]:
    client.write_all(request.as_bytes(), Timeout.seconds(2))
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
        except e:
            _ = e
            continue
    return out^


def main() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = JsonHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var get = _round_trip(
        server,
        handler,
        client,
        "GET /json HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n",
    )
    var get_text = String(from_utf8_lossy=Span(get))
    if get_text.find("HTTP/1.1 200 OK") < 0:
        raise Error("json status mismatch")
    if get_text.find("application/json") < 0:
        raise Error("json content-type mismatch")
    if get_text.find(_json_body()) < 0:
        raise Error("json body mismatch")
    client.close()
    print("HTTP json succeeded")
