"""Independent HTTP event loops sharing one listening socket.

ServerConfig bounds apply to each worker. A factory creates each worker's
handler before any threads start; serve joins every thread before returning.
"""

from std.ffi import c_int, c_ulong, external_call

from net import SocketAddress, TCPListener, listen_tcp
from net._actor import PthreadMutex
from net._sys.common import _online_cpu_count, _system_error
from net.error import NetError, NetErrorKind
from net.tls import TLSContext
from net.quic import QuicUDPEndpoint
from ._control import ServerControl
from .config import ServerConfig
from .handler import Handler, HandlerFactory
from .server import Server


struct _WorkerFailure(Movable):
    var mutex: PthreadMutex
    var first: Optional[Error]

    def __init__(out self):
        self.mutex = PthreadMutex._uninitialized()
        self.first = None

    def __deinit__(deinit self):
        self.mutex.destroy()

    def record(mut self, var error: Error):
        self.mutex.lock()
        if not self.first:
            self.first = error^
        self.mutex.unlock()


@fieldwise_init
struct _WorkerContext[H: Handler & Deinitable](Movable):
    var server: Server
    var handler: Self.H
    var failure: Pointer[_WorkerFailure, MutUntrackedOrigin]


def _worker_entry[
    H: Handler & Deinitable
](arg: Pointer[Byte, MutUntrackedOrigin],) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_WorkerContext[H]]()
    try:
        context[].server._run(context[].handler)
    except error:
        context[].failure[].record(error^)
        context[].server._finish_control()
    return arg


def _start_worker[
    H: Handler & Deinitable
](mut context: _WorkerContext[H],) raises -> UInt64:
    var thread: UInt64 = 0
    var result = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _worker_entry[H],
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    if result != 0:
        raise _system_error("pthread_create", result)
    return thread


def _join_workers(threads: List[UInt64]):
    for thread in threads:
        _ = external_call["pthread_join", c_int](
            c_ulong(thread), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
        )


def _run_workers[
    H: Handler & Deinitable
](
    mut contexts: List[_WorkerContext[H]],
    control: ServerControl,
    mut failure: _WorkerFailure,
) raises:
    var threads = List[UInt64]()
    for i in range(len(contexts)):
        try:
            threads.append(_start_worker(contexts[i]))
        except error:
            failure.record(error^)
            control.request_shutdown()
            break
    _join_workers(threads)
    if failure.first:
        raise failure.first.value().copy()


def _worker_count(requested: Int) -> Int:
    var count = _online_cpu_count() if requested == 0 else requested
    return min(1024, max(1, count))


struct ServerPool(Movable):
    """One listener, independent handlers/reactors, and broadcast shutdown."""

    var _config: ServerConfig
    var _workers: Int
    var _control: ServerControl
    var _listener: Optional[TCPListener]
    var _tls_context: Optional[TLSContext]
    var _quic_endpoint: Optional[QuicUDPEndpoint]
    var _started: Bool

    def __init__(out self, var config: ServerConfig, workers: Int = 0) raises:
        self._config = config^
        self._workers = _worker_count(workers)
        self._control = ServerControl()
        self._listener = None
        self._tls_context = None
        self._quic_endpoint = None
        self._started = False

    def __deinit__(deinit self):
        self._control.mark_exited()

    def worker_count(self) -> Int:
        """Configured TCP worker count; a QUIC-only pool runs worker zero."""
        return self._workers

    def control(self) -> ServerControl:
        return self._control.copy()

    def add_listener(mut self, var listener: TCPListener) raises:
        if self._started or self._listener:
            raise NetError(
                NetErrorKind.invalid_state(),
                "pool add listener",
                None,
                "pool already started or has a listener",
            )
        self._listener = listener^

    def add_tls_listener(
        mut self,
        var listener: TCPListener,
        var tls_context: TLSContext,
    ) raises:
        self.add_listener(listener^)
        self._tls_context = tls_context^

    def add_quic_endpoint(mut self, var endpoint: QuicUDPEndpoint) raises:
        if self._started or self._quic_endpoint:
            raise NetError(
                NetErrorKind.invalid_state(),
                "pool add QUIC endpoint",
                None,
                "pool already started or has a QUIC endpoint",
            )
        self._quic_endpoint = endpoint^

    def _prepare_workers[
        F: HandlerFactory
    ](
        mut self,
        mut factory: F,
        failure: Pointer[_WorkerFailure, MutUntrackedOrigin],
    ) raises -> List[_WorkerContext[F.HandlerType]]:
        var contexts = List[_WorkerContext[F.HandlerType]]()
        var active_workers = self._workers if self._listener else 1
        for worker_id in range(active_workers):
            var server = Server(self._config.copy())
            server._set_control(self._control)
            var handler = factory.build(worker_id)
            if self._listener:
                var listener = self._listener.value()._duplicate()
                if self._tls_context:
                    server.add_tls_listener(
                        listener^, self._tls_context.value()._duplicate()
                    )
                else:
                    server.add_listener(listener^)
            if worker_id == 0 and self._quic_endpoint:
                server.add_quic_endpoint(self._quic_endpoint.take())
            contexts.append(
                _WorkerContext[F.HandlerType](server^, handler^, failure)
            )
        self._listener = None
        self._tls_context = None
        return contexts^

    def local_address(self) raises NetError -> SocketAddress:
        if not self._listener:
            raise NetError(
                NetErrorKind.invalid_state(),
                "pool local address",
                None,
                "pool has no listener",
            )
        return self._listener.value().local_address()

    def serve[F: HandlerFactory](mut self, mut factory: F) raises:
        if self._started or (not self._listener and not self._quic_endpoint):
            raise NetError(
                NetErrorKind.invalid_state(),
                "pool serve",
                None,
                "pool already started or has no listener or QUIC endpoint",
            )
        self._started = True
        var failure = _WorkerFailure()
        failure.mutex._initialize()
        var failure_ptr = Pointer[_WorkerFailure, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=failure))
        )
        try:
            var contexts = self._prepare_workers(factory, failure_ptr)
            _run_workers(contexts, self._control, failure)
            contexts.clear()
        except error:
            self._listener = None
            self._tls_context = None
            self._quic_endpoint = None
            self._control.request_shutdown()
            raise error


def listen_and_serve_pool[
    F: HandlerFactory
](
    address: StringSlice,
    var config: ServerConfig,
    mut factory: F,
    workers: Int = 0,
) raises:
    var pool = ServerPool(config^, workers)
    pool.add_listener(listen_tcp(address))
    pool.serve(factory)
