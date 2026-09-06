from net._sys.common import (
    AF_INET,
    AF_INET6,
    IPPROTO_TCP,
    SOCK_STREAM,
    SOL_SOCKET,
    SO_KEEPALIVE,
    SO_RCVBUF,
    SO_SNDBUF,
    TCP_KEEPIDLE,
    TCP_KEEPINTVL,
    TCP_NODELAY,
    _OwnedFD,
    _connect_candidate,
    _create_bound_socket,
    _default_listen_backlog,
    _listen,
    _final_error,
    _set_linger,
    _set_socket_option_int,
    _shutdown,
    _socket_name,
)
from ._stream import (
    _accept_stream,
    _accept_stream_pair,
    _read_with_deadline,
    _try_accept,
    _try_recv,
    _try_send,
    _write_all_loop,
    _write_with_deadline,
)
from .address import (
    SocketAddress,
    _listen_addresses,
    _resolve_parsed,
    _socket_address_from_raw,
    _socket_address_to_raw,
    _v6only_for_listen,
    split_host_port,
)
from .error import (
    NetError,
    NetErrorKind,
    _invalid_address_error,
    _invalid_backlog_error,
    _timeout_error,
)
from .timeout import Timeout, _Deadline


def _timeout_seconds(
    period: Timeout, operation: String
) raises NetError -> Int32:
    var whole = period._value // 1_000_000_000
    if period._value % 1_000_000_000 != 0:
        whole += 1
    if whole == 0:
        whole = 1
    if whole > UInt64(Int32.MAX):
        raise NetError(
            NetErrorKind.invalid_argument(),
            operation,
            None,
            "keep-alive period is too large",
        )
    return Int32(whole)


def _socket_buffer_size(bytes: Int, operation: String) raises NetError -> Int32:
    if bytes < 1 or bytes > Int(Int32.MAX):
        raise NetError(
            NetErrorKind.invalid_argument(),
            operation,
            None,
            "socket buffer size is out of range",
        )
    return Int32(bytes)


