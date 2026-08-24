from std.ffi import (
    c_int,
    c_size_t,
    c_ssize_t,
    c_uint,
    c_ulong,
    external_call,
    get_errno,
)
from std.sys import CompilationTarget, size_of
from std.sys.info import is_64bit

import net._sys.darwin as darwin
import net._sys.linux as linux
from net.error import NetError, NetErrorKind, _timeout_error
from net.timeout import _Deadline


comptime _DARWIN = CompilationTarget.is_macos()
comptime _LINUX = CompilationTarget.is_linux()
comptime _SockaddrIn = (darwin._SockaddrIn if _DARWIN else linux._SockaddrIn)
comptime _SockaddrIn6 = (darwin._SockaddrIn6 if _DARWIN else linux._SockaddrIn6)
comptime _SockaddrUn = (darwin._SockaddrUn if _DARWIN else linux._SockaddrUn)
comptime _AddrInfo = darwin._AddrInfo if _DARWIN else linux._AddrInfo
comptime _IOVec = darwin._IOVec if _DARWIN else linux._IOVec
comptime _MsgHdr = darwin._MsgHdr if _DARWIN else linux._MsgHdr

comptime AF_INET: Int32 = darwin.AF_INET if _DARWIN else linux.AF_INET
comptime AF_INET6: Int32 = darwin.AF_INET6 if _DARWIN else linux.AF_INET6
comptime AF_UNIX: Int32 = darwin.AF_UNIX if _DARWIN else linux.AF_UNIX
comptime SOCK_STREAM: Int32 = (
    darwin.SOCK_STREAM if _DARWIN else linux.SOCK_STREAM
)
comptime SOCK_DGRAM: Int32 = (
    darwin.SOCK_DGRAM if _DARWIN else linux.SOCK_DGRAM
)
comptime SOCK_NONBLOCK: Int32 = (
    darwin.SOCK_NONBLOCK if _DARWIN else linux.SOCK_NONBLOCK
)
comptime SOCK_CLOEXEC: Int32 = (
    darwin.SOCK_CLOEXEC if _DARWIN else linux.SOCK_CLOEXEC
)
comptime SOL_SOCKET: Int32 = (
    darwin.SOL_SOCKET if _DARWIN else linux.SOL_SOCKET
)
comptime SO_ERROR: Int32 = darwin.SO_ERROR if _DARWIN else linux.SO_ERROR
comptime SO_REUSEADDR: Int32 = (
    darwin.SO_REUSEADDR if _DARWIN else linux.SO_REUSEADDR
)
comptime SO_NOSIGPIPE: Int32 = (
    darwin.SO_NOSIGPIPE if _DARWIN else linux.SO_NOSIGPIPE
)
comptime IPPROTO_IPV6: Int32 = (
    darwin.IPPROTO_IPV6 if _DARWIN else linux.IPPROTO_IPV6
)
comptime IPV6_V6ONLY: Int32 = (
    darwin.IPV6_V6ONLY if _DARWIN else linux.IPV6_V6ONLY
)
comptime POLLIN: Int16 = darwin.POLLIN if _DARWIN else linux.POLLIN
comptime POLLOUT: Int16 = darwin.POLLOUT if _DARWIN else linux.POLLOUT
comptime POLLERR: Int16 = darwin.POLLERR if _DARWIN else linux.POLLERR
comptime POLLHUP: Int16 = darwin.POLLHUP if _DARWIN else linux.POLLHUP
comptime POLLNVAL: Int16 = darwin.POLLNVAL if _DARWIN else linux.POLLNVAL
comptime EINTR: Int32 = darwin.EINTR if _DARWIN else linux.EINTR
comptime EAGAIN: Int32 = darwin.EAGAIN if _DARWIN else linux.EAGAIN
comptime EWOULDBLOCK: Int32 = (
    darwin.EWOULDBLOCK if _DARWIN else linux.EWOULDBLOCK
)
comptime EAFNOSUPPORT: Int32 = (
    darwin.EAFNOSUPPORT if _DARWIN else linux.EAFNOSUPPORT
)
comptime EINPROGRESS: Int32 = (
    darwin.EINPROGRESS if _DARWIN else linux.EINPROGRESS
)
comptime MSG_NOSIGNAL: Int32 = (
    darwin.MSG_NOSIGNAL if _DARWIN else linux.MSG_NOSIGNAL
)
comptime MSG_TRUNC: Int32 = (darwin.MSG_TRUNC if _DARWIN else linux.MSG_TRUNC)
comptime F_GETFD: Int32 = darwin.F_GETFD if _DARWIN else linux.F_GETFD
comptime F_SETFD: Int32 = darwin.F_SETFD if _DARWIN else linux.F_SETFD
comptime F_GETFL: Int32 = darwin.F_GETFL if _DARWIN else linux.F_GETFL
comptime F_SETFL: Int32 = darwin.F_SETFL if _DARWIN else linux.F_SETFL
comptime FD_CLOEXEC: Int32 = (
    darwin.FD_CLOEXEC if _DARWIN else linux.FD_CLOEXEC
)
comptime O_NONBLOCK: Int32 = (
    darwin.O_NONBLOCK if _DARWIN else linux.O_NONBLOCK
)
comptime AI_NUMERICSERV: Int32 = (
    darwin.AI_NUMERICSERV if _DARWIN else linux.AI_NUMERICSERV
)
comptime IF_NAMESIZE: Int = (
    darwin.IF_NAMESIZE if _DARWIN else linux.IF_NAMESIZE
)
comptime UNIX_PATH_MAX: Int = 103 if _DARWIN else 107


