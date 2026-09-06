from net._sys.common import (
    AF_INET,
    AF_INET6,
    SOCK_DGRAM,
    _OwnedFD,
    _connect_candidate,
    _create_bound_socket,
    _is_interrupted,
    _is_would_block,
    _final_error,
    _recv_from_status,
    _send_to_status,
    _socket_name,
    _system_error,
    _wait_readable,
    _wait_writable,
)
from ._stream import (
    _read_with_deadline,
    _try_recv,
    _try_send,
    _write_with_deadline,
)
from .address import (
    SocketAddress,
    _listen_addresses,
    _socket_address_from_raw,
    _socket_address_to_raw,
    resolve_socket_addresses,
    split_host_port,
)
from .error import (
    NetError,
    NetErrorKind,
    _invalid_address_error,
    _timeout_error,
)
from .timeout import Timeout, _Deadline


@fieldwise_init
struct UDPReceiveResult(Copyable, Movable, Writable):
    var count: Int
    var source: SocketAddress
    var truncated: Bool


def _invalid_udp_mode(operation: String) -> NetError:
    return NetError(
        NetErrorKind.invalid_state(),
        operation,
        None,
        "operation is invalid for this UDP mode",
    )


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
        return _read_with_deadline(self._fd.raw(), buffer, deadline)

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
        var written = _write_with_deadline(self._fd.raw(), buffer, deadline)
        if written != len(buffer):
            raise NetError(
                NetErrorKind.invalid_state(),
                "write",
                None,
                "datagram write was partial",
            )
        return written

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
                    raise _timeout_error("recv_from")
                continue
            if not _is_would_block(received.error_number):
                raise _system_error("recvmsg", received.error_number)
            if not _wait_readable(fd, deadline):
                raise _timeout_error("recv_from")

    def try_recv_from[
        origin: MutOrigin
    ](
        self, buffer: Span[mut=True, Byte, origin]
    ) raises NetError -> UDPReceiveResult:
        """One `recv_from` attempt that never waits; see
        `TCPConn.try_read`."""
        if self._connected:
            raise _invalid_udp_mode("recv_from")
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
                continue
            if _is_would_block(received.error_number):
                raise _timeout_error("recv_from")
            raise _system_error("recvmsg", received.error_number)

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
                    raise _timeout_error("send_to")
                continue
            if not _is_would_block(status.error_number):
                raise _system_error("sendto", status.error_number)
            if not _wait_writable(fd, deadline):
                raise _timeout_error("send_to")

    def try_read[
        origin: MutOrigin
    ](self, buffer: Span[mut=True, Byte, origin]) raises NetError -> Int:
        """One connected-mode `read` attempt that never waits; see
        `TCPConn.try_read`."""
        if not self._connected:
            raise _invalid_udp_mode("read")
        return _try_recv(self._fd.raw(), buffer)

    def try_write[
        origin: ImmOrigin
    ](self, buffer: Span[Byte, origin]) raises NetError -> Int:
        """One connected-mode `write` attempt that never waits; see
        `TCPConn.try_read`."""
        if not self._connected:
            raise _invalid_udp_mode("write")
        var written = _try_send(self._fd.raw(), buffer)
        if written != len(buffer):
            raise NetError(
                NetErrorKind.invalid_state(),
                "write",
                None,
                "datagram write was partial",
            )
        return written

    def try_send_to[
        origin: ImmOrigin
    ](
        self, buffer: Span[Byte, origin], address: SocketAddress
    ) raises NetError -> Int:
        """One `send_to` attempt that never waits; see
        `TCPConn.try_read`."""
        if self._connected:
            raise _invalid_udp_mode("send_to")
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
                continue
            if _is_would_block(status.error_number):
                raise _timeout_error("send_to")
            raise _system_error("sendto", status.error_number)

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

    def raw_fd(self) raises NetError -> Int32:
        """Borrows the descriptor number for `Poller` registration.

        The socket keeps ownership: do not close the returned value.
        """
        return self._fd.raw()

    def close(mut self) raises NetError:
        self._fd.close()


def dial_udp(
    address: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> UDPConn:
    var _, port = split_host_port(address)
    if port == 0:
        raise _invalid_address_error("dial udp", "invalid UDP address")
    var addresses = resolve_socket_addresses(address, SOCK_DGRAM)
    var deadline = _Deadline.from_optional(timeout)
    var last_error: Optional[NetError] = None
    var has_attempted = False

    for candidate in addresses:
        try:
            var domain = AF_INET6 if candidate.ip.is_ipv6() else AF_INET
            var raw = _socket_address_to_raw(candidate)
            return UDPConn(
                _connect_candidate(
                    domain, SOCK_DGRAM, raw, has_attempted, deadline
                ),
                True,
            )
        except error:
            if error.kind == NetErrorKind.timeout():
                raise error^
            last_error = error.copy()
            if deadline.expired():
                raise _timeout_error("connect")
    raise _final_error(
        last_error,
        "dial udp",
        _invalid_address_error("dial udp", "invalid UDP address"),
    )


def listen_udp(address: StringSlice) raises NetError -> UDPConn:
    var addresses = _listen_addresses(address, SOCK_DGRAM)
    var last_error: Optional[NetError] = None

    for candidate in addresses:
        try:
            var raw = _socket_address_to_raw(candidate)
            var fd = _create_bound_socket(
                AF_INET6 if candidate.ip.is_ipv6() else AF_INET,
                SOCK_DGRAM,
                raw,
                False,
                candidate.ip.is_ipv6(),
            )
            return UDPConn(fd^, False)
        except error:
            last_error = error.copy()
    raise _final_error(
        last_error,
        "listen udp",
        _invalid_address_error("dial udp", "invalid UDP address"),
    )
