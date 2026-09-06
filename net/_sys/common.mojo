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
comptime SO_KEEPALIVE: Int32 = (
    darwin.SO_KEEPALIVE if _DARWIN else linux.SO_KEEPALIVE
)
comptime SO_RCVBUF: Int32 = (darwin.SO_RCVBUF if _DARWIN else linux.SO_RCVBUF)
comptime SO_SNDBUF: Int32 = (darwin.SO_SNDBUF if _DARWIN else linux.SO_SNDBUF)
comptime SO_LINGER: Int32 = (darwin.SO_LINGER if _DARWIN else linux.SO_LINGER)
comptime IPPROTO_TCP: Int32 = (
    darwin.IPPROTO_TCP if _DARWIN else linux.IPPROTO_TCP
)
comptime TCP_NODELAY: Int32 = (
    darwin.TCP_NODELAY if _DARWIN else linux.TCP_NODELAY
)
# The idle-time knob is TCP_KEEPALIVE on Darwin and TCP_KEEPIDLE on Linux.
comptime TCP_KEEPIDLE: Int32 = (
    darwin.TCP_KEEPALIVE if _DARWIN else linux.TCP_KEEPIDLE
)
comptime TCP_KEEPINTVL: Int32 = (
    darwin.TCP_KEEPINTVL if _DARWIN else linux.TCP_KEEPINTVL
)
comptime TCP_KEEPCNT: Int32 = (
    darwin.TCP_KEEPCNT if _DARWIN else linux.TCP_KEEPCNT
)
comptime SOMAXCONN: Int32 = (darwin.SOMAXCONN if _DARWIN else linux.SOMAXCONN)
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
comptime ECONNREFUSED: Int32 = (
    darwin.ECONNREFUSED if _DARWIN else linux.ECONNREFUSED
)
comptime ECONNRESET: Int32 = (
    darwin.ECONNRESET if _DARWIN else linux.ECONNRESET
)
comptime EPIPE: Int32 = darwin.EPIPE if _DARWIN else linux.EPIPE
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
comptime _SOCKADDR_CAPACITY: Int = 128


struct _ResolverHints(Movable):
    var _storage: Array[UInt64, 6]

    def __init__(out self, socket_type: Int32):
        _verify_abi_layouts()
        self._storage = Array[UInt64, 6](fill=0)
        # Both addrinfo layouts share the first five fields
        # (flags/family/socket_type/protocol/address_length) and the
        # remaining pointer fields are all None, so field order differences
        # (address vs canonical_name) do not matter. Write the two nonzero
        # fields directly instead of building a platform struct + 48B copy.
        var destination = Pointer(to=self).unsafe_bitcast[Byte]()
        var flags = AI_NUMERICSERV
        destination[unsafe_offset=0] = Byte(flags & 0xFF)
        destination[unsafe_offset=1] = Byte((flags >> 8) & 0xFF)
        destination[unsafe_offset=2] = Byte((flags >> 16) & 0xFF)
        destination[unsafe_offset=3] = Byte((flags >> 24) & 0xFF)
        destination[unsafe_offset=8] = Byte(socket_type & 0xFF)
        destination[unsafe_offset=9] = Byte((socket_type >> 8) & 0xFF)
        destination[unsafe_offset=10] = Byte((socket_type >> 16) & 0xFF)
        destination[unsafe_offset=11] = Byte((socket_type >> 24) & 0xFF)

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

    def take(mut self) -> Self:
        # Move-only storage cannot be moved out of a borrowed struct, so
        # copy the words and reset the source instead. The payload is at
        # most 28 bytes; the copy costs nothing next to the syscall that
        # produced it.
        var out = Self()
        for i in range(16):
            out._storage[i] = self._storage[i]
            self._storage[i] = 0
        out.length = self.length
        self.length = 0
        return out^


def _invalid_unix_path() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "unix address",
        None,
        "invalid Unix socket path",
    )


def _validate_unix_path(value: StringSlice) raises NetError:
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