struct _ResolverHints(Movable):
    var _storage: Array[UInt64, 6]

    def __init__(out self, socket_type: Int32):
        _verify_abi_layouts()
        self._storage = Array[UInt64, 6](fill=0)
        var destination = Pointer(to=self).unsafe_bitcast[Byte]()
        comptime if _DARWIN:
            var hints = darwin._AddrInfo(
                flags=AI_NUMERICSERV,
                family=0,
                socket_type=socket_type,
                protocol=0,
                address_length=0,
                canonical_name=None,
                address=None,
                next=None,
            )
            var source = Pointer(to=hints).unsafe_bitcast[Byte]()
            for i in range(48):
                destination[unsafe_offset=i] = source[unsafe_offset=i]
        else:
            var hints = linux._AddrInfo(
                flags=AI_NUMERICSERV,
                family=0,
                socket_type=socket_type,
                protocol=0,
                address_length=0,
                address=None,
                canonical_name=None,
                next=None,
            )
            var source = Pointer(to=hints).unsafe_bitcast[Byte]()
            for i in range(48):
                destination[unsafe_offset=i] = source[unsafe_offset=i]

    def unsafe_ptr(mut self) -> Pointer[Byte, origin_of(self)]:
        return Pointer(to=self).unsafe_bitcast[Byte]()


def _addrinfo_family(address: Pointer[Byte, MutUntrackedOrigin]) -> Int32:
    comptime if _DARWIN:
        return address.unsafe_bitcast[darwin._AddrInfo]()[].family
    else:
        return address.unsafe_bitcast[linux._AddrInfo]()[].family


def _addrinfo_address_length(
    address: Pointer[Byte, MutUntrackedOrigin],
) -> UInt32:
    comptime if _DARWIN:
        return address.unsafe_bitcast[darwin._AddrInfo]()[].address_length
    else:
        return address.unsafe_bitcast[linux._AddrInfo]()[].address_length


def _addrinfo_address(
    address: Pointer[Byte, MutUntrackedOrigin],
) -> Optional[Pointer[Byte, MutUntrackedOrigin]]:
    comptime if _DARWIN:
        return address.unsafe_bitcast[darwin._AddrInfo]()[].address
    else:
        return address.unsafe_bitcast[linux._AddrInfo]()[].address