struct TCPConn(Movable):
    var _fd: _OwnedFD

    def __init__(out self, var fd: _OwnedFD):
        self._fd = fd^

    def read[
        origin: MutOrigin
    ](
        self,
        buffer: Span[mut=True, Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        var deadline = _Deadline.from_optional(timeout)
        var fd = self._fd.raw()
        return _read_with_deadline(fd, buffer, deadline)

    def write[
        origin: ImmOrigin
    ](
        self,
        buffer: Span[Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        var deadline = _Deadline.from_optional(timeout)
        var fd = self._fd.raw()
        return _write_with_deadline(fd, buffer, deadline)

    def write_all[
        origin: ImmOrigin
    ](
        self,
        buffer: Span[Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError:
        var deadline = _Deadline.from_optional(timeout)
        var fd = self._fd.raw()
        _write_all_loop(fd, buffer, deadline)

    def try_read[
        origin: MutOrigin
    ](self, buffer: Span[mut=True, Byte, origin]) raises NetError -> Int:
        """One `read` attempt that never waits: a would-block socket
        reports `timeout` instead, so a `Poller` event loop can serve
        the next ready descriptor."""
        return _try_recv(self._fd.raw(), buffer)

    def try_write[
        origin: ImmOrigin
    ](self, buffer: Span[Byte, origin]) raises NetError -> Int:
        """One `write` attempt that never waits; see `try_read`."""
        return _try_send(self._fd.raw(), buffer)

    def raw_fd(self) raises NetError -> Int32:
        """Borrows the descriptor number for `Poller` registration.

        The socket keeps ownership: do not close the returned value.
        """
        return self._fd.raw()

    def local_address(self) raises NetError -> SocketAddress:
        var raw = _socket_name(self._fd.raw(), False)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def remote_address(self) raises NetError -> SocketAddress:
        var raw = _socket_name(self._fd.raw(), True)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def shutdown(
        self, read_side: Bool = True, write_side: Bool = True
    ) raises NetError:
        _shutdown(self._fd.raw(), read_side, write_side)

    def set_no_delay(self, enabled: Bool) raises NetError:
        """Enables or disables `TCP_NODELAY`.

        New connections default to enabled, matching Go: small writes
        are sent immediately instead of waiting out Nagle's algorithm.
        """
        _set_socket_option_int(
            self._fd.raw(),
            IPPROTO_TCP,
            TCP_NODELAY,
            Int32(1) if enabled else Int32(0),
            "setsockopt(TCP_NODELAY)",
        )

    def set_keep_alive(self, enabled: Bool) raises NetError:
        """Enables or disables `SO_KEEPALIVE`."""
        _set_socket_option_int(
            self._fd.raw(),
            SOL_SOCKET,
            SO_KEEPALIVE,
            Int32(1) if enabled else Int32(0),
            "setsockopt(SO_KEEPALIVE)",
        )

    def set_keep_alive_period(self, period: Timeout) raises NetError:
        """Enables keep-alive and sets the idle and interval timers.

        The period has seconds granularity; sub-second values round up
        to one second.
        """
        var seconds = _timeout_seconds(period, "setsockopt(TCP_KEEPIDLE)")
        _set_socket_option_int(
            self._fd.raw(),
            SOL_SOCKET,
            SO_KEEPALIVE,
            Int32(1),
            "setsockopt(SO_KEEPALIVE)",
        )
        _set_socket_option_int(
            self._fd.raw(),
            IPPROTO_TCP,
            TCP_KEEPIDLE,
            seconds,
            "setsockopt(TCP_KEEPIDLE)",
        )
        _set_socket_option_int(
            self._fd.raw(),
            IPPROTO_TCP,
            TCP_KEEPINTVL,
            seconds,
            "setsockopt(TCP_KEEPINTVL)",
        )

    def set_read_buffer(self, bytes: Int) raises NetError:
        """Sets `SO_RCVBUF`. The kernel may round the value up."""
        _set_socket_option_int(
            self._fd.raw(),
            SOL_SOCKET,
            SO_RCVBUF,
            _socket_buffer_size(bytes, "setsockopt(SO_RCVBUF)"),
            "setsockopt(SO_RCVBUF)",
        )

    def set_write_buffer(self, bytes: Int) raises NetError:
        """Sets `SO_SNDBUF`. The kernel may round the value up."""
        _set_socket_option_int(
            self._fd.raw(),
            SOL_SOCKET,
            SO_SNDBUF,
            _socket_buffer_size(bytes, "setsockopt(SO_SNDBUF)"),
            "setsockopt(SO_SNDBUF)",
        )

    def set_linger(self, seconds: Int) raises NetError:
        """Sets `SO_LINGER`: a negative value disables lingering, zero
        discards unsent data on close, and a positive value blocks
        close up to that many seconds while data drains."""
        if seconds < 0:
            _set_linger(self._fd.raw(), 0, 0, "setsockopt(SO_LINGER)")
            return
        if seconds > Int(Int32.MAX):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "setsockopt(SO_LINGER)",
                None,
                "linger period is too large",
            )
        _set_linger(self._fd.raw(), 1, Int32(seconds), "setsockopt(SO_LINGER)")

    def close(mut self) raises NetError:
        self._fd.close()


@fieldwise_init
struct TCPAcceptResult(Movable):
    var conn: TCPConn
    var address: SocketAddress


struct TCPListener(Movable):
    var _fd: _OwnedFD

    def __init__(out self, var fd: _OwnedFD):
        self._fd = fd^

    def accept(
        self, timeout: Optional[Timeout] = None
    ) raises NetError -> TCPConn:
        var deadline = _Deadline.from_optional(timeout)
        var fd = _accept_stream(self._fd.raw(), deadline)
        _set_socket_option_int(
            fd.raw(),
            IPPROTO_TCP,
            TCP_NODELAY,
            Int32(1),
            "setsockopt(TCP_NODELAY)",
        )
        return TCPConn(fd^)

    def try_accept(self) raises NetError -> TCPConn:
        """One `accept` attempt that never waits; see `TCPConn.try_read`."""
        return TCPConn(_try_accept(self._fd.raw()))

    def raw_fd(self) raises NetError -> Int32:
        """Borrows the descriptor number for `Poller` registration.

        The listener keeps ownership: do not close the returned value.
        """
        return self._fd.raw()

    def accept_with_address(
        self, timeout: Optional[Timeout] = None
    ) raises NetError -> TCPAcceptResult:
        """Accepts one connection and returns the peer address captured
        by the same syscall, saving a `getpeername` round trip."""
        var deadline = _Deadline.from_optional(timeout)
        var accepted = _accept_stream_pair(self._fd.raw(), deadline)
        var peer_length = accepted.peer.length
        var address = _socket_address_from_raw(
            accepted.peer.unsafe_ptr(), peer_length
        )
        return TCPAcceptResult(
            conn=TCPConn(accepted.take_fd()), address=address^
        )

    def local_address(self) raises NetError -> SocketAddress:
        var raw = _socket_name(self._fd.raw(), False)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def close(mut self) raises NetError:
        self._fd.close()


def _dial_tcp_candidates(
    var candidates: List[SocketAddress], deadline: _Deadline
) raises NetError -> TCPConn:
    var last_error: Optional[NetError] = None
    var has_attempted = False

    for candidate in candidates:
        try:
            var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
            var raw = _socket_address_to_raw(candidate)
            var fd = _connect_candidate(
                domain, SOCK_STREAM, raw, has_attempted, deadline
            )
            _set_socket_option_int(
                fd.raw(),
                IPPROTO_TCP,
                TCP_NODELAY,
                Int32(1),
                "setsockopt(TCP_NODELAY)",
            )
            return TCPConn(fd^)
        except error:
            if error.kind == NetErrorKind.timeout():
                raise error^
            last_error = error.copy()
            if deadline.expired():
                raise _timeout_error("connect")
    raise _final_error(
        last_error,
        "dial tcp",
        _invalid_address_error("dial tcp", "invalid TCP address"),
    )


def dial_tcp(
    address: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> TCPConn:
    var host, port = split_host_port(address)
    if port == 0:
        raise _invalid_address_error("dial tcp", "invalid TCP address")
    var addresses = _resolve_parsed(host^, port, SOCK_STREAM)
    var deadline = _Deadline.from_optional(timeout)
    return _dial_tcp_candidates(addresses^, deadline)


def listen_tcp(
    address: StringSlice, backlog: Optional[Int] = None, ipv6_only: Bool = False
) raises NetError -> TCPListener:
    """Listens for TCP connections. Without an explicit backlog the
    kernel's somaxconn applies (`/proc/sys/net/core/somaxconn` on
    Linux, `kern.ipc.somaxconn` on macOS)."""
    var effective = _default_listen_backlog()
    if backlog:
        effective = backlog.value()
    if effective < 1 or effective > Int(Int32.MAX):
        raise _invalid_backlog_error("listen tcp")
    var addresses = _listen_addresses(address, SOCK_STREAM)
    var last_error: Optional[NetError] = None

    for candidate in addresses:
        if ipv6_only and not candidate.ip.is_ipv6():
            continue
        try:
            var raw = _socket_address_to_raw(candidate)
            var v6only = _v6only_for_listen(candidate, ipv6_only)
            var fd = _create_bound_socket(
                AF_INET6 if candidate.ip.is_ipv6() else AF_INET,
                SOCK_STREAM,
                raw,
                True,
                v6only,
            )
            _listen(fd.raw(), Int32(effective))
            return TCPListener(fd^)
        except error:
            last_error = error.copy()
    raise _final_error(
        last_error,
        "listen tcp",
        _invalid_address_error("listen tcp", "invalid TCP address"),
    )
