"""Optional OpenSSL-backed nonblocking TLS server transport.

`TLSContext` owns the server configuration. A `TLSConnection` owns its TLS
session and accepted socket; drive `handshake`, `try_read`, and `try_write`
from the socket's readiness events. The TLS feature is built separately from
the core `net` package.
"""

from std.ffi import (
    c_int,
    c_size_t,
    OwnedDLHandle,
    Pointer,
)

from net.error import NetError, NetErrorKind
from net.tcp import TCPConn


comptime _TLS_WANT_READ: Int32 = -2
comptime _TLS_WANT_WRITE: Int32 = -3
comptime _TLS_CLOSED: Int32 = -4
comptime _TLS_SHUTDOWN_SENT: Int32 = -5


@fieldwise_init
struct TLSProgress(Copyable, Equatable):
    var value: Int32

    @staticmethod
    def complete() -> Self:
        return Self(value=1)

    @staticmethod
    def wants_read() -> Self:
        return Self(value=_TLS_WANT_READ)

    @staticmethod
    def wants_write() -> Self:
        return Self(value=_TLS_WANT_WRITE)

    @staticmethod
    def closed() -> Self:
        return Self(value=_TLS_CLOSED)

    @staticmethod
    def sent_close_notify() -> Self:
        return Self(value=_TLS_SHUTDOWN_SENT)

    def is_complete(self) -> Bool:
        return self.value == 1

    def is_wants_read(self) -> Bool:
        return self.value == _TLS_WANT_READ

    def is_wants_write(self) -> Bool:
        return self.value == _TLS_WANT_WRITE

    def is_closed(self) -> Bool:
        return self.value == _TLS_CLOSED

    def is_sent_close_notify(self) -> Bool:
        return self.value == _TLS_SHUTDOWN_SENT


@fieldwise_init
struct TLSIOResult(Copyable, Equatable):
    var progress: TLSProgress
    var count: Int


struct TLSContext(Movable):
    var _library_path: String
    var _library: OwnedDLHandle
    var _context: Pointer[Byte, MutUntrackedOrigin]

    @staticmethod
    def server(
        var library_path: String,
        var certificate_path: String,
        var private_key_path: String,
        var protocols: String,
    ) raises -> Self:
        return Self(
            library_path^,
            certificate_path^,
            private_key_path^,
            protocols^,
        )

    def __init__(
        out self,
        var library_path: String,
        var certificate_path: String,
        var private_key_path: String,
        var protocols: String,
    ) raises:
        var library = OwnedDLHandle(library_path)
        var certificate = certificate_path.as_c_string_slice()
        var private_key = private_key_path.as_c_string_slice()
        var alpn = protocols.as_c_string_slice()
        var context = library.call[
            "net_tls_context_server",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](
            certificate.unsafe_ptr(),
            private_key.unsafe_ptr(),
            alpn.unsafe_ptr(),
        )
        if context == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create TLS server context",
                None,
                "OpenSSL could not load the certificate, key, or ALPN list",
            )
        self._library_path = library_path^
        self._library = library^
        self._context = context.value()

    def __deinit__(deinit self):
        self._library.call["net_tls_context_free"](self._context)

    def accept(mut self, var socket: TCPConn) raises -> TLSConnection:
        var fd = socket.raw_fd()
        var session_library = OwnedDLHandle(self._library_path)
        var session = self._library.call[
            "net_tls_connection_new",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](self._context, c_int(fd))
        if session == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create TLS connection",
                None,
                "OpenSSL could not create a connection for the socket",
            )
        return TLSConnection(
            library=session_library^,
            session=session.value(),
            socket=socket^,
        )


struct TLSConnection(Movable):
    var _library: OwnedDLHandle
    var _session: Pointer[Byte, MutUntrackedOrigin]
    var _socket: TCPConn

    def __init__(
        out self,
        var library: OwnedDLHandle,
        session: Pointer[Byte, MutUntrackedOrigin],
        var socket: TCPConn,
    ):
        self._library = library^
        self._session = session
        self._socket = socket^

    def __deinit__(deinit self):
        self._library.call["net_tls_connection_free"](self._session)

    def handshake(mut self) raises NetError -> TLSProgress:
        var result = Int32(
            self._library.call["net_tls_handshake", c_int](self._session)
        )
        if result == 1:
            return TLSProgress.complete()
        if result == _TLS_WANT_READ:
            return TLSProgress.wants_read()
        if result == _TLS_WANT_WRITE:
            return TLSProgress.wants_write()
        raise NetError(
            NetErrorKind.system_error(),
            "TLS handshake",
            None,
            "OpenSSL rejected the peer handshake",
        )

    def try_read[
        origin: MutOrigin
    ](
        mut self, buffer: Span[mut=True, Byte, origin]
    ) raises NetError -> TLSIOResult:
        if len(buffer) == 0:
            return TLSIOResult(progress=TLSProgress.complete(), count=0)
        var result = Int32(
            self._library.call["net_tls_read", c_int](
                self._session, buffer.unsafe_ptr(), c_size_t(len(buffer))
            )
        )
        return _io_result(result, "TLS read")

    def try_write[
        origin: ImmOrigin
    ](mut self, buffer: Span[Byte, origin]) raises NetError -> TLSIOResult:
        if len(buffer) == 0:
            return TLSIOResult(progress=TLSProgress.complete(), count=0)
        var result = Int32(
            self._library.call["net_tls_write", c_int](
                self._session, buffer.unsafe_ptr(), c_size_t(len(buffer))
            )
        )
        return _io_result(result, "TLS write")

    def selected_alpn(mut self) raises NetError -> String:
        var buffer = Array[Byte, 256](fill=0)
        var count = self._library.call["net_tls_selected_alpn", c_int](
            self._session, buffer.unsafe_ptr(), c_size_t(len(buffer) - 1)
        )
        if count <= 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "TLS selected ALPN",
                None,
                "handshake has no selected application protocol",
            )
        buffer[count] = 0
        return String(unsafe_from_utf8_ptr=buffer.unsafe_ptr())

    def pending(self) -> Int:
        return Int(self._library.call["net_tls_pending", c_int](self._session))

    def shutdown(mut self) raises NetError -> TLSProgress:
        var result = Int32(
            self._library.call["net_tls_shutdown", c_int](self._session)
        )
        if result == 1:
            return TLSProgress.complete()
        if result == _TLS_WANT_READ:
            return TLSProgress.wants_read()
        if result == _TLS_WANT_WRITE:
            return TLSProgress.wants_write()
        if result == _TLS_SHUTDOWN_SENT:
            return TLSProgress.sent_close_notify()
        raise NetError(
            NetErrorKind.system_error(),
            "TLS shutdown",
            None,
            "OpenSSL could not send close notification",
        )

    def raw_fd(self) raises NetError -> Int32:
        return self._socket.raw_fd()


def _io_result(result: Int32, operation: String) raises NetError -> TLSIOResult:
    if result > 0:
        return TLSIOResult(progress=TLSProgress.complete(), count=Int(result))
    if result == _TLS_WANT_READ:
        return TLSIOResult(progress=TLSProgress.wants_read(), count=0)
    if result == _TLS_WANT_WRITE:
        return TLSIOResult(progress=TLSProgress.wants_write(), count=0)
    if result == _TLS_CLOSED:
        return TLSIOResult(progress=TLSProgress.closed(), count=0)
    raise NetError(
        NetErrorKind.system_error(), operation, None, "OpenSSL I/O failed"
    )