def _unix_address_from_raw[
    origin: MutOrigin
](raw: Pointer[Byte, origin], length: UInt32) raises NetError -> String:
    var path_offset = 2
    var path_max = UNIX_PATH_MAX
    comptime if _DARWIN:
        if length < 2 or length > UInt32(2 + path_max):
            raise _invalid_unix_path()
        if UInt16(raw[unsafe_offset=1]) != UInt16(AF_UNIX):
            raise _invalid_unix_path()
    else:
        if length < 2 or length > UInt32(2 + path_max):
            raise _invalid_unix_path()
        var family = UInt16(raw[unsafe_offset=0]) | (
            UInt16(raw[unsafe_offset=1]) << 8
        )
        if family != UInt16(AF_UNIX):
            raise _invalid_unix_path()
    var path_length = Int(length) - path_offset
    var bytes = List[Byte]()
    for i in range(path_length):
        var byte = raw[unsafe_offset=path_offset + i]
        if byte == 0:
            break
        bytes.append(byte)
    return String(from_utf8_lossy=Span(bytes))


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
    var peer: _RawSocketAddress
    var error_number: Int32
    var invalid_state: Bool

    def __init__(
        out self,
        var fd: _OwnedFD,
        var peer: _RawSocketAddress,
        error_number: Int32,
        invalid_state: Bool = False,
    ):
        self.fd = fd^
        self.peer = peer^
        self.error_number = error_number
        self.invalid_state = invalid_state

    def take_fd(mut self) -> _OwnedFD:
        return _OwnedFD(self.fd._take())

    def take_peer(mut self) -> _RawSocketAddress:
        return self.peer.take()


@fieldwise_init
struct _PollFD(Copyable, Movable):
    var fd: Int32
    var events: Int16
    var revents: Int16


def _verify_abi_layouts():
    # Linux uses the generic ABI on both x86_64 and aarch64: the errno
    # numbers, SOCK_*/O_* flags, and sockaddr/addrinfo/msghdr layouts in
    # net/_sys/linux.mojo match on either target (only alpha/mips/sparc
    # style ABIs differ), so any 64-bit Linux target is accepted.
    comptime assert (
        _DARWIN and CompilationTarget.is_apple_silicon() and is_64bit()
    ) or (
        _LINUX and is_64bit()
    ), "net supports only macOS arm64 and 64-bit Linux"
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
        size_of[_RawSocketAddress]() >= _SOCKADDR_CAPACITY
    ), "invalid raw socket address storage"
    comptime assert size_of[_SockaddrIn]() == 16, "invalid sockaddr_in ABI"
    comptime assert size_of[_SockaddrIn6]() == 28, "invalid sockaddr_in6 ABI"
    comptime assert size_of[_Linger]() == 8, "invalid linger ABI"
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


def _copy_c_string(address: Pointer[Byte, MutUntrackedOrigin]) -> String:
    var length = 0
    while length < 256 and address[unsafe_offset=length] != 0:
        length += 1
    var bytes = List[Byte]()
    for i in range(length):
        bytes.append(address[unsafe_offset=i])
    return String(from_utf8_lossy=Span(bytes))


def _strerror_text(error_number: Int32) -> String:
    # NOTE: declared with a bare pointer return to match the stdlib's own
    # strerror declaration (reached via std.tempfile); an
    # Optional-wrapped return type conflicts at compile time. strerror
    # never returns NULL on the supported targets (unknown codes yield
    # "Unknown error N"). strerror may use a static buffer and is not
    # guaranteed thread-safe; that is acceptable while net-mojo is
    # single-threaded by design, and must be revisited (strerror_r) if
    # threading support is ever added.
    var message = external_call["strerror", Pointer[Byte, MutUntrackedOrigin]](
        c_int(error_number)
    )
    return _copy_c_string(message)


def _system_error(operation: String, error_number: Int32) -> NetError:
    return NetError(
        NetErrorKind.system_error(),
        operation,
        Int(error_number),
        _strerror_text(error_number),
    )


def _unsupported_family(error: NetError) -> Bool:
    return error.has_errno(EAFNOSUPPORT)


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
comptime _CONNECT_FAILED: Int32 = 2