def _addrinfo_next(
    address: Pointer[Byte, MutUntrackedOrigin],
) -> Optional[Pointer[Byte, MutUntrackedOrigin]]:
    comptime if _DARWIN:
        return address.unsafe_bitcast[darwin._AddrInfo]()[].next
    else:
        return address.unsafe_bitcast[linux._AddrInfo]()[].next


struct _RawSocketAddress(Movable):
    var _storage: Array[UInt64, 16]
    var length: UInt32

    def __init__(out self):
        _verify_abi_layouts()
        self._storage = Array[UInt64, 16](fill=0)
        self.length = 0

    def unsafe_ptr(mut self) -> Pointer[Byte, origin_of(self)]:
        return Pointer(to=self).unsafe_bitcast[Byte]()


def _invalid_unix_path() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "unix address",
        None,
        "invalid Unix socket path",
    )


def _validate_unix_path(value: StringSlice) raises NetError:
    _verify_abi_layouts()
    var bytes = value.as_bytes()
    if len(bytes) == 0 or len(bytes) > UNIX_PATH_MAX:
        raise _invalid_unix_path()
    for byte in bytes:
        if byte == 0:
            raise _invalid_unix_path()


def _unix_address_to_raw(
    value: StringSlice,
) raises NetError -> _RawSocketAddress:
    _validate_unix_path(value)
    var input = value.as_bytes()
    var length = 2 + len(input) + 1
    var raw = _RawSocketAddress()

    comptime if _DARWIN:
        var path = Array[Byte, 104](fill=0)
        for i in range(len(input)):
            path[i] = input[i]
        var address = darwin._SockaddrUn(
            length=UInt8(length), family=UInt8(AF_UNIX), path=path^
        )
        var source = Pointer(to=address).unsafe_bitcast[Byte]()
        var destination = raw.unsafe_ptr()
        for i in range(length):
            destination[unsafe_offset=i] = source[unsafe_offset=i]
    else:
        var path = Array[Byte, 108](fill=0)
        for i in range(len(input)):
            path[i] = input[i]
        var address = linux._SockaddrUn(family=UInt16(AF_UNIX), path=path^)
        var source = Pointer(to=address).unsafe_bitcast[Byte]()
        var destination = raw.unsafe_ptr()
        for i in range(length):
            destination[unsafe_offset=i] = source[unsafe_offset=i]

    raw.length = UInt32(length)
    return raw^


@fieldwise_init
struct _SyscallStatus(Copyable, Movable):
    var value: Int
    var error_number: Int32


struct _RawDatagramReceiveStatus(Movable):
    var count: Int
    var source: _RawSocketAddress
    var truncated: Bool
    var error_number: Int32
    var address_too_large: Bool

    def __init__(
        out self,
        count: Int,
        var source: _RawSocketAddress,
        truncated: Bool,
        error_number: Int32,
        address_too_large: Bool = False,
    ):
        self.count = count
        self.source = source^
        self.truncated = truncated
        self.error_number = error_number
        self.address_too_large = address_too_large


struct _AcceptStatus(Movable):
    var fd: _OwnedFD
    var error_number: Int32
    var invalid_state: Bool

    def __init__(
        out self,
        var fd: _OwnedFD,
        error_number: Int32,
        invalid_state: Bool = False,
    ):
        self.fd = fd^
        self.error_number = error_number
        self.invalid_state = invalid_state

    def take_fd(mut self) -> _OwnedFD:
        return _OwnedFD(self.fd._take())


@fieldwise_init
struct _PollFD:
    var fd: Int32
    var events: Int16
    var revents: Int16


