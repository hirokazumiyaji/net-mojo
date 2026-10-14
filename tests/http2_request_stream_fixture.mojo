from std.ffi import c_int, c_ulong, external_call
from std.memory import ArcPointer, OwnedPointer
from std.time import perf_counter_ns, sleep
from std.testing import assert_equal, assert_true
from net import Timeout, listen_tcp
from net._actor import PthreadMutex
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    Request,
    RequestBodyEndpoints,
    RequestBodyReceiver,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.tls import TLSContext


struct _State(Movable):
    var mutex: PthreadMutex
    var gate: Bool
    var count: Int
    var checksum: Int
    var done: Bool
    var cancelled: Bool
    var failed: Bool
    var premature_trailers: Bool
    var trailer: String

    def __init__(out self, gate: Bool):
        self.mutex = PthreadMutex._uninitialized()
        self.gate = gate
        self.count = 0
        self.checksum = 0
        self.done = False
        self.cancelled = False
        self.failed = False
        self.premature_trailers = False
        self.trailer = String()

    def __deinit__(deinit self):
        self.mutex.destroy()


@fieldwise_init
struct _Work(Movable):
    var endpoints: RequestBodyEndpoints
    var state: ArcPointer[_State]
    var early: Bool


def _consume(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var work = arg.unsafe_bitcast[_Work]()
    var state = work[].state.copy()
    var buffer = Array[Byte, 1024](fill=0)
    try:
        if work[].early:
            work[].endpoints.sender.respond(
                200, Headers(), List[Byte]("early".as_bytes())
            )
        var gate_deadline = perf_counter_ns() + 3_000_000_000
        while True:
            state[].mutex.lock()
            var released = state[].gate
            state[].mutex.unlock()
            if released or perf_counter_ns() >= gate_deadline:
                break
            sleep(0.001)
        if not work[].endpoints.receiver.is_eof():
            try:
                _ = work[].endpoints.receiver.trailers()
                state[].mutex.lock()
                state[].premature_trailers = True
                state[].mutex.unlock()
            except error:
                if (
                    error.kind != NetErrorKind.invalid_state()
                    and error.kind != NetErrorKind.cancelled()
                ):
                    raise error^
        while True:
            var count = work[].endpoints.receiver.receive(
                Span(buffer), Timeout.seconds(2)
            )
            if count == 0:
                break
            var checksum = 0
            for i in range(count):
                checksum += Int(buffer[i])
            state[].mutex.lock()
            state[].count += count
            state[].checksum += checksum
            state[].mutex.unlock()
        var trailers = work[].endpoints.receiver.trailers()
        state[].mutex.lock()
        if trailers.get_first("x-end"):
            state[].trailer = trailers.get_first("x-end").value().copy()
        var total = state[].count
        state[].mutex.unlock()
        if not work[].early:
            work[].endpoints.sender.respond(
                200, Headers(), List[Byte](String(total).as_bytes())
            )
        state[].mutex.lock()
        state[].done = True
        state[].mutex.unlock()
    except error:
        state[].mutex.lock()
        state[].cancelled = error.kind == NetErrorKind.cancelled()
        state[].failed = not state[].cancelled
        state[].done = True
        state[].mutex.unlock()
    return arg


@fieldwise_init
struct _StandaloneWork(Movable):
    var receiver: RequestBodyReceiver
    var state: ArcPointer[_State]


def _consume_standalone(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var work = arg.unsafe_bitcast[_StandaloneWork]()
    var buffer = Array[Byte, 1024](fill=0)
    try:
        while True:
            var count = work[].receiver.receive(
                Span(buffer), Timeout.seconds(2)
            )
            if count == 0:
                break
            work[].state[].mutex.lock()
            work[].state[].count += count
            work[].state[].mutex.unlock()
    except error:
        work[].state[].mutex.lock()
        work[].state[].failed = True
        work[].state[].cancelled = error.kind == NetErrorKind.cancelled()
        work[].state[].mutex.unlock()
    work[].state[].mutex.lock()
    work[].state[].done = True
    work[].state[].mutex.unlock()
    return arg


struct _StreamingHandler(Handler):
    var shutdown: Bool
    var work: List[OwnedPointer[_Work]]
    var threads: List[UInt64]
    var standalone_work: List[OwnedPointer[_StandaloneWork]]

    def __init__(out self):
        self.shutdown = False
        self.work = List[OwnedPointer[_Work]]()
        self.threads = List[UInt64]()
        self.standalone_work = List[OwnedPointer[_StandaloneWork]]()

    def __deinit__(deinit self):
        for i in range(len(self.work)):
            self.work[i][].state[].mutex.lock()
            self.work[i][].state[].gate = True
            self.work[i][].state[].mutex.unlock()
        for i in range(len(self.threads)):
            _ = external_call["pthread_join", c_int](
                c_ulong(self.threads[i]),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
        # Context ownership must outlive every joined worker.
        _ = len(self.work)
        _ = len(self.standalone_work)

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/standalone-status":
            ref state = self.standalone_work[
                len(self.standalone_work) - 1
            ][].state[]
            state.mutex.lock()
            var count = state.count
            var done = state.done
            var failed = state.failed
            state.mutex.unlock()
            if failed:
                writer.write_string("failed")
            elif done:
                writer.write_string(String(count))
            else:
                writer.write_string("waiting")
            return
        if req.path == "/standalone":
            var reader = req.body_reader()
            var state = ArcPointer(_State(True))
            state[].mutex._initialize()
            self.standalone_work.append(
                OwnedPointer(_StandaloneWork(reader.detach(), state^))
            )
            var thread: UInt64 = 0
            var result = external_call["pthread_create", c_int](
                Pointer(to=thread),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                _consume_standalone,
                Pointer(
                    to=self.standalone_work[len(self.standalone_work) - 1][]
                ).unsafe_bitcast[Byte](),
            )
            assert_equal(Int(result), 0)
            self.threads.append(thread)
            writer.write_string("standalone")
            return
        if req.path == "/response-only":
            var sender = writer.detach()
            sender.respond(
                200, Headers(), List[Byte]("response only".as_bytes())
            )
            return
        if req.path == "/ignore":
            writer.write_string("ignored")
            return
        if req.path == "/sibling":
            writer.write_string("sibling ok")
            return
        if req.path == "/shutdown":
            self.shutdown = True
            writer.write_string("shutdown")
            return
        if req.path == "/status" or req.path == "/release":
            if len(self.work) == 0:
                writer.write_string("missing")
                return
            ref work = self.work[len(self.work) - 1][]
            ref state = work.state[]
            state.mutex.lock()
            if req.path == "/release":
                state.gate = True
            var value = (
                String(state.count)
                + ","
                + String(state.checksum)
                + ","
                + String(Int(state.done))
                + ","
                + String(Int(state.cancelled))
                + ","
                + String(Int(work.endpoints.sender.is_cancelled()))
                + ","
                + String(Int(state.premature_trailers))
                + ","
                + state.trailer
            )
            state.mutex.unlock()
            value += (
                ","
                + String(work.endpoints.receiver._pipe.pending_bytes())
                + ","
                + String(work.endpoints.receiver.total_decoded())
            )
            state.mutex.lock()
            value += "," + String(Int(state.failed))
            state.mutex.unlock()
            writer.write_string(value)
            return
        var state = ArcPointer(_State(req.path != "/hold"))
        state[].mutex._initialize()
        self.work.append(
            OwnedPointer(
                _Work(
                    writer.detach_with_body(req),
                    state.copy(),
                    req.path == "/early",
                )
            )
        )
        var thread: UInt64 = 0
        var result = external_call["pthread_create", c_int](
            Pointer(to=thread),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _consume,
            Pointer(to=self.work[len(self.work) - 1][]).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(result), 0)
        self.threads.append(thread)


def main() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    config.body_deadline = Timeout.milliseconds(600)
    config.detached_response_timeout = Timeout.seconds(5)
    config.shutdown_grace = Timeout.milliseconds(300)
    config.http2_max_control_frames_per_second = 100000
    var server = Server(config^)
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2",
        ),
    )
    print(String("READY ") + String(server.local_address().port))
    var handler = _StreamingHandler()
    while not handler.shutdown:
        _ = server.tick(handler, Timeout.seconds(2))
    server.request_shutdown()
    while server.tick(handler, Timeout.seconds(2)):
        pass
    assert_equal(server.active_connections(), 0)
    for i in range(len(handler.threads)):
        assert_equal(
            Int(
                external_call["pthread_join", c_int](
                    c_ulong(handler.threads[i]),
                    Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                )
            ),
            0,
        )
    handler.threads.clear()
    ref terminal_work = handler.work[len(handler.work) - 1][]
    ref terminal = terminal_work.state[]
    assert_true(terminal.done)
    assert_true(terminal.cancelled)
    assert_true(terminal_work.endpoints.sender.is_cancelled())
