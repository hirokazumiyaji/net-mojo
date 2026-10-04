from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns
from net import Timeout, listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.http._connection import H1_ERROR_CAPACITY
from net.tls import TLSContext


struct _InvalidAltSvcHandler(Handler):
    var arms: Int
    var arm_slot: Int
    var targets: Int
    var siblings: Int

    def __init__(out self):
        self.arms = 0
        self.arm_slot = -1
        self.targets = 0
        self.siblings = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/arm":
            self.arms += 1
            self.arm_slot = writer._slot
        elif req.path == "/error":
            self.targets += 1
            raise Error("configured Alt-Svc error fixture")
        elif req.path == "/normal":
            self.targets += 1
            writer.write_string("normal")
            return
        else:
            self.siblings += 1
        writer.headers.add(String("Alt-Svc"), String('h3=":9443"; ma=60'))
        writer.write_string("alive")


def main() raises:
    var bad_values = List[String]()
    bad_values.append(String('h3=":8443"\r\nX-Injected: yes'))
    bad_values.append(String('h3=":8443"\rX-Injected: yes'))
    bad_values.append(String('h3=":8443"\nX-Injected: yes'))
    bad_values.append(String('h3=":8443"') + chr(0) + String("injected"))
    bad_values.append(String('h3=":8443"') + chr(31) + String("injected"))
    bad_values.append(String('h3=":8443"') + chr(127) + String("injected"))
    for i in range(len(bad_values)):
        bad_values[i] += String("a") * (64 - bad_values[i].byte_length())
    var cases = 2 * len(bad_values) + 1
    var valid_value = String("a") * 64
    var config = ServerConfig.default()
    config.alt_svc = valid_value.copy()
    var server = Server(config^)
    var observer = server._budget.copy()
    assert_true(observer.try_reserve(5))
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
    var handler = _InvalidAltSvcHandler()
    var armed = 0
    var restored = 0
    var expires = Int(perf_counter_ns()) + 30_000_000_000
    while (
        handler.targets < cases
        or handler.siblings < cases + 1
        or server.active_connections() > 0
    ) and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.milliseconds(10))
        if handler.arms > armed:
            armed = handler.arms
            var idx = handler.arm_slot
            var capacity = server._conns[idx]._error_wire.capacity()
            var address = Int(server._conns[idx]._error_wire.unsafe_ptr())
            assert_equal(capacity, H1_ERROR_CAPACITY + 11 + 64)
            var value_index = (armed - 1) // 2
            if value_index == len(bad_values):
                value_index = 0
            server.config.alt_svc = bad_values[value_index].copy()
            assert_equal(server.config.alt_svc.byte_length(), 64)
            assert_equal(server._conns[idx]._error_wire.capacity(), capacity)
            assert_equal(
                Int(server._conns[idx]._error_wire.unsafe_ptr()), address
            )
        if handler.siblings > restored:
            restored = handler.siblings
            server.config.alt_svc = valid_value.copy()
    assert_equal(handler.arms, cases)
    assert_equal(handler.targets, cases)
    assert_equal(handler.siblings, cases + 1)
    assert_equal(server.active_connections(), 0)
    assert_equal(observer.used(), 5)
    _ = server^
    assert_equal(observer.used(), 5)
    observer.release(5)
    assert_equal(observer.used(), 0)
