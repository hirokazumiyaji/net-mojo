"""WebSocket configuration and owned message values."""

from net import Timeout
from net.error import NetError, NetErrorKind

comptime OPCODE_CONTINUATION: UInt8 = 0
comptime OPCODE_TEXT: UInt8 = 1
comptime OPCODE_BINARY: UInt8 = 2
comptime OPCODE_CLOSE: UInt8 = 8
comptime OPCODE_PING: UInt8 = 9
comptime OPCODE_PONG: UInt8 = 10


@fieldwise_init
struct WebSocketConfig(Copyable, Movable):
    var max_message_bytes: Int
    var max_frame_bytes: Int
    var max_fragment_count: Int
    var read_deadline: Timeout
    var write_deadline: Timeout
    var ping_interval: Timeout
    var validate_utf8: Bool
    var subprotocols: List[String]

    @staticmethod
    def default() -> Self:
        return Self(
            1_048_576,
            1_048_576,
            64,
            Timeout.nanoseconds(30_000_000_000),
            Timeout.nanoseconds(10_000_000_000),
            Timeout.nanoseconds(0),
            True,
            List[String](),
        )

    def _validate(self) raises NetError:
        if (
            self.max_message_bytes < 1
            or self.max_frame_bytes < 1
            or self.max_fragment_count < 1
            or self.read_deadline._value == 0
            or self.write_deadline._value == 0
        ):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket config",
                None,
                "limits and read/write deadlines must be positive",
            )
        for protocol in self.subprotocols:
            if not _valid_protocol(protocol):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "WebSocket config",
                    None,
                    "subprotocol must be a nonempty HTTP token",
                )


@fieldwise_init
struct WebSocketMessage(Movable):
    var opcode: UInt8
    var payload: List[Byte]


@fieldwise_init
struct WebSocketCloseInfo(Copyable, Movable):
    var code: UInt16
    var reason: String


def _valid_protocol(token: StringSlice) -> Bool:
    if token.byte_length() == 0:
        return False
    for byte in token.as_bytes():
        if (
            (byte >= 48 and byte <= 57)
            or (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
        ):
            continue
        var found = False
        for allowed in "!#$%&'*+-.^_`|~".as_bytes():
            if byte == allowed:
                found = True
        if not found:
            return False
    return True
