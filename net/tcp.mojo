from net._sys.common import (
    AF_INET,
    AF_INET6,
    EAFNOSUPPORT,
    EAGAIN,
    EINTR,
    EWOULDBLOCK,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    SOCK_STREAM,
    SOL_SOCKET,
    SO_REUSEADDR,
    _OwnedFD,
    _accept,
    _bind,
    _connect,
    _listen,
    _recv,
    _send,
    _set_socket_option_int,
    _shutdown,
    _socket,
    _socket_error,
    _socket_name,
    _system_error,
    _wait_readable,
    _wait_writable,
)
from .address import (
    SocketAddress,
    _socket_address_from_raw,
    _socket_address_to_raw,
    _split_host_port,
    resolve_socket_addresses,
    split_host_port,
)
from .error import NetError, NetErrorKind
from .ip import IPAddress
from .timeout import Timeout, _Deadline


def _timeout_error(operation: String) -> NetError:
    return NetError(
        NetErrorKind.timeout(), operation, None, "operation timed out"
    )


def _invalid_tcp_address() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "dial tcp",
        None,
        "invalid TCP address",
    )


def _invalid_backlog() -> NetError:
    return NetError(
        NetErrorKind.invalid_argument(),
        "listen tcp",
        None,
        "backlog is out of range",
    )


def _would_block(error: NetError) -> Bool:
    if not error.errno:
        return False
    var error_number = Int32(error.errno.value())
    return error_number == EAGAIN or error_number == EWOULDBLOCK


def _interrupted(error: NetError) -> Bool:
    return error.errno and Int32(error.errno.value()) == EINTR


def _unsupported_family(error: NetError) -> Bool:
    return error.errno and Int32(error.errno.value()) == EAFNOSUPPORT


def _read_with_deadline[
    origin: MutOrigin
](
    fd: Int32,
    buffer: Span[mut=True, Byte, origin],
    deadline: _Deadline,
) raises NetError -> Int:
    if len(buffer) == 0:
        return 0
    while True:
        try:
            return _recv(fd, buffer)
        except error:
            if _interrupted(error):
                if deadline.expired():
                    raise _timeout_error("read")
                continue
            if not _would_block(error):
                raise error^
        if not _wait_readable(fd, deadline):
            raise _timeout_error("read")


def _write_with_deadline[
    origin: ImmOrigin
](
    fd: Int32, buffer: Span[Byte, origin], deadline: _Deadline
) raises NetError -> Int:
    if len(buffer) == 0:
        return 0
    while True:
        try:
            var written = _send(fd, buffer)
            if written == 0:
                raise NetError(
                    NetErrorKind.invalid_state(),
                    "write",
                    None,
                    "non-empty write made no progress",
                )
            return written
        except error:
            if _interrupted(error):
                if deadline.expired():
                    raise _timeout_error("write")
                continue
            if not _would_block(error):
                raise error^
        if not _wait_writable(fd, deadline):
            raise _timeout_error("write")


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
        var offset = 0
        while offset < len(buffer):
            offset += _write_with_deadline(fd, buffer[offset:], deadline)

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

    def close(mut self) raises NetError:
        self._fd.close()


struct TCPListener(Movable):
    var _fd: _OwnedFD

    def __init__(out self, var fd: _OwnedFD):
        self._fd = fd^

    def accept(
        self, timeout: Optional[Timeout] = None
    ) raises NetError -> TCPConn:
        var deadline = _Deadline.from_optional(timeout)
        var fd = self._fd.raw()
        while True:
            try:
                var accepted = _accept(fd)
                return TCPConn(accepted^)
            except error:
                if _interrupted(error):
                    if deadline.expired():
                        raise _timeout_error("accept")
                    continue
                if not _would_block(error):
                    raise error^
            if not _wait_readable(fd, deadline):
                raise _timeout_error("accept")

    def local_address(self) raises NetError -> SocketAddress:
        var raw = _socket_name(self._fd.raw(), False)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def close(mut self) raises NetError:
        self._fd.close()


def _listen_addresses(
    value: StringSlice,
) raises NetError -> List[SocketAddress]:
    var host, port = _split_host_port(value, True)
    if host.byte_length() != 0:
        return resolve_socket_addresses(value, SOCK_STREAM)
    var addresses = List[SocketAddress]()
    addresses.append(
        SocketAddress(ip=IPAddress.parse("::"), port=port, scope_id=0)
    )
    addresses.append(
        SocketAddress(ip=IPAddress.parse("0.0.0.0"), port=port, scope_id=0)
    )
    return addresses^


def dial_tcp(
    address: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> TCPConn:
    var _, port = split_host_port(address)
    if port == 0:
        raise _invalid_tcp_address()
    var addresses = resolve_socket_addresses(address, SOCK_STREAM)
    var deadline = _Deadline.from_optional(timeout)
    var last_error = _invalid_tcp_address()
    var had_error = False

    for candidate in addresses:
        try:
            var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
            var fd = _socket(domain, SOCK_STREAM, 0)
            var raw = _socket_address_to_raw(candidate)
            if not _connect(fd.raw(), raw):
                if not _wait_writable(fd.raw(), deadline):
                    raise _timeout_error("connect")
                var error_number = _socket_error(fd.raw())
                if error_number != 0:
                    raise _system_error("connect", error_number)
            return TCPConn(fd^)
        except error:
            if error.kind == NetErrorKind.timeout():
                raise error^
            last_error = error.copy()
            had_error = True
            if deadline.expired():
                raise _timeout_error("connect")
    if had_error:
        if _unsupported_family(last_error):
            raise NetError(
                NetErrorKind.unsupported(),
                "dial tcp",
                last_error.errno,
                "address family is unsupported",
            )
        raise last_error^
    raise _invalid_tcp_address()


def listen_tcp(
    address: StringSlice, backlog: Int = 128
) raises NetError -> TCPListener:
    if backlog < 1 or backlog > Int(Int32.MAX):
        raise _invalid_backlog()
    var addresses = _listen_addresses(address)
    var last_error = _invalid_tcp_address()
    var had_error = False

    for candidate in addresses:
        try:
            var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
            var fd = _socket(domain, SOCK_STREAM, 0)
            _set_socket_option_int(
                fd.raw(),
                SOL_SOCKET,
                SO_REUSEADDR,
                1,
                "setsockopt(SO_REUSEADDR)",
            )
            if candidate.ip.is_ipv6():
                _set_socket_option_int(
                    fd.raw(),
                    IPPROTO_IPV6,
                    IPV6_V6ONLY,
                    1,
                    "setsockopt(IPV6_V6ONLY)",
                )
            var raw = _socket_address_to_raw(candidate)
            _bind(fd.raw(), raw)
            _listen(fd.raw(), Int32(backlog))
            return TCPListener(fd^)
        except error:
            last_error = error.copy()
            had_error = True
    if had_error:
        if _unsupported_family(last_error):
            raise NetError(
                NetErrorKind.unsupported(),
                "listen tcp",
                last_error.errno,
                "address family is unsupported",
            )
        raise last_error^
    raise _invalid_tcp_address()
