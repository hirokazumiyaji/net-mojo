"""Connection leases keep pool ownership independent of Client lifetime."""

from std.ffi import c_int, c_size_t
from std.memory import ArcPointer
from std.time import perf_counter_ns
from net import TCPConn
from net._actor import PthreadMutex
from net._stream import _read_with_deadline, _write_all_loop
from net.error import NetError, NetErrorKind, _timeout_error
from net.tls import TLSConnection, TLSProgress
from net._sys.common import _wait_readable, _wait_writable
from net.timeout import Timeout, _Deadline
from .client_error import ClientError
from .client_config import ClientConfig
from ._url import ParsedUrl


def _client_transport(kind: UInt8, var error: NetError) -> ClientError:
    var resolved = kind
    if error.is_timeout():
        resolved = ClientError.TIMEOUT
    return ClientError(resolved, error.message.copy(), error^)


def _phase_deadline(overall: _Deadline, timeout: Timeout) -> _Deadline:
    var phase = _Deadline.from_timeout(timeout)
    if overall._expires_at:
        if overall._expires_at.value() < phase._expires_at.value():
            return overall.copy()
    return phase^


def _wait_client_tls(
    connection: TLSConnection, progress: TLSProgress, deadline: _Deadline
) raises NetError:
    var ready: Bool
    if progress.is_wants_read():
        ready = _wait_readable(connection.raw_fd(), deadline)
    else:
        ready = _wait_writable(connection.raw_fd(), deadline)
    if not ready:
        raise _timeout_error("TLS I/O")


struct _ClientConnection(Movable):
    var tcp: Optional[TCPConn]
    var tls: Optional[TLSConnection]

    def __init__(out self, var tcp: TCPConn):
        self.tcp = tcp^
        self.tls = None

    def __init__(out self, var tls: TLSConnection):
        self.tcp = None
        self.tls = tls^

    def handshake(mut self, deadline: _Deadline) raises ClientError:
        try:
            while True:
                if deadline.expired():
                    raise _timeout_error("TLS handshake")
                var progress = self.tls.value().handshake()
                if progress.is_complete():
                    break
                _wait_client_tls(self.tls.value(), progress, deadline)
            var alpn = Array[Byte, 256](fill=0)
            var count = self.tls.value()._library.call[
                "net_tls_selected_alpn", c_int
            ](self.tls.value()._session, alpn.unsafe_ptr(), c_size_t(255))
            if count < 0 or (
                count > 0
                and String(from_utf8_lossy=Span(alpn)[: Int(count)])
                != "http/1.1"
            ):
                raise NetError(
                    NetErrorKind.unsupported(),
                    "TLS ALPN",
                    None,
                    "peer selected an unsupported application protocol",
                )
        except error:
            raise _client_transport(ClientError.TLS, error^)

    def _tls_read[
        origin: MutOrigin
    ](
        mut self, buf: Span[mut=True, Byte, origin], deadline: _Deadline
    ) raises NetError -> Int:
        while True:
            if deadline.expired():
                raise _timeout_error("TLS read")
            var result = self.tls.value().try_read(buf)
            if result.progress.is_complete():
                return result.count
            if result.progress.is_closed():
                return 0
            _wait_client_tls(self.tls.value(), result.progress, deadline)

    def _tls_write_all[
        origin: ImmOrigin
    ](mut self, buf: Span[Byte, origin], deadline: _Deadline) raises NetError:
        var sent = 0
        while sent < len(buf):
            if deadline.expired():
                raise _timeout_error("TLS write")
            var result = self.tls.value().try_write(buf[sent:])
            if result.progress.is_complete():
                sent += result.count
            elif result.progress.is_closed():
                raise NetError(
                    NetErrorKind.closed(),
                    "TLS write",
                    None,
                    "TLS peer closed the connection",
                )
            else:
                _wait_client_tls(self.tls.value(), result.progress, deadline)

    def read[
        origin: MutOrigin
    ](
        mut self, buf: Span[mut=True, Byte, origin], deadline: _Deadline
    ) raises ClientError -> Int:
        if deadline.expired():
            raise ClientError(
                ClientError.TIMEOUT, "response read deadline expired"
            )
        try:
            if self.tls:
                return self._tls_read(buf, deadline)
            return _read_with_deadline(self.tcp.value().raw_fd(), buf, deadline)
        except error:
            raise _client_transport(ClientError.READ, error^)

    def write_all[
        origin: ImmOrigin
    ](
        mut self, buf: Span[Byte, origin], deadline: _Deadline
    ) raises ClientError:
        if deadline.expired():
            raise ClientError(
                ClientError.TIMEOUT, "request write deadline expired"
            )
        try:
            if self.tls:
                self._tls_write_all(buf, deadline)
            else:
                _write_all_loop(self.tcp.value().raw_fd(), buf, deadline)
        except error:
            raise _client_transport(ClientError.WRITE, error^)


