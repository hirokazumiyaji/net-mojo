comptime AF_INET: Int32 = 2
comptime AF_INET6: Int32 = 30
comptime AF_UNIX: Int32 = 1
comptime SOCK_STREAM: Int32 = 1
comptime SOCK_DGRAM: Int32 = 2
comptime SOCK_NONBLOCK: Int32 = 0
comptime SOCK_CLOEXEC: Int32 = 0
comptime SOL_SOCKET: Int32 = 0xFFFF
comptime SO_ERROR: Int32 = 0x1007
comptime SO_REUSEADDR: Int32 = 0x0004
comptime SO_KEEPALIVE: Int32 = 0x0008
comptime SO_RCVBUF: Int32 = 0x1002
comptime SO_SNDBUF: Int32 = 0x1001
comptime SO_LINGER: Int32 = 0x0080
comptime SO_NOSIGPIPE: Int32 = 0x1022
comptime SOMAXCONN: Int32 = 128
comptime IPPROTO_TCP: Int32 = 6
comptime TCP_NODELAY: Int32 = 0x01
comptime TCP_KEEPALIVE: Int32 = 0x10
comptime TCP_KEEPINTVL: Int32 = 0x101
comptime TCP_KEEPCNT: Int32 = 0x102
comptime IPPROTO_IPV6: Int32 = 41
comptime IPV6_V6ONLY: Int32 = 27
comptime POLLIN: Int16 = 0x001
comptime POLLOUT: Int16 = 0x004
comptime POLLERR: Int16 = 0x008
comptime POLLHUP: Int16 = 0x010
comptime POLLNVAL: Int16 = 0x020
comptime EINTR: Int32 = 4
comptime EAGAIN: Int32 = 35
comptime EWOULDBLOCK: Int32 = 35
comptime EAFNOSUPPORT: Int32 = 47
comptime EINPROGRESS: Int32 = 36
comptime MSG_NOSIGNAL: Int32 = 0x80000
comptime MSG_TRUNC: Int32 = 0x10
comptime F_GETFD: Int32 = 1
comptime F_SETFD: Int32 = 2
comptime F_GETFL: Int32 = 3
comptime F_SETFL: Int32 = 4
comptime FD_CLOEXEC: Int32 = 1
comptime O_NONBLOCK: Int32 = 0x4
comptime AI_NUMERICSERV: Int32 = 0x1000
comptime IF_NAMESIZE: Int = 16


@fieldwise_init
struct _SockaddrIn:
    var length: UInt8
    var family: UInt8
    var port: UInt16
    var address: UInt32
    var zero: Array[Byte, 8]


@fieldwise_init
struct _SockaddrIn6:
    var length: UInt8
    var family: UInt8
    var port: UInt16
    var flow_info: UInt32
    var address: Array[Byte, 16]
    var scope_id: UInt32


@fieldwise_init
struct _SockaddrUn:
    var length: UInt8
    var family: UInt8
    var path: Array[Byte, 104]


@fieldwise_init
struct _AddrInfo:
    var flags: Int32
    var family: Int32
    var socket_type: Int32
    var protocol: Int32
    var address_length: UInt32
    var canonical_name: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var address: Optional[Pointer[Byte, MutUntrackedOrigin]]
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
    var vector_count: Int32
    var control: Optional[Pointer[Byte, MutUntrackedOrigin]]
    var control_length: UInt32
    var flags: Int32
