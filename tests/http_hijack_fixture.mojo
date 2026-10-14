from std.os import getenv
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.http import (
    Handler,
    Headers,
    HijackSender,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.tls import TLSContext


struct _FixtureHandler(Handler):
    var sender: Optional[HijackSender]
    var target: String

    def __init__(out self, var target: String):
        self.sender = None
        self.target = target^

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if request.method == "CONNECT":
            if request.authority != self.target:
                writer.status = 403
                writer.should_close = True
                return
            self.sender = writer.hijack()
        else:
            var headers = Headers()
            headers.add(String("Connection"), String("Upgrade"))
            headers.add(String("Upgrade"), String("echo"))
            self.sender = writer.switch_protocols(headers^)


def main() raises:
    var config = ServerConfig.default()
    config.max_connections = 1
    var server = Server(config^)
    var listener = listen_tcp("127.0.0.1:0")
    var port = listener.local_address().port
    if getenv("HIJACK_TRANSPORT") == "tls":
        server.add_tls_listener(
            listener^,
            TLSContext.server(
                "build/tls/libnet_tls",
                "build/tls/test-cert.pem",
                "build/tls/test-key.pem",
                "http/1.1",
            ),
        )
    else:
        server.add_listener(listener^)
    var target = String("127.0.0.1:") + getenv("HIJACK_TARGET_PORT")
    var handler = _FixtureHandler(target.copy())
    print("READY", port)
    var deadline = Int(perf_counter_ns()) + 5_000_000_000
    while (not handler.sender or server.active_connections() != 0) and Int(
        perf_counter_ns()
    ) < deadline:
        _ = server.tick(handler, Timeout.milliseconds(10))
    assert_true(handler.sender)
    assert_equal(server.active_connections(), 0)
    var connection = handler.sender.take().take_connection()
    assert_equal(server._budget.used(), 0)
    _ = server^
    var connecting = getenv("HIJACK_METHOD") == "connect"
    var upstream: Optional[TCPConn] = None
    if connecting:
        upstream = dial_tcp(target, Timeout.seconds(5))
        var status = "HTTP/1.1 200 Connection Established\r\n\r\n".as_bytes()
        var sent = 0
        while sent < len(status):
            sent += connection.write(status[sent:], Timeout.seconds(5))
    var bytes = List[Byte]()
    var scratch = Array[Byte, 1](fill=0)
    while len(bytes) < 10:
        var count = connection.read(Span(scratch), Timeout.seconds(5))
        assert_equal(count, 1)
        bytes.append(scratch[0])
    if connecting:
        upstream.value().write_all(Span(bytes), Timeout.seconds(5))
        var echo = Array[Byte, 10](fill=0)
        var offset = 0
        while offset < 10:
            var count = upstream.value().read(
                Span(echo)[offset:], Timeout.seconds(5)
            )
            assert_true(count > 0)
            offset += count
        for index in range(10):
            assert_equal(echo[index], bytes[index])
        upstream.value().close()
    var sent = 0
    while sent < len(bytes):
        sent += connection.write(Span(bytes)[sent:], Timeout.seconds(5))
    connection.shutdown_write()
    connection^.close()
    print("DONE")
