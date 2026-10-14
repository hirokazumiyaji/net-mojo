"""A self-contained loopback WebSocket echo with an owned Upgrade handoff."""

from std.testing import assert_equal, assert_true
from net import Timeout, dial_tcp, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.http.websocket import (
    OPCODE_TEXT,
    WebSocketConfig,
    WebSocketUpgrade,
    websocket_accept,
    websocket_adopt,
)


struct EchoHandler(Handler):
    var upgrade: Optional[WebSocketUpgrade]

    def __init__(out self):
        self.upgrade = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if request.path != "/echo":
            writer.status = 404
            return
        var config = WebSocketConfig.default()
        config.subprotocols.append(String("chat"))
        self.upgrade = websocket_accept(request, writer, config)


def main() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    var handler = EchoHandler()
    client.write_all(
        "GET /echo HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
        "Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Protocol: chat\r\n\r\n".as_bytes(),
        Timeout.seconds(1),
    )
    var masked_hello: Array[Byte, 11] = [
        0x81,
        0x85,
        0x37,
        0xFA,
        0x21,
        0x3D,
        0x7F,
        0x9F,
        0x4D,
        0x51,
        0x58,
    ]
    client.write_all(Span(masked_hello), Timeout.seconds(1))
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(10))
        if handler.upgrade and server.active_connections() == 0:
            break
    assert_true(handler.upgrade)
    assert_equal(server.active_connections(), 0)
    # The loop has completed the handoff, so adoption cannot block its progress.
    _ = server^
    var ws = websocket_adopt(handler.upgrade.take())
    assert_equal(ws.selected_subprotocol(), "chat")
    var message = ws.read_message()
    assert_equal(message.opcode, OPCODE_TEXT)
    var text = String(from_utf8_lossy=Span(message.payload))
    assert_equal(text, "Hello")
    ws.write_text(text)
    var response = List[Byte]()
    var scratch = Array[Byte, 512](fill=0)
    while True:
        var count = client.read(Span(scratch), Timeout.seconds(1))
        assert_true(count > 0)
        response.extend(Span(scratch)[0:count])
        assert_true(len(response) <= 4096)
        var wire = String(from_utf8_lossy=Span(response))
        if "\r\n\r\n" in wire and wire.endswith("Hello"):
            break
    var wire = String(from_utf8_lossy=Span(response))
    assert_true(wire.startswith("HTTP/1.1 101 Switching Protocols\r\n"))
    var peer_close: Array[Byte, 8] = [
        0x88,
        0x82,
        1,
        2,
        3,
        4,
        2,
        0xEA,
    ]
    client.write_all(Span(peer_close), Timeout.seconds(1))
    ws^.close()
    client.close()
    print("WebSocket chat echo succeeded: Hello")
