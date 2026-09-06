@fieldwise_init
struct NetErrorKind(Copyable, Equatable, Hashable, Writable):
    var value: UInt8

    @staticmethod
    def invalid_address() -> Self:
        return Self(value=0)

    @staticmethod
    def invalid_argument() -> Self:
        return Self(value=1)

    @staticmethod
    def resolution_failed() -> Self:
        return Self(value=2)

    @staticmethod
    def system_error() -> Self:
        return Self(value=3)

    @staticmethod
    def timeout() -> Self:
        return Self(value=4)

    @staticmethod
    def closed() -> Self:
        return Self(value=5)

    @staticmethod
    def invalid_state() -> Self:
        return Self(value=6)

    @staticmethod
    def unsupported() -> Self:
        return Self(value=7)

    def write_to[W: Writer](self, mut writer: W):
        if self == Self.invalid_address():
            writer.write("invalid_address")
        elif self == Self.invalid_argument():
            writer.write("invalid_argument")
        elif self == Self.resolution_failed():
            writer.write("resolution_failed")
        elif self == Self.system_error():
            writer.write("system_error")
        elif self == Self.timeout():
            writer.write("timeout")
        elif self == Self.closed():
            writer.write("closed")
        elif self == Self.invalid_state():
            writer.write("invalid_state")
        elif self == Self.unsupported():
            writer.write("unsupported")
        else:
            writer.write("unknown")


struct NetError(Copyable, Movable, Writable):
    var kind: NetErrorKind
    var operation: String
    var errno: Optional[Int]
    var message: String
    var resolver_status: Optional[Int]

    def __init__(
        out self,
        kind: NetErrorKind,
        operation: String,
        errno: Optional[Int],
        message: String,
        resolver_status: Optional[Int] = None,
    ):
        self.kind = kind.copy()
        self.operation = String(operation)
        self.errno = errno.copy()
        self.message = String(message)
        self.resolver_status = resolver_status.copy()

    def is_timeout(self) -> Bool:
        return self.kind == NetErrorKind.timeout()

    def has_errno(self, value: Int32) -> Bool:
        if not self.errno:
            return False
        return Int32(self.errno.value()) == value

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.operation)
        writer.write(": ")
        writer.write(self.message)
        if self.errno:
            writer.write(" (errno ")
            writer.write(self.errno.value())
            writer.write(")")
        elif self.resolver_status:
            writer.write(" (resolver status ")
            writer.write(self.resolver_status.value())
            writer.write(")")


def _timeout_error(operation: String) -> NetError:
    return NetError(
        NetErrorKind.timeout(), operation, None, "operation timed out"
    )


def _invalid_address_error(operation: String, message: String) -> NetError:
    return NetError(NetErrorKind.invalid_address(), operation, None, message)


def _invalid_backlog_error(operation: String) -> NetError:
    return NetError(
        NetErrorKind.invalid_argument(),
        operation,
        None,
        "backlog is out of range",
    )
