"""HTTP/2 PING, RST_STREAM, and GOAWAY frames."""

from .frame import FrameParseResult
from .frame_encoder import FrameEncodeResult, encode_frame


@fieldwise_init
struct RstStreamFrameResult(Movable):
    var kind: UInt8
    var stream_id: UInt32
    var error_code: UInt32

    @staticmethod
    def valid(stream_id: UInt32, error_code: UInt32) -> Self:
        return Self(kind=1, stream_id=stream_id, error_code=error_code)

    @staticmethod
    def error() -> Self:
        return Self(kind=2, stream_id=UInt32(0), error_code=UInt32(0))

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


@fieldwise_init
struct PingFrameResult(Movable):
    var kind: UInt8
    var ack: Bool
    var opaque_data: List[Byte]

    @staticmethod
    def valid(ack: Bool, var opaque_data: List[Byte]) -> Self:
        return Self(kind=1, ack=ack, opaque_data=opaque_data^)

    @staticmethod
    def error() -> Self:
        return Self(kind=2, ack=False, opaque_data=List[Byte]())

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def is_ack(self) -> Bool:
        return self.ack

    def encode_ack(mut self) -> FrameEncodeResult:
        if not self.is_valid() or self.ack:
            return FrameEncodeResult.failure()
        return encode_frame(Byte(6), Byte(1), UInt32(0), Span(self.opaque_data))


@fieldwise_init
struct GoAwayFrameResult(Copyable):
    var kind: UInt8
    var last_stream_id: UInt32
    var error_code: UInt32

    @staticmethod
    def valid(last_stream_id: UInt32, error_code: UInt32) -> Self:
        return Self(
            kind=1, last_stream_id=last_stream_id, error_code=error_code
        )

    @staticmethod
    def error() -> Self:
        return Self(kind=2, last_stream_id=UInt32(0), error_code=UInt32(0))

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def parse_rst_stream_frame[
    origin: Origin
](frame: FrameParseResult, payload: Span[Byte, origin]) -> RstStreamFrameResult:
    if (
        not frame.is_complete()
        or frame.frame_type != Byte(3)
        or frame.stream_id == UInt32(0)
        or frame.payload_length != 4
        or len(payload) < 4
    ):
        return RstStreamFrameResult.error()

    var error_code = (
        (UInt32(payload[0]) << 24)
        | (UInt32(payload[1]) << 16)
        | (UInt32(payload[2]) << 8)
        | UInt32(payload[3])
    )
    return RstStreamFrameResult.valid(frame.stream_id, error_code)


def encode_rst_stream_frame(
    stream_id: UInt32, error_code: UInt32
) -> FrameEncodeResult:
    if stream_id == UInt32(0) or stream_id > UInt32(0x7FFFFFFF):
        return FrameEncodeResult.failure()
    var payload: List[Byte] = [
        Byte((error_code >> 24) & UInt32(0xFF)),
        Byte((error_code >> 16) & UInt32(0xFF)),
        Byte((error_code >> 8) & UInt32(0xFF)),
        Byte(error_code & UInt32(0xFF)),
    ]
    return encode_frame(Byte(3), Byte(0), stream_id, Span(payload))


def parse_ping_frame[
    origin: Origin
](frame: FrameParseResult, payload: Span[Byte, origin]) -> PingFrameResult:
    if (
        not frame.is_complete()
        or frame.frame_type != Byte(6)
        or frame.stream_id != UInt32(0)
        or frame.payload_length != 8
        or len(payload) < 8
    ):
        return PingFrameResult.error()

    return PingFrameResult.valid(
        (frame.flags & Byte(1)) != Byte(0), List[Byte](payload[:8])
    )


def parse_goaway_frame[
    origin: Origin
](frame: FrameParseResult, payload: Span[Byte, origin]) -> GoAwayFrameResult:
    if (
        not frame.is_complete()
        or frame.frame_type != Byte(7)
        or frame.stream_id != UInt32(0)
        or frame.payload_length < 8
        or len(payload) < frame.payload_length
    ):
        return GoAwayFrameResult.error()

    var last_stream_id = (
        (UInt32(payload[0]) << 24)
        | (UInt32(payload[1]) << 16)
        | (UInt32(payload[2]) << 8)
        | UInt32(payload[3])
    ) & UInt32(0x7FFFFFFF)
    var error_code = (
        (UInt32(payload[4]) << 24)
        | (UInt32(payload[5]) << 16)
        | (UInt32(payload[6]) << 8)
        | UInt32(payload[7])
    )
    return GoAwayFrameResult.valid(last_stream_id, error_code)


def encode_goaway_frame(
    last_stream_id: UInt32, error_code: UInt32
) -> FrameEncodeResult:
    if last_stream_id > UInt32(0x7FFFFFFF):
        return FrameEncodeResult.failure()
    var payload = List[Byte]()
    payload.append(Byte((last_stream_id >> 24) & UInt32(0x7F)))
    payload.append(Byte((last_stream_id >> 16) & UInt32(0xFF)))
    payload.append(Byte((last_stream_id >> 8) & UInt32(0xFF)))
    payload.append(Byte(last_stream_id & UInt32(0xFF)))
    payload.append(Byte((error_code >> 24) & UInt32(0xFF)))
    payload.append(Byte((error_code >> 16) & UInt32(0xFF)))
    payload.append(Byte((error_code >> 8) & UInt32(0xFF)))
    payload.append(Byte(error_code & UInt32(0xFF)))
    return encode_frame(Byte(7), Byte(0), UInt32(0), Span(payload))
