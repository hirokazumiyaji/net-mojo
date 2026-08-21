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
from net.error import NetError, NetErrorKind
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
comptime SO_REUSEADDR: Int32 = 0x0004 if _DARWIN else 2
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
comptime EAFNOSUPPORT: Int32 = 47 if _DARWIN else 97
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


def _last_errno() -> Int32:
    return get_errno().value


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


def _fcntl_get(
    fd: Int32, command: Int32, operation: String
) raises NetError -> Int32:
    var result = _fcntl(c_int(fd), c_int(command), c_int(0))
    if result == -1:
        var error_number = _last_errno()
        raise _system_error(operation, error_number)
    return result


def _fcntl_set(
    fd: Int32, command: Int32, value: Int32, operation: String
) raises NetError:
    var result = _fcntl(c_int(fd), c_int(command), c_int(value))
    if result == -1:
        var error_number = _last_errno()
        raise _system_error(operation, error_number)


def _set_nonblocking_cloexec(fd: Int32) raises NetError:
    var status = _fcntl_get(fd, F_GETFL, "fcntl(F_GETFL)")
    if (status & O_NONBLOCK) == 0:
        _fcntl_set(fd, F_SETFL, status | O_NONBLOCK, "fcntl(F_SETFL)")
        status = _fcntl_get(fd, F_GETFL, "fcntl(F_GETFL)")
        if (status & O_NONBLOCK) == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "fcntl(F_SETFL)",
                None,
                "descriptor is blocking",
            )
    var descriptor = _fcntl_get(fd, F_GETFD, "fcntl(F_GETFD)")
    if (descriptor & FD_CLOEXEC) == 0:
        _fcntl_set(
            fd,
            F_SETFD,
            descriptor | FD_CLOEXEC,
            "fcntl(F_SETFD)",
        )
        descriptor = _fcntl_get(fd, F_GETFD, "fcntl(F_GETFD)")
        if (descriptor & FD_CLOEXEC) == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "fcntl(F_SETFD)",
                None,
                "close-on-exec is not set",
            )


def _set_no_sigpipe(fd: Int32) raises NetError:
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
            var error_number = _last_errno()
            raise _system_error("setsockopt(SO_NOSIGPIPE)", error_number)


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


def _accept(fd: Int32, stream: Bool = True) raises NetError -> _OwnedFD:
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
        raise _system_error("accept", error_number)
    var result = _OwnedFD(raw)
    comptime if _DARWIN:
        _set_nonblocking_cloexec(result.raw())
        if stream:
            _set_no_sigpipe(result.raw())
    return result^


def _recv[
    origin: MutOrigin
](fd: Int32, buffer: Span[mut=True, Byte, origin]) raises NetError -> Int:
    _verify_abi_layouts()
    var result = external_call["recv", c_ssize_t](
        c_int(fd), buffer.unsafe_ptr(), c_size_t(len(buffer)), c_int(0)
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("recv", error_number)
    return Int(result)


def _send[
    origin: ImmOrigin
](fd: Int32, buffer: Span[Byte, origin]) raises NetError -> Int:
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
        raise _system_error("send", error_number)
    return Int(result)


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


def _connect(fd: Int32, mut address: _RawSocketAddress) raises NetError -> Bool:
    _verify_abi_layouts()
    var result = external_call["connect", c_int](
        c_int(fd), address.unsafe_ptr(), c_uint(address.length)
    )
    if result == 0:
        return True
    var error_number = _last_errno()
    if error_number == EINPROGRESS or error_number == EINTR:
        return False
    raise _system_error("connect", error_number)


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
        var remaining = deadline.remaining_milliseconds()
        var timeout = Int32.MAX
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
