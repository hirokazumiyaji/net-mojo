"""Optional OpenSSL-backed nonblocking TLS transport.

`TLSContext` owns server credentials or client trust configuration. A `TLSConnection` owns its TLS
session and accepted socket; drive `handshake`, `try_read`, and `try_write`
from the socket's readiness events. The TLS feature is built separately from
the core `net` package.
"""

from std.ffi import (
    c_int,
    c_uint,
    c_size_t,
    OwnedDLHandle,
    Pointer,
)

from net.error import NetError, NetErrorKind, _require_handle
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

    @staticmethod
    def client(
        var library_path: String,
        ca_bundle_path: Optional[String] = None,
        var alpn: String = "http/1.1",
        insecure_skip_verify: Bool = False,
    ) raises NetError -> Self:
        if alpn != "http/1.1":
            raise NetError(
                NetErrorKind.invalid_argument(),
                "create TLS client context",
                None,
                "only HTTP/1.1 ALPN is supported",
            )
        var ca = String("")
        if ca_bundle_path:
            ca = ca_bundle_path.value().copy()
            if ca.byte_length() == 0:
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "create TLS client context",
                    None,
                    "CA bundle path must not be empty",
                )
        var library: OwnedDLHandle
        try:
            library = OwnedDLHandle(library_path)
        except error:
            raise NetError(
                NetErrorKind.system_error(),
                "create TLS client context",
                None,
                String(error),
            )
        var flags = UInt32(0)
        if insecure_skip_verify:
            flags = 1
        var ca_bytes = ca.as_c_string_span()
        var alpn_bytes = alpn.as_c_string_span()
        var context = _require_handle(
            library.call[
                "net_tls_context_client",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](ca_bytes.ptr(), alpn_bytes.ptr(), c_uint(flags)),
            "create TLS client context",
            "OpenSSL could not load the trust store or ALPN configuration",
        )
        return Self(
            library_path=library_path^, library=library^, context=context
        )

    def __init__(
        out self,
        var library_path: String,
        var certificate_path: String,
        var private_key_path: String,
        var protocols: String,
    ) raises:
        var library = OwnedDLHandle(library_path)
        var certificate = certificate_path.as_c_string_span()
        var private_key = private_key_path.as_c_string_span()
        var alpn = protocols.as_c_string_span()
        var context = _require_handle(
            library.call[
                "net_tls_context_server",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](
                certificate.ptr(),
                private_key.ptr(),
                alpn.ptr(),
            ),
            "create TLS server context",
            "OpenSSL could not load the certificate, key, or ALPN list",
        )
        self._library_path = library_path^
        self._library = library^
        self._context = context

    def __init__(
        out self,
        *,
        var library_path: String,
        var library: OwnedDLHandle,
        context: Pointer[Byte, MutUntrackedOrigin],
    ):
        self._library_path = library_path^
        self._library = library^
        self._context = context

    def _duplicate(self) raises -> Self:
        var library = OwnedDLHandle(self._library_path)
        self._library.call["net_tls_context_retain"](self._context)
        return Self(
            library_path=self._library_path.copy(),
            library=library^,
            context=self._context,
        )

    def __deinit__(deinit self):
        self._library.call["net_tls_context_free"](self._context)

    def accept(mut self, var socket: TCPConn) raises -> TLSConnection:
        var fd = socket.raw_fd()
        var session_library = OwnedDLHandle(self._library_path)
        var session = _require_handle(
            self._library.call[
                "net_tls_connection_new",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](self._context, c_int(fd)),
            "create TLS connection",
            "OpenSSL could not create a connection for the socket",
        )
        return TLSConnection(
            library=session_library^,
            session=session,
            socket=socket^,
        )

    def connect(
        mut self,
        var socket: TCPConn,
        var hostname: String,
        sni_override: Optional[String] = None,
    ) raises NetError -> TLSConnection:
        var sni = hostname.copy()
        if sni_override:
            sni = sni_override.value().copy()
        if hostname.byte_length() == 0 or sni.byte_length() == 0:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "create TLS client connection",
                None,
                "TLS peer names must not be empty",
            )
        for byte in hostname.as_bytes():
            if byte == 0:
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "create TLS client connection",
                    None,
                    "TLS hostname contains NUL",
                )
        for byte in sni.as_bytes():
            if byte == 0:
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "create TLS client connection",
                    None,
                    "TLS SNI contains NUL",
                )
        var fd = socket.raw_fd()
        var session_library: OwnedDLHandle
        try:
            session_library = OwnedDLHandle(self._library_path)
        except error:
            raise NetError(
                NetErrorKind.system_error(),
                "create TLS client connection",
                None,
                String(error),
            )
        var host_bytes = hostname.as_c_string_span()
        var sni_bytes = sni.as_c_string_span()
        var session = _require_handle(
            self._library.call[
                "net_tls_connection_new_client",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](self._context, c_int(fd), sni_bytes.ptr(), host_bytes.ptr()),
            "create TLS client connection",
            "OpenSSL could not configure SNI or peer identity verification",
        )
        return TLSConnection(session_library^, session, socket^)


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