def _connect_disposition(error_number: Int32) -> Int32:
    if error_number == 0:
        return _CONNECT_SUCCEEDED
    # A non-blocking connect interrupted by a signal keeps going in the
    # kernel, exactly like EINPROGRESS: wait it out on the same socket
    # instead of opening a second one.
    if error_number == EINPROGRESS or error_number == EINTR:
        return _CONNECT_PENDING
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
    # Fresh descriptors start with file flags 0: read the status flags
    # once, set O_NONBLOCK when missing, then set FD_CLOEXEC
    # unconditionally. The kernel applies what it is told, so reading the
    # flags back to verify wastes two syscalls per descriptor.
    var status = _fcntl(c_int(fd), c_int(F_GETFL), c_int(0))
    if status == -1:
        return _SyscallStatus(value=-1, error_number=_last_errno())
    if (status & O_NONBLOCK) == 0:
        var set_status = _fcntl(
            c_int(fd), c_int(F_SETFL), c_int(status | O_NONBLOCK)
        )
        if set_status == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())

    var set_descriptor = _fcntl(c_int(fd), c_int(F_SETFD), c_int(FD_CLOEXEC))
    if set_descriptor == -1:
        return _SyscallStatus(value=-1, error_number=_last_errno())
    return _SyscallStatus(value=0, error_number=0)


def _no_sigpipe_status(fd: Int32) -> _SyscallStatus:
    comptime if _DARWIN:
        var enabled: Int32 = 1
        var result = external_call["setsockopt", c_int](
            c_int(fd),
            c_int(SOL_SOCKET),
            c_int(darwin.SO_NOSIGPIPE),
            Pointer(to=enabled),
            c_uint(size_of[Int32]()),
        )
        if result == -1:
            return _SyscallStatus(value=-1, error_number=_last_errno())
    return _SyscallStatus(value=0, error_number=0)


def _set_nonblocking_cloexec(fd: Int32) raises NetError:
    var status = _nonblocking_cloexec_status(fd)
    if status.error_number != 0:
        raise _system_error("fcntl", status.error_number)


def _set_no_sigpipe(fd: Int32) raises NetError:
    var status = _no_sigpipe_status(fd)
    if status.error_number != 0:
        raise _system_error("setsockopt(SO_NOSIGPIPE)", status.error_number)


def _socket(
    domain: Int32, socket_type: Int32, protocol: Int32
) raises NetError -> _OwnedFD:
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
    comptime if _DARWIN:
        # Linux sets SOCK_NONBLOCK | SOCK_CLOEXEC atomically above and
        # needs no follow-up fcntl calls.
        _set_nonblocking_cloexec(result.raw())
        if socket_type == SOCK_STREAM:
            _set_no_sigpipe(result.raw())
    return result^


def _accepted_fd_configuration_status(fd: Int32) -> _SyscallStatus:
    var status = _nonblocking_cloexec_status(fd)
    if status.value != 0:
        return status^
    comptime if _DARWIN:
        return _no_sigpipe_status(fd)
    return status^


def _accept_status(fd: Int32) -> _AcceptStatus:
    # The peer address rides along for free: accept fills the buffer as
    # part of the same syscall, so accept_with_address needs no extra
    # getpeername round trip.
    var peer = _RawSocketAddress()
    var peer_length = UInt32(_SOCKADDR_CAPACITY)
    var raw: Int32
    comptime if _LINUX:
        raw = external_call["accept4", c_int](
            c_int(fd),
            peer.unsafe_ptr(),
            Pointer(to=peer_length),
            c_int(SOCK_NONBLOCK | SOCK_CLOEXEC),
        )
    else:
        raw = external_call["accept", c_int](
            c_int(fd),
            peer.unsafe_ptr(),
            Pointer(to=peer_length),
        )
    if raw == -1:
        var error_number = _last_errno()
        return _AcceptStatus(_OwnedFD(-1), peer^, error_number)
    if peer_length > UInt32(_SOCKADDR_CAPACITY):
        return _AcceptStatus(
            _OwnedFD(raw),
            peer^,
            0,
            invalid_state=True,
        )
    peer.length = peer_length
    var result = _OwnedFD(raw)
    comptime if _DARWIN:
        var configuration = _accepted_fd_configuration_status(raw)
        if configuration.value != 0:
            return _AcceptStatus(result^, peer^, configuration.error_number)
    return _AcceptStatus(result^, peer^, 0)


def _recv_status[
    origin: MutOrigin
](fd: Int32, buffer: Span[mut=True, Byte, origin]) -> _SyscallStatus:
    var result = external_call["recv", c_ssize_t](
        c_int(fd), buffer.unsafe_ptr(), c_size_t(len(buffer)), c_int(0)
    )
    if result == -1:
        var error_number = _last_errno()
        return _SyscallStatus(value=-1, error_number=error_number)
    return _SyscallStatus(value=Int(result), error_number=0)


