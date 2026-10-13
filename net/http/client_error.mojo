"""HTTP client failures, independent of server response status codes."""

from net.error import NetError


struct ClientError(Copyable, Movable, Writable):
    comptime DIAL: UInt8 = 0
    comptime TLS: UInt8 = 1
    comptime WRITE: UInt8 = 2
    comptime READ: UInt8 = 3
    comptime PARSE: UInt8 = 4
    comptime REDIRECT: UInt8 = 5
    comptime TIMEOUT: UInt8 = 6
    comptime BODY_TOO_LARGE: UInt8 = 7
    comptime POOL_FULL: UInt8 = 8
    comptime CANCELED: UInt8 = 9

    var kind: UInt8
    var message: String
    var transport: Optional[NetError]

    def __init__(
        out self,
        kind: UInt8,
        var message: String,
        var transport: Optional[NetError] = None,
    ):
        self.kind = kind
        self.message = message^
        self.transport = transport^

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.message)
        if self.transport:
            writer.write(": ")
            writer.write(self.transport.value())

    @staticmethod
    def parse(var message: String) -> Self:
        return Self(kind=Self.PARSE, message=message^)
