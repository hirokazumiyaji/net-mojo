"""Own-loopback RFC 6455 echo fixture with one owner per adopted connection."""

from std.ffi import c_int, c_ulong, c_size_t, external_call
from std.os import getenv
from std.sys import size_of
from std.time import perf_counter_ns
from net import Timeout, listen_tcp
from net._actor import Mailbox
from net.http import (
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
)
from net.http.websocket import (
    WebSocketConfig,
    WebSocketUpgrade,
    websocket_accept,
    websocket_adopt,
)
from net.tls import TLSContext


@fieldwise_init
struct _Work:
    var upgrade: Optional[WebSocketUpgrade]
    var completion_addr: Int
    var index: UInt64


def _worker_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var work = arg.unsafe_bitcast[_Work]()
    var upgrade = work[].upgrade.take()
    var completion_addr = work[].completion_addr
    var index = work[].index
    work.unsafe_deinit_pointee()
    external_call["free", NoneType](arg)
    try:
        var ws = websocket_adopt(upgrade^)
        while not ws.is_closed():
            try:
                var message = ws.read_message()
                if message.opcode == 1:
                    ws.write_text(String(from_utf8_lossy=Span(message.payload)))
                else:
                    ws.write_binary(Span(message.payload))
            except:
                break
        ws^.close()
    except:
        pass
    var completed = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=completion_addr
    ).unsafe_bitcast[Mailbox[UInt64]]()
    _ = completed[].push(index)
    return completed.unsafe_bitcast[Byte]()


struct _FixtureHandler(Handler):
    var control: ServerControl
    var upgrades: List[WebSocketUpgrade]
    var stopping: Bool
    var conformance: Bool

    def __init__(out self, var control: ServerControl):
        self.control = control^
        self.upgrades = List[WebSocketUpgrade]()
        self.stopping = False
        self.conformance = getenv("WEBSOCKET_CONFORMANCE") == "1"

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if request.path == "/shutdown":
            writer.write("bye".as_bytes())
            writer.should_close = True
            self.control.request_shutdown()
            self.stopping = True
            return
        if request.path == "/health":
            writer.write("ok".as_bytes())
            return
        var config = WebSocketConfig.default()
        config.subprotocols.append(String("chat"))
        if self.conformance:
            config.max_message_bytes = 64 * 1024 * 1024
            config.max_frame_bytes = 64 * 1024 * 1024
            config.max_fragment_count = 1_000_000
            config.read_deadline = Timeout.nanoseconds(120_000_000_000)
            config.write_deadline = Timeout.nanoseconds(120_000_000_000)
        try:
            self.upgrades.append(websocket_accept(request, writer, config))
        except:
            writer.status = 400
            writer.should_close = True


def _join(handle: UInt64) raises:
    var result = external_call["pthread_join", c_int](
        c_ulong(handle), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    if Int(result) != 0:
        raise Error("WebSocket fixture pthread_join failed")


def main() raises:
    var config = ServerConfig.default()
    config.max_connections = 32
    var server = Server(config^)
    var control = server.control.copy()
    var listener = listen_tcp("127.0.0.1:0")
    var port = listener.local_address().port
    if getenv("WEBSOCKET_TRANSPORT") == "tls":
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
    var handler = _FixtureHandler(control^)
    var completed = Mailbox[UInt64]()
    var workers = Dict[UInt64, UInt64]()
    var next_index: UInt64 = 0
    print("READY", port)
    var deadline = perf_counter_ns() + 3_600_000_000_000
    while not handler.stopping or server.active_connections() > 0:
        if perf_counter_ns() >= deadline:
            break
        _ = server.tick(handler, Timeout.milliseconds(10))
        var finished = completed.pop_all()
        for index in finished:
            _join(workers[index])
            _ = workers.pop(index)
        while len(handler.upgrades) > 0:
            var upgrade = handler.upgrades.pop()
            if len(workers) >= 32:
                _ = upgrade^
                continue
            var allocation = external_call[
                "malloc", Pointer[Byte, MutUntrackedOrigin]
            ](c_size_t(size_of[_Work]()))
            if Int(allocation) == 0:
                raise Error("WebSocket worker allocation failed")
            var work = allocation.unsafe_bitcast[_Work]()
            work.unsafe_write(
                _Work(
                    Optional(upgrade^), Int(Pointer(to=completed)), next_index
                )
            )
            var handle: UInt64 = 0
            var result = external_call["pthread_create", c_int](
                Pointer(to=handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                _worker_entry,
                allocation,
            )
            if Int(result) != 0:
                work.unsafe_deinit_pointee()
                external_call["free", NoneType](allocation)
                raise Error("WebSocket fixture pthread_create failed")
            workers[next_index] = handle
            next_index += 1
    _ = server^
    for entry in workers.items():
        _join(entry.value)
