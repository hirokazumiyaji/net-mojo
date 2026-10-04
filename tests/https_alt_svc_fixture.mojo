from std.testing import assert_equal, assert_true
from net.http._connection import H1_ERROR_CAPACITY, STATE_READING
from net.http._deadline import now_ns
from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.tls import TLSContext


struct _AltSvcHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        if req.path == "/error":
            raise Error("test error response")
        writer.set_status(200)
        writer.set_should_close(True)
        if req.path == "/custom":
            writer.headers.add(String("Alt-Svc"), String('h3=":9443"; ma=60'))
        writer.write_string("alt-svc ok")


def main() raises:
    var config = ServerConfig.default()
    config.alt_svc = (
        String('h3=":8443"; ma=86400; x="') + String("a") * 300 + String('"')
    )
    var server = Server(config^)
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "http/1.1",
        ),
    )
    print(String("READY ") + String(server.local_address().port))
    var handler = _AltSvcHandler()
    var observer = server._budget.copy()
    var grown = False
    while handler.requests < 5:
        server._accept_pending(now_ns())
        if handler.requests == 4 and not grown:
            for idx in range(len(server._conns)):
                if (
                    server._conns[idx].active
                    and server._conns[idx].state == STATE_READING
                ):
                    var capacity = server._conns[idx]._error_wire.capacity()
                    var address = Int(
                        server._conns[idx]._error_wire.unsafe_ptr()
                    )
                    assert_equal(
                        capacity,
                        H1_ERROR_CAPACITY
                        + 11
                        + server.config.alt_svc.byte_length(),
                    )
                    server.config.alt_svc += String("b") * 512
                    assert_equal(
                        server._conns[idx]._error_wire.capacity(), capacity
                    )
                    assert_equal(
                        Int(server._conns[idx]._error_wire.unsafe_ptr()),
                        address,
                    )
                    grown = True
        _ = server.tick(handler, Timeout.seconds(2))
    assert_true(grown)
    while server.active_connections() > 0:
        _ = server.tick(handler, Timeout.seconds(2))

    assert_equal(observer.used(), 0)