def _send_status[
    origin: ImmOrigin
](fd: Int32, buffer: Span[Byte, origin]) -> _SyscallStatus:
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


def _send_to_status[
    origin: ImmOrigin
](
    fd: Int32,
    buffer: Span[Byte, origin],
    mut address: _RawSocketAddress,
) -> _SyscallStatus:
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
    var source = _RawSocketAddress()
    var source_pointer = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(source.unsafe_ptr())
    )
    var buffer_pointer = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(buffer.unsafe_ptr())
    )
    var received: Int = -1
    var source_length: UInt32 = 0
    var message_flags: Int32 = 0
    var error_number: Int32 = 0
    var failed = False

    # Mojo 1.0 cannot use the comptime _IOVec/_MsgHdr aliases as nominal
    # types for construction (see #5 discussion), so only the msghdr/iovec
    # construction stays branched. The recvmsg call shape and all error /
    # tail handling are shared via outer locals.
    comptime if _DARWIN:
        var vector = darwin._IOVec(
            base=buffer_pointer, length=UInt(len(buffer))
        )
        var vector_pointer = Pointer[darwin._IOVec, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=vector))
        )
        var message = darwin._MsgHdr(
            name=source_pointer,
            name_length=UInt32(_SOCKADDR_CAPACITY),
            vectors=vector_pointer,
            vector_count=1,
            control=None,
            control_length=0,
            flags=0,
        )
        var result = external_call["recvmsg", c_ssize_t](
            c_int(fd), Pointer(to=message), c_int(0)
        )
        if result == -1:
            error_number = _last_errno()
            failed = True
        else:
            # The ABI erases origins, so keep the iovec storage live.
            _ = vector.length
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
            name_length=UInt32(_SOCKADDR_CAPACITY),
            vectors=vector_pointer,
            vector_count=1,
            control=None,
            control_length=0,
            flags=0,
        )
        var result = external_call["recvmsg", c_ssize_t](
            c_int(fd), Pointer(to=message), c_int(0)
        )
        if result == -1:
            error_number = _last_errno()
            failed = True
        else:
            # The ABI erases origins, so keep the iovec storage live.
            _ = vector.length
            received = Int(result)
            source_length = message.name_length
            message_flags = message.flags

    if failed:
        return _RawDatagramReceiveStatus(
            count=-1,
            source=source^,
            truncated=False,
            error_number=error_number,
        )

    if source_length > UInt32(_SOCKADDR_CAPACITY):
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


@fieldwise_init
struct _Linger(Copyable, Movable):
    var onoff: Int32
    var seconds: Int32


def _set_socket_option_int(
    fd: Int32,
    level: Int32,
    option: Int32,
    value: Int32,
    operation: String,
) raises NetError:
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


