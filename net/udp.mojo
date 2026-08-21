from net._sys.common import (
    AF_INET,
    AF_INET6,
    EAFNOSUPPORT,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    SOCK_DGRAM,
    _OwnedFD,
    _CONNECT_FAILED,
    _CONNECT_PENDING,
    _CONNECT_RETRY,
    _bind,
    _connect_attempt_allowed,
    _connect_disposition,
    _connect_status,
    _is_interrupted,
    _is_would_block,
    _recv_from_status,
    _recv_status,
    _send_status,
    _send_to_status,
    _set_socket_option_int,
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


@fieldwise_init
struct UDPReceiveResult(Copyable, Movable, Writable):
    var count: Int
    var source: SocketAddress
    var truncated: Bool


def _udp_timeout(operation: String) -> NetError:
    return NetError(
        NetErrorKind.timeout(), operation, None, "operation timed out"
    )


def _invalid_udp_address() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "dial udp",
        None,
        "invalid UDP address",
    )


def _invalid_udp_mode(operation: String) -> NetError:
    return NetError(
        NetErrorKind.invalid_state(),
        operation,
        None,
        "operation is invalid for this UDP mode",
    )


def _udp_unsupported_family(error: NetError) -> Bool:
    return error.errno and Int32(error.errno.value()) == EAFNOSUPPORT


def _udp_read[
    origin: MutOrigin
](
    fd: Int32,
    buffer: Span[mut=True, Byte, origin],
    deadline: _Deadline,
) raises NetError -> Int:
    while True:
        var status = _recv_status(fd, buffer)
        if status.error_number == 0:
            return status.value
        if _is_interrupted(status.error_number):
            if deadline.expired():
                raise _udp_timeout("read")
            continue
        if not _is_would_block(status.error_number):
            raise _system_error("recv", status.error_number)
        if not _wait_readable(fd, deadline):
            raise _udp_timeout("read")


def _udp_write[
    origin: ImmOrigin
](
    fd: Int32, buffer: Span[Byte, origin], deadline: _Deadline
) raises NetError -> Int:
    while True:
        var status = _send_status(fd, buffer)
        if status.error_number == 0:
            if status.value != len(buffer):
                raise NetError(
                    NetErrorKind.invalid_state(),
                    "write",
                    None,
                    "datagram write was partial",
                )
            return status.value
        if _is_interrupted(status.error_number):
            if deadline.expired():
                raise _udp_timeout("write")
            continue
        if not _is_would_block(status.error_number):
            raise _system_error("send", status.error_number)
        if not _wait_writable(fd, deadline):
            raise _udp_timeout("write")