@fieldwise_init
struct _IdleClientConnection(Movable):
    var connection: Optional[_ClientConnection]
    var idle_since: Int


@fieldwise_init
struct _ClientOriginPool(Movable):
    var key: String
    var idle: List[_IdleClientConnection]
    var count: Int


struct _ClientPoolState(Movable):
    var mutex: PthreadMutex
    var origins: List[_ClientOriginPool]
    var closed: Bool
    var max_connections: Int
    var max_idle: Int
    var idle_timeout: UInt64

    def __init__(out self, config: ClientConfig):
        self.mutex = PthreadMutex._uninitialized()
        self.origins = List[_ClientOriginPool]()
        self.closed = False
        self.max_connections = config.max_conns_per_host
        self.max_idle = config.max_idle_conns_per_host
        self.idle_timeout = config.idle_conn_timeout._value

    def __deinit__(deinit self):
        self.mutex.destroy()


struct _ClientLease(Movable):
    var state: ArcPointer[_ClientPoolState]
    var origin: Int
    var connection: Optional[_ClientConnection]
    var reused: Bool
    var active: Bool

    def __init__(
        out self,
        var state: ArcPointer[_ClientPoolState],
        origin: Int,
        var connection: Optional[_ClientConnection],
        reused: Bool,
    ):
        self.state = state^
        self.origin = origin
        self.connection = connection^
        self.reused = reused
        self.active = True

    def finish(mut self, reusable: Bool):
        if not self.active:
            return
        self.active = False
        self.state[].mutex.lock()
        if (
            reusable
            and not self.state[].closed
            and len(self.state[].origins[self.origin].idle)
            < self.state[].max_idle
        ):
            var connection = self.connection.take()
            self.state[].origins[self.origin].idle.append(
                _IdleClientConnection(connection^, perf_counter_ns())
            )
        else:
            self.state[].origins[self.origin].count -= 1
            self.connection = None
        self.state[].mutex.unlock()

    def __deinit__(deinit self):
        self.finish(False)


struct _ClientPool(Movable):
    var state: ArcPointer[_ClientPoolState]

    def __init__(out self, config: ClientConfig):
        self.state = ArcPointer(_ClientPoolState(config))
        self.state[].mutex._initialize()

    def acquire(mut self, url: ParsedUrl) raises ClientError -> _ClientLease:
        var key = url.scheme + "|" + url.host + "|" + String(url.port)
        self.state[].mutex.lock()
        if self.state[].closed:
            self.state[].mutex.unlock()
            raise ClientError(ClientError.CANCELED, "HTTP client is closed")
        var origin = -1
        for i in range(len(self.state[].origins)):
            if self.state[].origins[i].key == key:
                origin = i
                break
        if origin < 0:
            origin = len(self.state[].origins)
            self.state[].origins.append(
                _ClientOriginPool(key^, List[_IdleClientConnection](), 0)
            )
        while len(self.state[].origins[origin].idle) > 0:
            var idle = self.state[].origins[origin].idle.pop()
            if (
                UInt64(perf_counter_ns() - idle.idle_since)
                >= self.state[].idle_timeout
            ):
                self.state[].origins[origin].count -= 1
                continue
            self.state[].mutex.unlock()
            return _ClientLease(
                self.state.copy(), origin, idle.connection.take(), True
            )
        if self.state[].origins[origin].count >= self.state[].max_connections:
            self.state[].mutex.unlock()
            raise ClientError(
                ClientError.POOL_FULL, "HTTP origin connection pool is full"
            )
        self.state[].origins[origin].count += 1
        self.state[].mutex.unlock()
        return _ClientLease(self.state.copy(), origin, None, False)

    def close(mut self):
        self.state[].mutex.lock()
        self.state[].closed = True
        for i in range(len(self.state[].origins)):
            self.state[].origins[i].count -= len(self.state[].origins[i].idle)
            self.state[].origins[i].idle.clear()
        self.state[].mutex.unlock()