def _set_linger(
    fd: Int32, onoff: Int32, seconds: Int32, operation: String
) raises NetError:
    var value = _Linger(onoff=onoff, seconds=seconds)
    var result = external_call["setsockopt", c_int](
        c_int(fd),
        c_int(SOL_SOCKET),
        c_int(SO_LINGER),
        Pointer(to=value),
        c_uint(size_of[_Linger]()),
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error(operation, error_number)


def _get_linger(fd: Int32) raises NetError -> _Linger:
    var value = _Linger(onoff=0, seconds=0)
    var length = UInt32(size_of[_Linger]())
    var result = external_call["getsockopt", c_int](
        c_int(fd),
        c_int(SOL_SOCKET),
        c_int(SO_LINGER),
        Pointer(to=value),
        Pointer(to=length),
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("getsockopt", error_number)
    if length != UInt32(size_of[_Linger]()):
        raise NetError(
            NetErrorKind.invalid_state(),
            "getsockopt",
            None,
            "invalid socket option length",
        )
    return value^


def _bind(fd: Int32, mut address: _RawSocketAddress) raises NetError:
    var result = external_call["bind", c_int](
        c_int(fd), address.unsafe_ptr(), c_uint(address.length)
    )
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("bind", error_number)


def _listen(fd: Int32, backlog: Int32) raises NetError:
    var result = external_call["listen", c_int](c_int(fd), c_int(backlog))
    if result == -1:
        var error_number = _last_errno()
        raise _system_error("listen", error_number)


def _create_bound_socket(
    domain: Int32,
    socket_type: Int32,
    mut address: _RawSocketAddress,
    reuse_address: Bool,
    v6only: Bool,
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
    if domain == AF_INET6:
        _set_socket_option_int(
            fd.raw(),
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            Int32(1) if v6only else Int32(0),
            "setsockopt(IPV6_V6ONLY)",
        )
    _bind(fd.raw(), address)
    return fd^


def _connect_status(
    fd: Int32, mut address: _RawSocketAddress
) -> _SyscallStatus:
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
    var address = _RawSocketAddress()
    var length = UInt32(_SOCKADDR_CAPACITY)
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
    if length > UInt32(_SOCKADDR_CAPACITY):
        raise NetError(
            NetErrorKind.invalid_state(),
            "getpeername" if peer else "getsockname",
            None,
            "socket address is too large",
        )
    address.length = length
    return address^


def _shutdown(fd: Int32, read_side: Bool, write_side: Bool) raises NetError:
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


def _poll_timeout_ms(deadline: _Deadline) -> Int32:
    if deadline.is_indefinite():
        return -1
    var remaining = deadline.remaining_milliseconds()
    if remaining < Int(Int32.MAX):
        return Int32(remaining)
    return Int32.MAX


def _poll_multiple(
    mut entries: List[_PollFD], deadline: _Deadline
) raises NetError -> Int:
    """Polls every entry at once, mirroring `_wait` timeout semantics.

    Returns the number of entries with a nonzero `revents`. An empty list
    returns 0 immediately. The poll is always attempted at least once, so
    an expired deadline still reports what is already ready instead of
    sleeping. `EINTR` restarts the wait against the same deadline instead
    of surfacing to the caller. `revents` is cleared up front so a caller
    never observes state left over from a previous wait.
    """
    if len(entries) == 0:
        return 0
    for i in range(len(entries)):
        entries[i].revents = 0
    while True:
        var timeout = _poll_timeout_ms(deadline)
        var result: Int32
        comptime if _DARWIN:
            result = external_call["poll", c_int](
                Pointer(to=entries[0]),
                c_uint(len(entries)),
                c_int(timeout),
            )
        else:
            result = external_call["poll", c_int](
                Pointer(to=entries[0]),
                c_ulong(len(entries)),
                c_int(timeout),
            )
        if result > 0:
            return Int(result)
        if result == 0:
            if deadline.expired():
                return 0
            continue
        var error_number = _last_errno()
        if error_number != EINTR:
            raise _system_error("poll", error_number)
        if deadline.expired():
            return 0


def _parse_backlog_limit(text: StringSlice) -> Optional[Int]:
    var bytes = text.as_bytes()
    var value = 0
    var digits = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if (
            byte == Byte(ord(" "))
            or byte == Byte(ord("\t"))
            or byte == Byte(ord("\n"))
            or byte == Byte(ord("\r"))
        ):
            continue
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return None
        digits += 1
        value = value * 10 + Int(byte - Byte(ord("0")))
        if value > Int(Int32.MAX):
            return None
    if digits == 0 or value < 1:
        return None
    return value


def _darwin_backlog_limit() -> Optional[Int]:
    var name = String("kern.ipc.somaxconn")
    var c_name = name.as_c_string_slice()
    var value: Int32 = 0
    var length = UInt64(size_of[Int32]())
    var result = external_call["sysctlbyname", c_int](
        c_name.unsafe_ptr(),
        Pointer(to=value),
        Pointer(to=length),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        c_size_t(0),
    )
    if result == -1:
        return None
    if length != UInt64(size_of[Int32]()) or value < 1:
        return None
    return Int(value)


def _linux_backlog_limit() -> Optional[Int]:
    try:
        var handle = open("/proc/sys/net/core/somaxconn", "r")
        return _parse_backlog_limit(handle.read())
    except:
        return None


def _kernel_backlog_limit() -> Optional[Int]:
    comptime if _DARWIN:
        return _darwin_backlog_limit()
    else:
        return _linux_backlog_limit()


def _default_listen_backlog() -> Int:
    var limit = _kernel_backlog_limit()
    if limit:
        return limit.value()
    return Int(SOMAXCONN)