def _verify_abi_layouts():
    comptime assert (
        _DARWIN and CompilationTarget.is_apple_silicon() and is_64bit()
    ) or (
        _LINUX and CompilationTarget.is_x86() and is_64bit()
    ), "net supports only macOS arm64 and Linux x86_64"
    comptime assert size_of[_PollFD]() == 8, "invalid pollfd ABI"
    comptime assert (
        size_of[darwin._AddrInfo]() == 48
    ), "invalid Darwin addrinfo ABI"
    comptime assert (
        size_of[linux._AddrInfo]() == 48
    ), "invalid Linux addrinfo ABI"
    comptime assert (
        size_of[_ResolverHints]() == 48
    ), "invalid resolver hints storage"
    comptime assert (
        size_of[_RawSocketAddress]() >= 128
    ), "invalid raw socket address storage"
    comptime assert size_of[_SockaddrIn]() == 16, "invalid sockaddr_in ABI"
    comptime assert size_of[_SockaddrIn6]() == 28, "invalid sockaddr_in6 ABI"
    comptime assert size_of[_IOVec]() == 16, "invalid iovec ABI"
    comptime if _DARWIN:
        comptime assert (
            size_of[_SockaddrUn]() == 106
        ), "invalid Darwin sockaddr_un ABI"
        comptime assert size_of[_MsgHdr]() == 48, "invalid Darwin msghdr ABI"
    else:
        comptime assert (
            size_of[_SockaddrUn]() == 110
        ), "invalid Linux sockaddr_un ABI"
        comptime assert size_of[_MsgHdr]() == 56, "invalid Linux msghdr ABI"


def _system_error(operation: String, error_number: Int32) -> NetError:
    return NetError(
        NetErrorKind.system_error(),
        operation,
        Int(error_number),
        "system call failed",
    )


def _unsupported_family(error: NetError) -> Bool:
    return error.errno and Int32(error.errno.value()) == EAFNOSUPPORT


def _final_error(
    last_error: Optional[NetError], operation: String, fallback: NetError
) -> NetError:
    if last_error:
        var final_error = last_error.value().copy()
        if _unsupported_family(final_error):
            return NetError(
                NetErrorKind.unsupported(),
                operation,
                final_error.errno,
                "address family is unsupported",
            )
        return final_error^
    return fallback.copy()


def _last_errno() -> Int32:
    return get_errno().value


def _is_interrupted(error_number: Int32) -> Bool:
    return error_number == EINTR


def _is_would_block(error_number: Int32) -> Bool:
    return error_number == EAGAIN or error_number == EWOULDBLOCK


comptime _CONNECT_SUCCEEDED: Int32 = 0
comptime _CONNECT_PENDING: Int32 = 1
comptime _CONNECT_RETRY: Int32 = 2
comptime _CONNECT_FAILED: Int32 = 3


def _connect_disposition(error_number: Int32) -> Int32:
    if error_number == 0:
        return _CONNECT_SUCCEEDED
    if error_number == EINPROGRESS:
        return _CONNECT_PENDING
    if error_number == EINTR:
        return _CONNECT_RETRY
    return _CONNECT_FAILED


def _connect_attempt_allowed(has_attempted: Bool, deadline: _Deadline) -> Bool:
    return not has_attempted or not deadline.expired()


def _connect_candidate(
    domain: Int32,
    socket_type: Int32,
    mut address: _RawSocketAddress,
    mut has_attempted: Bool,
    deadline: _Deadline,
) raises NetError -> _OwnedFD:
    while True:
        if not _connect_attempt_allowed(has_attempted, deadline):
            raise _timeout_error("connect")
        has_attempted = True
        var fd = _socket(domain, socket_type, 0)
        var status = _connect_status(fd.raw(), address)
        var disposition = _connect_disposition(status.error_number)
        if disposition == _CONNECT_RETRY:
            continue
        if disposition == _CONNECT_FAILED:
            raise _system_error("connect", status.error_number)
        if disposition == _CONNECT_PENDING:
            if not _wait_writable(fd.raw(), deadline):
                raise _timeout_error("connect")
            var error_number = _socket_error(fd.raw())
            if error_number != 0:
                raise _system_error("connect", error_number)
        return fd^


def _close(fd: Int32) raises NetError:
    _verify_abi_layouts()
    var result = external_call["close", c_int](c_int(fd))
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("close", error_number)


