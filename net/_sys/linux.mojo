from std.sys import CompilationTarget

comptime AF_INET: Int32 = 2
comptime AF_INET6: Int32 = 10
comptime AF_UNIX: Int32 = 1
comptime SOCK_STREAM: Int32 = 1
comptime SOCK_DGRAM: Int32 = 2
comptime SOCK_NONBLOCK: Int32 = 0x800
comptime SOCK_CLOEXEC: Int32 = 0x80000
comptime SOL_SOCKET: Int32 = 1
comptime SO_ERROR: Int32 = 4
comptime SO_REUSEADDR: Int32 = 2
comptime SO_KEEPALIVE: Int32 = 9
comptime SO_RCVBUF: Int32 = 8
comptime SO_SNDBUF: Int32 = 7
comptime SO_LINGER: Int32 = 13
comptime SOMAXCONN: Int32 = 4096
comptime IPPROTO_TCP: Int32 = 6
comptime TCP_NODELAY: Int32 = 1
comptime TCP_KEEPIDLE: Int32 = 4
comptime TCP_KEEPINTVL: Int32 = 5
comptime TCP_KEEPCNT: Int32 = 6
comptime IPPROTO_IPV6: Int32 = 41
comptime IPV6_V6ONLY: Int32 = 26
comptime POLLIN: Int16 = 0x001
comptime POLLOUT: Int16 = 0x004
comptime POLLERR: Int16 = 0x008
comptime POLLHUP: Int16 = 0x010
comptime POLLNVAL: Int16 = 0x020
comptime EINTR: Int32 = 4
comptime EAGAIN: Int32 = 11
comptime EWOULDBLOCK: Int32 = 11
comptime ECONNREFUSED: Int32 = 111
comptime ECONNRESET: Int32 = 104
comptime EPIPE: Int32 = 32
comptime EAFNOSUPPORT: Int32 = 97
comptime EINPROGRESS: Int32 = 115
comptime MSG_NOSIGNAL: Int32 = 0x4000
comptime MSG_TRUNC: Int32 = 0x20
comptime F_GETFD: Int32 = 1
comptime F_SETFD: Int32 = 2
comptime F_GETFL: Int32 = 3
comptime F_SETFL: Int32 = 4
comptime FD_CLOEXEC: Int32 = 1
comptime O_NONBLOCK: Int32 = 0x800
comptime AI_NUMERICSERV: Int32 = 0x400
comptime IF_NAMESIZE: Int = 16

# --- epoll event queue (Phase 4) ---
# struct epoll_event { uint32_t events; epoll_data_t data; } has a
# per-arch layout: glibc defines __EPOLL_PACKED only for __x86_64__
# (i386 ABI compat), giving events@0 (4B), data@4 (8B), size 12,
# align 4. On aarch64 it is naturally aligned: events@0 (4B), 4B
# padding, data@8 (8B), size 16, align 8. NEON exists only on ARM, so
# a non-NEON target means x86-64 here (64-bit targets only).
comptime EPOLL_CLOEXEC: Int32 = 0x80000
comptime EPOLL_CTL_ADD: Int32 = 1
comptime EPOLL_CTL_DEL: Int32 = 2
comptime EPOLL_CTL_MOD: Int32 = 3
comptime EPOLLIN: UInt32 = 0x1
comptime EPOLLOUT: UInt32 = 0x4
comptime EPOLLERR: UInt32 = 0x8
comptime EPOLLHUP: UInt32 = 0x10
comptime EPOLLRDHUP: UInt32 = 0x2000


@fieldwise_init
struct _EpollEventPacked(Copyable, ImplicitlyCopyable, Movable):
    var events: UInt32
    var data_lo: UInt32
    var data_hi: UInt32


@fieldwise_init
struct _EpollEventAligned(Copyable, ImplicitlyCopyable, Movable):
    var events: UInt32
    var _reserved: UInt32
    var data: UInt64


comptime _EPOLL_PACKED: Bool = not CompilationTarget.has_neon()
# u32-word stride and data offset for the ready batch and ctl buffers.
# Packed (x86-64): [events, data_lo, data_hi]. Aligned (aarch64):
# [events, pad, data_lo, data_hi].
comptime _EPOLL_STRIDE_U32: Int = 3 if _EPOLL_PACKED else 4
comptime _EPOLL_DATA_U32: Int = 1 if _EPOLL_PACKED else 2


@fieldwise_init
struct _SockaddrIn:
    var family: UInt16
    var port: UInt16
    var address: UInt32
    var zero: Array[Byte, 8]


@fieldwise_init
struct _SockaddrIn6:
    var family: UInt16
    var port: UInt16
    var flow_info: UInt32
    var address: Array[Byte, 16]
    var scope_id: UInt32


@fieldwise_init
struct _SockaddrUn:
    var family: UInt16
    var path: Array[Byte, 108]


@fieldwise_init
struct _AddrInfo:
    var flags: Int32
    var family: Int32
    var socket_type: Int32
    var protocol: Int32
    var address_length: UInt32
    var address: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var canonical_name: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var next: Optional[Pointer[Byte, MutUntrackedOrigin]]


@fieldwise_init
struct _IOVec:
    var base: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var length: UInt


@fieldwise_init
struct _MsgHdr:
    var name: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var name_length: UInt32
    var vectors: Optional[Pointer[_IOVec, MutUntrackedOrigin]]
    var vector_count: UInt
    var control: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var control_length: UInt
    var flags: Int32
