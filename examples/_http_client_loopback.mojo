from std.ffi import c_int, c_ulong, external_call
from std.memory import ArcPointer
from net import Timeout, listen_tcp
from net.http import (
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
)
from net.tls import TLSContext


struct _LoopbackHandler(Handler):
    var payload: String
    var requests: Int

    def __init__(out self, var payload: String):
        self.payload = payload^
        self.requests = 0

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        self.requests += 1
        if request.method == "POST":
            writer.write(Span(request.body))
        else:
            writer.write_string(self.payload)


struct _LoopbackState(Movable):
    var server: Server
    var handler: _LoopbackHandler
    var failed: Bool

    def __init__(out self, var server: Server, var payload: String):
        self.server = server^
        self.handler = _LoopbackHandler(payload^)
        self.failed = False


def _serve(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var state = arg.unsafe_bitcast[_LoopbackState]()
    try:
        while state[].server.tick(
            state[].handler, Timeout.nanoseconds(10000000)
        ):
            pass
    except:
        state[].failed = True
    return arg


struct _LoopbackHTTPServer(Movable):
    var _state: ArcPointer[_LoopbackState]
    var _control: ServerControl
    var _thread: UInt64
    var _joined: Bool
    var url: String

    def __init__(
        out self, var payload: String, var tls: Optional[TLSContext] = None
    ) raises:
        var config = ServerConfig.default()
        config.shutdown_grace = Timeout.seconds(1)
        var server = Server(config^)
        var listener = listen_tcp("127.0.0.1:0")
        var port = listener.local_address().port
        if tls:
            server.add_tls_listener(listener^, tls.take())
            self.url = String("https://localhost:") + String(port)
        else:
            server.add_listener(listener^)
            self.url = String("http://127.0.0.1:") + String(port)
        self._control = server.control.copy()
        self._state = ArcPointer(_LoopbackState(server^, payload^))
        self._thread = 0
        self._joined = True
        var result = external_call["pthread_create", c_int](
            Pointer(to=self._thread),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _serve,
            Pointer(to=self._state[]).unsafe_bitcast[Byte](),
        )
        if result != 0:
            raise Error("could not start loopback HTTP server")
        self._joined = False

    def finish(mut self) raises -> Int:
        self._control.request_shutdown()
        if not self._joined:
            var result = external_call["pthread_join", c_int](
                c_ulong(self._thread),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
            self._joined = True
            if result != 0:
                raise Error("could not join loopback HTTP server")
        if self._state[].failed:
            raise Error("loopback HTTP server failed")
        return self._state[].handler.requests

    def __deinit__(deinit self):
        self._control.request_shutdown()
        if not self._joined:
            _ = external_call["pthread_join", c_int](
                c_ulong(self._thread),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
        _ = self._state^