struct _OwnedFD(Movable):
    var _value: Int32

    def __init__(out self, value: Int32):
        _verify_abi_layouts()
        self._value = value

    def __init__(out self, *, deinit move: Self):
        self._value = move._take()

    def __deinit__(deinit self):
        var fd = self._take()
        if fd >= 0:
            _ = external_call["close", c_int](c_int(fd))

    def is_valid(self) -> Bool:
        return self._value >= 0

    def raw(self) raises NetError -> Int32:
        if not self.is_valid():
            raise NetError(
                NetErrorKind.closed(), "fd", None, "descriptor is closed"
            )
        return self._value

    def close(mut self) raises NetError:
        var fd = self._take()
        if fd < 0:
            raise NetError(
                NetErrorKind.closed(), "close", None, "descriptor is closed"
            )
        _close(fd)

    def _take(mut self) -> Int32:
        var value = self._value
        self._value = -1
        return value


def _fcntl[*types: Intable](fd: c_int, command: c_int, *args: *types) -> c_int:
    return external_call["fcntl", c_int, num_fixed_args=2](
        fd, command, args.get_loaded_kgen_pack()
    )


def _nonblocking_cloexec_status(fd: Int32) -> _SyscallStatus:
    var status = _fcntl(c_int(fd), c_int(F_GETFL), c_int(0))
    if status == -1:
        return _SyscallStatus(value=-1, error_number=_last_errno())
    if (status & O_NONBLOCK) == 0:
        var set_status = _fcntl(
            c_int(fd), c_int(F_SETFL), c_int(status | O_NONBLOCK)
        )
        if set_status == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())
        status = _fcntl(c_int(fd), c_int(F_GETFL), c_int(0))
        if status == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())
        if (status & O_NONBLOCK) == 0:
            return _SyscallStatus(value=-2, error_number=0)

    var descriptor = _fcntl(c_int(fd), c_int(F_GETFD), c_int(0))
    if descriptor == -1:
        return _SyscallStatus(value=-1, error_number=_last_errno())
    if (descriptor & FD_CLOEXEC) == 0:
        var set_descriptor = _fcntl(
            c_int(fd), c_int(F_SETFD), c_int(descriptor | FD_CLOEXEC)
        )
        if set_descriptor == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())
        descriptor = _fcntl(c_int(fd), c_int(F_GETFD), c_int(0))
        if descriptor == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())
        if (descriptor & FD_CLOEXEC) == 0:
            return _SyscallStatus(value=-2, error_number=0)
    return _SyscallStatus(value=0, error_number=0)


def _no_sigpipe_status(fd: Int32) -> _SyscallStatus:
    comptime if _DARWIN:
        var enabled: Int32 = 1
        var result = external_call["setsockopt", c_int](
            c_int(fd),
            c_int(SOL_SOCKET),
            c_int(SO_NOSIGPIPE),
            Pointer(to=enabled),
            c_uint(size_of[Int32]()),
        )
        if result == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())
    return _SyscallStatus(value=0, error_number=0)


def _set_nonblocking_cloexec(fd: Int32) raises NetError:
    var status = _nonblocking_cloexec_status(fd)
    if status.value == -2:
        raise NetError(
            NetErrorKind.invalid_state(),
            "fcntl",
            None,
            "descriptor configuration failed",
        )
    if status.error_number != 0:
        raise _system_error("fcntl", status.error_number)


def _set_no_sigpipe(fd: Int32) raises NetError:
    var status = _no_sigpipe_status(fd)
    if status.error_number != 0:
        raise _system_error("setsockopt(SO_NOSIGPIPE)", status.error_number)


def _socket(
    domain: Int32, socket_type: Int32, protocol: Int32
) raises NetError -> _OwnedFD:
    _verify_abi_layouts()
    var actual_type = socket_type
    comptime if _LINUX:
        actual_type |= SOCK_NONBLOCK | SOCK_CLOEXEC
    var raw = external_call["socket", c_int](
        c_int(domain), c_int(actual_type), c_int(protocol)
    )
    if raw == -1:
        var error_number = _last_errno()
        raise _system_error("socket", error_number)
    var result = _OwnedFD(raw)
    _set_nonblocking_cloexec(result.raw())
    comptime if _DARWIN:
        if socket_type == SOCK_STREAM:
            _set_no_sigpipe(result.raw())
    return result^


