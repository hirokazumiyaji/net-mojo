from std.testing import assert_equal, assert_true, TestSuite

from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    Handler,
    HijackSender,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)
from tests.support import _tick_n
from tests.test_http_hijack import (
    test_connect_success_requires_raw_takeover_in_all_response_paths,
)


struct _ConnectHandler(Handler):
    var sender: Optional[HijackSender]

    def __init__(out self):
        self.sender = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        assert_equal(request.method, "CONNECT")
        assert_equal(request.authority, "local:443")
        assert_equal(request.path, "")
        self.sender = writer.hijack()


def test_connect_raw_status_and_binary_surplus_echo() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var client = dial_tcp(address, Timeout.seconds(1))
    var request = List[Byte](
        "CONNECT local:443 HTTP/1.1\r\nHost: local:443\r\n\r\n".as_bytes()
    )
    var payload: Array[Byte, 4] = [0, 127, 128, 255]
    request.extend(Span(payload))
    client.write_all(Span(request), Timeout.seconds(1))
    var handler = _ConnectHandler()
    _tick_n(server, handler, 10)
    assert_true(handler.sender)
    assert_equal(server.active_connections(), 0)
    var connection = handler.sender.take().take_connection()
    var scratch = Array[Byte, 4](fill=0)
    assert_equal(connection.read(Span(scratch), Timeout.seconds(1)), 4)
    for index in range(4):
        assert_equal(scratch[index], payload[index])
    var response = List[Byte](
        "HTTP/1.1 200 Connection Established\r\n\r\n".as_bytes()
    )
    response.extend(Span(scratch))
    var sent = 0
    while sent < len(response):
        sent += connection.write(Span(response)[sent:], Timeout.seconds(1))
    var received = List[Byte]()
    var bytes = Array[Byte, 256](fill=0)
    while len(received) < len(response):
        var count = client.read(Span(bytes), Timeout.seconds(1))
        assert_true(count > 0)
        received.extend(Span(bytes)[0:count])
    assert_equal(len(received), len(response))
    for index in range(len(response)):
        assert_equal(received[index], response[index])
    assert_equal(server._budget.used(), 0)
    connection^.close()
    client.close()


def test_connect_rejects_non_authority_targets_and_body_framing() raises:
    for request in [
        "CONNECT / HTTP/1.1\r\nHost: local\r\n\r\n",
        "CONNECT https://local:443/ HTTP/1.1\r\nHost: local\r\n\r\n",
        "CONNECT local HTTP/1.1\r\nHost: local\r\n\r\n",
        (
            "CONNECT local:443 HTTP/1.1\r\nHost: local\r\nContent-Length:"
            " 0\r\n\r\n"
        ),
        (
            "CONNECT local:443 HTTP/1.1\r\nHost: local\r\nTransfer-Encoding:"
            " chunked\r\n\r\n0\r\n\r\n"
        ),
    ]:
        var server = Server(ServerConfig.default())
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var client = dial_tcp(address, Timeout.seconds(1))
        client.write_all(request.as_bytes(), Timeout.seconds(1))
        var handler = _ConnectHandler()
        _tick_n(server, handler, 10)
        assert_true(not handler.sender)
        var bytes = Array[Byte, 256](fill=0)
        var count = client.read(Span(bytes), Timeout.seconds(1))
        assert_true(
            String(from_utf8_lossy=Span(bytes)[0:count]).startswith(
                "HTTP/1.1 400"
            )
        )
        client.close()


def main() raises:
    test_connect_success_requires_raw_takeover_in_all_response_paths()
    TestSuite.discover_tests[__functions_in_module()]().run()
