"""One loopback raw Upgrade exchange. WebSocket framing belongs to #236."""

from std.testing import assert_equal, assert_true
from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    Handler,
    Headers,
    HijackSender,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)


struct EchoHandler(Handler):
    var sender: Optional[HijackSender]

    def __init__(out self):
        self.sender = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        var upgrade = request.headers.get_first("Upgrade")
        if (
            request.method != "GET"
            or not upgrade
            or upgrade.value().lower() != "echo"
        ):
            writer.status = 405
            return
        var headers = Headers()
        headers.add(String("Connection"), String("Upgrade"))
        headers.add(String("Upgrade"), String("echo"))
        self.sender = writer.switch_protocols(headers^)


def main() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    var handler = EchoHandler()
    client.write_all(
        "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade:"
        " echo\r\n\r\necho".as_bytes(),
        Timeout.seconds(1),
    )
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(10))
        if handler.sender and server.active_connections() == 0:
            break
    assert_true(handler.sender)
    assert_equal(server.active_connections(), 0)
    var raw = handler.sender.take().take_connection()
    _ = server^
    var payload = Array[Byte, 4](fill=0)
    var offset = 0
    while offset < 4:
        var count = raw.read(Span(payload)[offset:], Timeout.seconds(1))
        assert_true(count > 0)
        offset += count
    offset = 0
    while offset < 4:
        offset += raw.write(Span(payload)[offset:], Timeout.seconds(1))
    raw.shutdown_write()
    raw^.close()
    var response = List[Byte]()
    var scratch = Array[Byte, 512](fill=0)
    while True:
        var count = client.read(Span(scratch), Timeout.seconds(1))
        if count == 0:
            break
        for index in range(count):
            response.append(scratch[index])
    var text = String(from_utf8_lossy=Span(response))
    assert_true(text.startswith("HTTP/1.1 101 Switching Protocols\r\n"))
    assert_true(text.endswith("\r\n\r\necho"))
    client.close()
    print("Raw Upgrade echo succeeded")