def _accepted_fd_configuration_status(
    fd: Int32, stream: Bool
) -> _SyscallStatus:
    var status = _nonblocking_cloexec_status(fd)
    if status.value != 0:
        return status^
    comptime if _DARWIN:
        if stream:
            return _no_sigpipe_status(fd)
    return status^


def _accept_status(fd: Int32, stream: Bool = True) -> _AcceptStatus:
    _verify_abi_layouts()
    var raw: Int32
    comptime if _LINUX:
        raw = external_call["accept4", c_int](
            c_int(fd),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            Optional[Pointer[UInt32, MutUntrackedOrigin]](None),
            c_int(SOCK_NONBLOCK | SOCK_CLOEXEC),
        )
    else:
        raw = external_call["accept", c_int](
            c_int(fd),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            Optional[Pointer[UInt32, MutUntrackedOrigin]](None),
        )
    if raw == -1:
        var error_number = _last_errno()
        return _AcceptStatus(_OwnedFD(-1), error_number)
    var result = _OwnedFD(raw)
    comptime if _DARWIN:
        var configuration = _accepted_fd_configuration_status(raw, stream)
        if configuration.value != 0:
            return _AcceptStatus(
                result^,
                configuration.error_number,
                invalid_state=configuration.value == -2,
            )
    return _AcceptStatus(result^, 0)


def _recv_status[
    origin: MutOrigin
](fd: Int32, buffer: Span[mut=True, Byte, origin]) -> _SyscallStatus:
    _verify_abi_layouts()
    var result = external_call["recv", c_ssize_t](
        c_int(fd), buffer.unsafe_ptr(), c_size_t(len(buffer)), c_int(0)
    )
    if result == -1:
        var error_number = _last_errno()
        return _SyscallStatus(value=-1, error_number=error_number)
    return _SyscallStatus(value=Int(result), error_number=0)


def _recv[
    origin: MutOrigin
](fd: Int32, buffer: Span[mut=True, Byte, origin]) raises NetError -> Int:
    var status = _recv_status(fd, buffer)
    if status.error_number != 0:
        raise _system_error("recv", status.error_number)
    return status.value


def _send_status[
    origin: ImmOrigin
](fd: Int32, buffer: Span[Byte, origin]) -> _SyscallStatus:
    _verify_abi_layouts()
    var flags: Int32 = 0
    comptime if _LINUX:
        flags = MSG_NOSIGNAL
    var result = external_call["send", c_ssize_t](
        c_int(fd),
        buffer.unsafe_ptr(),
        c_size_t(len(buffer)),
        c_int(flags),
    )
    if result == -1:
        var error_number = _last_errno()
        return _SyscallStatus(value=-1, error_number=error_number)
    return _SyscallStatus(value=Int(result), error_number=0)


def _send[
    origin: ImmOrigin
](fd: Int32, buffer: Span[Byte, origin]) raises NetError -> Int:
    var status = _send_status(fd, buffer)
    if status.error_number != 0:
        raise _system_error("send", status.error_number)
    return status.value


def _send_to_status[
    origin: ImmOrigin
](
    fd: Int32,
    buffer: Span[Byte, origin],
    mut address: _RawSocketAddress,
) -> _SyscallStatus:
    _verify_abi_layouts()
    var flags: Int32 = 0
    comptime if _LINUX:
        flags = MSG_NOSIGNAL
    var result = external_call["sendto", c_ssize_t](
        c_int(fd),
        buffer.unsafe_ptr(),
        c_size_t(len(buffer)),
        c_int(flags),
        address.unsafe_ptr(),
        c_uint(address.length),
    )
    if result == -1:
        var error_number = _last_errno()
        return _SyscallStatus(value=-1, error_number=error_number)
    return _SyscallStatus(value=Int(result), error_number=0)


