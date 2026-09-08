from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig


struct HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/hello":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string("hello, mojo http!")
        else:
            writer.set_status(404)
            writer.write_string("not found")


def _read_response(
    mut server: Server,
    mut handler: HelloHandler,
    client: TCPConn,
    max_ticks: Int = 300,
) raises -> List[Byte]:
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
    var handler = HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String("GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    var out = _read_response(server, handler, client)
    var text = String(from_utf8_lossy=Span(out))
    if text.find("HTTP/1.1 200 OK") < 0 or text.find("hello, mojo http!") < 0:
        raise Error("hello response mismatch: " + text)
    client.write_all(
        String(
            "GET /missing HTTP/1.1\r\nHost: example.com\r\nConnection:"
            " close\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    var missing = _read_response(server, handler, client)
    var missing_text = String(from_utf8_lossy=Span(missing))
    if missing_text.find("HTTP/1.1 404 Not Found") < 0:
        raise Error("404 response mismatch: " + missing_text)
    client.close()
    print("HTTP hello succeeded")
