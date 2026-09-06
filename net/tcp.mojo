from net._sys.common import (
    AF_INET,
    AF_INET6,
    SOCK_STREAM,
    _OwnedFD,
    _connect_candidate,
    _create_bound_socket,
    _listen,
    _final_error,
    _shutdown,
    _socket_name,
)
from ._stream import (
    _SocketWriteStep,
    _accept_stream,
    _read_with_deadline,
    _write_all_loop,
    _write_with_deadline,
)
from .address import (
    SocketAddress,
    _listen_addresses,
    _socket_address_from_raw,
    _socket_address_to_raw,
    _v6only_for_listen,
    resolve_socket_addresses,
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
        var write_step = _SocketWriteStep(fd, buffer)
        _write_all_loop(len(buffer), deadline, write_step)

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
        return TCPConn(_accept_stream(self._fd.raw(), deadline))

    def local_address(self) raises NetError -> SocketAddress:
        var raw = _socket_name(self._fd.raw(), False)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def close(mut self) raises NetError:
        self._fd.close()


def dial_tcp(
    address: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> TCPConn:
    var _, port = split_host_port(address)
    if port == 0:
        raise _invalid_address_error("dial tcp", "invalid TCP address")
    var addresses = resolve_socket_addresses(address, SOCK_STREAM)
    var deadline = _Deadline.from_optional(timeout)
    var last_error: Optional[NetError] = None
    var has_attempted = False

    for candidate in addresses:
        try:
            var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
            var raw = _socket_address_to_raw(candidate)
            return TCPConn(
                _connect_candidate(
                    domain, SOCK_STREAM, raw, has_attempted, deadline
                )
            )
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


def listen_tcp(
    address: StringSlice, backlog: Int = 128, ipv6_only: Bool = False
) raises NetError -> TCPListener:
    if backlog < 1 or backlog > Int(Int32.MAX):
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
            _listen(fd.raw(), Int32(backlog))
            return TCPListener(fd^)
        except error:
            last_error = error.copy()
    raise _final_error(
        last_error,
        "listen tcp",
        _invalid_address_error("dial tcp", "invalid TCP address"),
    )