def _recv_from_status[
    origin: MutOrigin
](fd: Int32, buffer: Span[mut=True, Byte, origin]) -> _RawDatagramReceiveStatus:
    _verify_abi_layouts()
    var source = _RawSocketAddress()
    var source_pointer = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(source.unsafe_ptr())
    )
    var buffer_pointer = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(buffer.unsafe_ptr())
    )
    var received: Int
    var source_length: UInt32
    var message_flags: Int32

    comptime if _DARWIN:
        var vector = darwin._IOVec(
            base=buffer_pointer, length=UInt(len(buffer))
        )
        var vector_pointer = Pointer[darwin._IOVec, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=vector))
        )
        var message = darwin._MsgHdr(
            name=source_pointer,
            name_length=128,
            vectors=vector_pointer,
            vector_count=1,
            control=None,
            control_length=0,
            flags=0,
        )
        var result = external_call["recvmsg", c_ssize_t](
            c_int(fd), Pointer(to=message), c_int(0)
        )
        var error_number: Int32 = 0
        if result == -1:
            error_number = _last_errno()
        # The ABI erases origins, so keep the iovec storage live through recvmsg.
        _ = vector.length
        if result == -1:
            return _RawDatagramReceiveStatus(
                count=-1,
                source=source^,
                truncated=False,
                error_number=error_number,
            )
        received = Int(result)
        source_length = message.name_length
        message_flags = message.flags
    else:
        var vector = linux._IOVec(base=buffer_pointer, length=UInt(len(buffer)))
        var vector_pointer = Pointer[linux._IOVec, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=vector))
        )
        var message = linux._MsgHdr(
            name=source_pointer,
            name_length=128,
            vectors=vector_pointer,
            vector_count=1,
            control=None,
            control_length=0,
            flags=0,
        )
        var result = external_call["recvmsg", c_ssize_t](
            c_int(fd), Pointer(to=message), c_int(0)
        )
        var error_number: Int32 = 0
        if result == -1:
            error_number = _last_errno()
        # The ABI erases origins, so keep the iovec storage live through recvmsg.
        _ = vector.length
        if result == -1:
            return _RawDatagramReceiveStatus(
                count=-1,
                source=source^,
                truncated=False,
                error_number=error_number,
            )
        received = Int(result)
        source_length = message.name_length
        message_flags = message.flags

    if source_length > 128:
        return _RawDatagramReceiveStatus(
            count=-1,
            source=source^,
            truncated=False,
            error_number=0,
            address_too_large=True,
        )
    source.length = source_length
    var count = received if received <= len(buffer) else len(buffer)
    return _RawDatagramReceiveStatus(
        count=count,
        source=source^,
        truncated=(message_flags & MSG_TRUNC) != 0,
        error_number=0,
    )


