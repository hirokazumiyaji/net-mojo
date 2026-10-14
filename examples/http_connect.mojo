"""One CONNECT exchange with an explicitly permitted local echo target."""

from std.testing import assert_equal, assert_true
from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    Handler,
    HijackSender,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)


struct ConnectHandler(Handler):
    var allowed_authority: String
    var sender: Optional[HijackSender]

    def __init__(out self, var allowed_authority: String):
        self.allowed_authority = allowed_authority^
        self.sender = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if (
            request.method != "CONNECT"
            or request.authority != self.allowed_authority
        ):
            writer.status = 405
            return
        self.sender = writer.hijack()


def main() raises:
    var target_listener = listen_tcp("127.0.0.1:0")
    var target = String(target_listener.local_address())
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    var handler = ConnectHandler(target.copy())
    var request = (
        String("CONNECT ")
        + target
        + String(" HTTP/1.1\r\nHost: localhost\r\n\r\necho")
    )
    client.write_all(request.as_bytes(), Timeout.seconds(1))
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(10))
        if handler.sender and server.active_connections() == 0:
            break
    assert_true(handler.sender)
    assert_equal(server.active_connections(), 0)
    var raw = handler.sender.take().take_connection()
    _ = server^
    var upstream = dial_tcp(target, Timeout.seconds(1))
    var target_peer = target_listener.accept(Timeout.seconds(1))
    var head = "HTTP/1.1 200 Connection Established\r\n\r\n".as_bytes()
    var offset = 0
    while offset < len(head):
        offset += raw.write(head[offset:], Timeout.seconds(1))
    var payload = Array[Byte, 4](fill=0)
    offset = 0
    while offset < 4:
        var count = raw.read(Span(payload)[offset:], Timeout.seconds(1))
        assert_true(count > 0)
        offset += count
    upstream.write_all(Span(payload), Timeout.seconds(1))
    offset = 0
    while offset < 4:
        var count = target_peer.read(Span(payload)[offset:], Timeout.seconds(1))
        assert_true(count > 0)
        offset += count
    target_peer.write_all(Span(payload), Timeout.seconds(1))
    offset = 0
    while offset < 4:
        var count = upstream.read(Span(payload)[offset:], Timeout.seconds(1))
        assert_true(count > 0)
        offset += count
    offset = 0
    while offset < 4:
        offset += raw.write(Span(payload)[offset:], Timeout.seconds(1))
    raw.shutdown_write()
    raw^.close()
    var response = List[Byte]()
    var scratch = Array[Byte, 128](fill=0)
    while True:
        var count = client.read(Span(scratch), Timeout.seconds(1))
        if count == 0:
            break
        for index in range(count):
            response.append(scratch[index])
    assert_equal(
        String(from_utf8_lossy=Span(response)),
        String("HTTP/1.1 200 Connection Established\r\n\r\necho"),
    )
    upstream.close()
    target_peer.close()
    target_listener.close()
    client.close()
    print("Loopback CONNECT echo succeeded")
