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
        writer.write(self.value)


struct NetError(Copyable, Movable, Writable):
    var kind: NetErrorKind
    var operation: String
    var errno: Optional[Int]
    var message: String

    def __init__(
        out self,
        kind: NetErrorKind,
        operation: String,
        errno: Optional[Int],
        message: String,
    ):
        self.kind = kind.copy()
        self.operation = String(operation)
        self.errno = errno
        self.message = String(message)

    def is_timeout(self) -> Bool:
        return self.kind == NetErrorKind.timeout()

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.operation)
        writer.write(": ")
        writer.write(self.message)