def _set_socket_option_int(
    fd: Int32,
    level: Int32,
    option: Int32,
    value: Int32,
    operation: String,
) raises NetError:
    _verify_abi_layouts()
    var stored_value = value
    var result = external_call["setsockopt", c_int](
        c_int(fd),
        c_int(level),
        c_int(option),
        Pointer(to=stored_value),
        c_uint(size_of[Int32]()),
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error(operation, error_number)


def _get_socket_option_int(
    fd: Int32, level: Int32, option: Int32
) raises NetError -> Int32:
    _verify_abi_layouts()
    var value: Int32 = 0
    var length = UInt32(size_of[Int32]())
    var result = external_call["getsockopt", c_int](
        c_int(fd),
        c_int(level),
        c_int(option),
        Pointer(to=value),
        Pointer(to=length),
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("getsockopt", error_number)
    if length != UInt32(size_of[Int32]()):
        raise NetError(
            NetErrorKind.invalid_state(),
            "getsockopt",
            None,
            "invalid socket option length",
        )
    return value


def _bind(fd: Int32, mut address: _RawSocketAddress) raises NetError:
    _verify_abi_layouts()
    var result = external_call["bind", c_int](
        c_int(fd), address.unsafe_ptr(), c_uint(address.length)
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("bind", error_number)


def _listen(fd: Int32, backlog: Int32) raises NetError:
    _verify_abi_layouts()
    var result = external_call["listen", c_int](c_int(fd), c_int(backlog))
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("listen", error_number)


def _create_bound_socket(
    domain: Int32,
    socket_type: Int32,
    mut address: _RawSocketAddress,
    reuse_address: Bool,
    ipv6_only: Bool,
) raises NetError -> _OwnedFD:
    var fd = _socket(domain, socket_type, 0)
    if reuse_address:
        _set_socket_option_int(
            fd.raw(),
            SOL_SOCKET,
            SO_REUSEADDR,
            1,
            "setsockopt(SO_REUSEADDR)",
        )
    if ipv6_only:
        _set_socket_option_int(
            fd.raw(),
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            1,
            "setsockopt(IPV6_V6ONLY)",
        )
    _bind(fd.raw(), address)
    return fd^


def _connect_status(
    fd: Int32, mut address: _RawSocketAddress
) -> _SyscallStatus:
    _verify_abi_layouts()
    var result = external_call["connect", c_int](
        c_int(fd), address.unsafe_ptr(), c_uint(address.length)
    )
    if result == 0:
        return _SyscallStatus(value=0, error_number=0)
    var error_number = _last_errno()
    return _SyscallStatus(value=-1, error_number=error_number)


def _socket_error(fd: Int32) raises NetError -> Int32:
    return _get_socket_option_int(fd, SOL_SOCKET, SO_ERROR)


def _socket_name(fd: Int32, peer: Bool) raises NetError -> _RawSocketAddress:
    _verify_abi_layouts()
    var address = _RawSocketAddress()
    var length = UInt32(128)
    var result: Int32
    if peer:
        result = external_call["getpeername", c_int](
            c_int(fd), address.unsafe_ptr(), Pointer(to=length)
        )
    else:
        result = external_call["getsockname", c_int](
            c_int(fd), address.unsafe_ptr(), Pointer(to=length)
        )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error(
            "getpeername" if peer else "getsockname", error_number
        )
    if length > 128:
        raise NetError(
            NetErrorKind.invalid_state(),
            "getpeername" if peer else "getsockname",
            None,
            "socket address is too large",
        )
    address.length = length
    return address^


def _shutdown(fd: Int32, read_side: Bool, write_side: Bool) raises NetError:
    _verify_abi_layouts()
    if not read_side and not write_side:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "shutdown",
            None,
            "no shutdown direction selected",
        )
    var direction: Int32
    if read_side and write_side:
        direction = 2
    elif read_side:
        direction = 0
    else:
        direction = 1
    var result = external_call["shutdown", c_int](c_int(fd), c_int(direction))
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("shutdown", error_number)


def _wait(
    fd: Int32, events: Int16, deadline: _Deadline
) raises NetError -> Bool:
    _verify_abi_layouts()
    var descriptor = _PollFD(fd=fd, events=events, revents=0)
    while True:
        if deadline.expired():
            return False
        var timeout = Int32(-1)
        if not deadline.is_indefinite():
            var remaining = deadline.remaining_milliseconds()
            timeout = Int32.MAX
            if remaining < Int(Int32.MAX):
                timeout = Int32(remaining)
        var result: Int32
        comptime if _DARWIN:
            result = external_call["poll", c_int](
                Pointer(to=descriptor), c_uint(1), c_int(timeout)
            )
        else:
            result = external_call["poll", c_int](
                Pointer(to=descriptor), c_ulong(1), c_int(timeout)
            )
        if result > 0:
            var ready = events | POLLERR | POLLHUP | POLLNVAL
            return (descriptor.revents & ready) != 0
        if result == 0:
            if deadline.expired():
                return False
            continue
        var error_number = _last_errno()
        if error_number != EINTR:
            raise _system_error("poll", error_number)


def _wait_readable(fd: Int32, deadline: _Deadline) raises NetError -> Bool:
    return _wait(fd, POLLIN, deadline)


def _wait_writable(fd: Int32, deadline: _Deadline) raises NetError -> Bool:
    return _wait(fd, POLLOUT, deadline)