struct UDPConn(Movable):
    var _fd: _OwnedFD
    var _connected: Bool

    def __init__(out self, var fd: _OwnedFD, connected: Bool):
        self._fd = fd^
        self._connected = connected

    def read[
        origin: MutOrigin
    ](
        self,
        buffer: Span[mut=True, Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        if not self._connected:
            raise _invalid_udp_mode("read")
        var deadline = _Deadline.from_optional(timeout)
        return _udp_read(self._fd.raw(), buffer, deadline)

    def write[
        origin: ImmOrigin
    ](
        self,
        buffer: Span[Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        if not self._connected:
            raise _invalid_udp_mode("write")
        var deadline = _Deadline.from_optional(timeout)
        return _udp_write(self._fd.raw(), buffer, deadline)

    def recv_from[
        origin: MutOrigin
    ](
        self,
        buffer: Span[mut=True, Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> UDPReceiveResult:
        if self._connected:
            raise _invalid_udp_mode("recv_from")
        var deadline = _Deadline.from_optional(timeout)
        var fd = self._fd.raw()
        while True:
            var received = _recv_from_status(fd, buffer)
            if received.error_number == 0:
                if received.address_too_large:
                    raise NetError(
                        NetErrorKind.invalid_state(),
                        "recvmsg",
                        None,
                        "socket address is too large",
                    )
                var source_length = received.source.length
                var source = _socket_address_from_raw(
                    received.source.unsafe_ptr(), source_length
                )
                return UDPReceiveResult(
                    count=received.count,
                    source=source^,
                    truncated=received.truncated,
                )
            if _is_interrupted(received.error_number):
                if deadline.expired():
                    raise _udp_timeout("recv_from")
                continue
            if not _is_would_block(received.error_number):
                raise _system_error("recvmsg", received.error_number)
            if not _wait_readable(fd, deadline):
                raise _udp_timeout("recv_from")

    def send_to[
        origin: ImmOrigin
    ](
        self,
        buffer: Span[Byte, origin],
        address: SocketAddress,
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        if self._connected:
            raise _invalid_udp_mode("send_to")
        var deadline = _Deadline.from_optional(timeout)
        var fd = self._fd.raw()
        var raw = _socket_address_to_raw(address)
        while True:
            var status = _send_to_status(fd, buffer, raw)
            if status.error_number == 0:
                if status.value != len(buffer):
                    raise NetError(
                        NetErrorKind.invalid_state(),
                        "send_to",
                        None,
                        "datagram write was partial",
                    )
                return status.value
            if _is_interrupted(status.error_number):
                if deadline.expired():
                    raise _udp_timeout("send_to")
                continue
            if not _is_would_block(status.error_number):
                raise _system_error("sendto", status.error_number)
            if not _wait_writable(fd, deadline):
                raise _udp_timeout("send_to")

    def local_address(self) raises NetError -> SocketAddress:
        var raw = _socket_name(self._fd.raw(), False)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def remote_address(self) raises NetError -> SocketAddress:
        if not self._connected:
            raise _invalid_udp_mode("remote_address")
        var raw = _socket_name(self._fd.raw(), True)
        var length = raw.length
        return _socket_address_from_raw(raw.unsafe_ptr(), length)

    def close(mut self) raises NetError:
        self._fd.close()


def _udp_listen_addresses(
    value: StringSlice,
) raises NetError -> List[SocketAddress]:
    var host, port = _split_host_port(value, True)
    if host.byte_length() != 0:
        return resolve_socket_addresses(value, SOCK_DGRAM)
    var addresses = List[SocketAddress]()
    addresses.append(
        SocketAddress(ip=IPAddress.parse("::"), port=port, scope_id=0)
    )
    addresses.append(
        SocketAddress(ip=IPAddress.parse("0.0.0.0"), port=port, scope_id=0)
    )
    return addresses^


def dial_udp(
    address: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> UDPConn:
    var _, port = split_host_port(address)
    if port == 0:
        raise _invalid_udp_address()
    var addresses = resolve_socket_addresses(address, SOCK_DGRAM)
    var deadline = _Deadline.from_optional(timeout)
    var last_error: Optional[NetError] = None
    var has_attempted = False

    for candidate in addresses:
        while True:
            if not _connect_attempt_allowed(has_attempted, deadline):
                raise _udp_timeout("connect")
            has_attempted = True
            try:
                var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
                var fd = _socket(domain, SOCK_DGRAM, 0)
                var raw = _socket_address_to_raw(candidate)
                var status = _connect_status(fd.raw(), raw)
                var disposition = _connect_disposition(status.error_number)
                if disposition == _CONNECT_RETRY:
                    continue
                if disposition == _CONNECT_FAILED:
                    raise _system_error("connect", status.error_number)
                if disposition == _CONNECT_PENDING:
                    if not _wait_writable(fd.raw(), deadline):
                        raise _udp_timeout("connect")
                    var error_number = _socket_error(fd.raw())
                    if error_number != 0:
                        raise _system_error("connect", error_number)
                return UDPConn(fd^, True)
            except error:
                if error.kind == NetErrorKind.timeout():
                    raise error^
                last_error = error.copy()
                if deadline.expired():
                    raise _udp_timeout("connect")
                break
    if last_error:
        var final_error = last_error.value().copy()
        if _udp_unsupported_family(final_error):
            raise NetError(
                NetErrorKind.unsupported(),
                "dial udp",
                final_error.errno,
                "address family is unsupported",
            )
        raise final_error^
    raise _invalid_udp_address()


def listen_udp(address: StringSlice) raises NetError -> UDPConn:
    var addresses = _udp_listen_addresses(address)
    var last_error: Optional[NetError] = None

    for candidate in addresses:
        try:
            var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
            var fd = _socket(domain, SOCK_DGRAM, 0)
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
            return UDPConn(fd^, False)
        except error:
            last_error = error.copy()
    if last_error:
        var final_error = last_error.value().copy()
        if _udp_unsupported_family(final_error):
            raise NetError(
                NetErrorKind.unsupported(),
                "listen udp",
                final_error.errno,
                "address family is unsupported",
            )
        raise final_error^
    raise _invalid_udp_address()
