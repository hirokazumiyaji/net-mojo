"""Bounded, socket-independent HTTP/2 frame encoding."""


@fieldwise_init
struct FrameEncodeResult(Movable):
    var kind: UInt8
    var wire: List[Byte]
    var error_code: UInt32

    @staticmethod
    def complete(var wire: List[Byte]) -> Self:
        return Self(kind=1, wire=wire^, error_code=UInt32(0))

    @staticmethod
    def failure(error_code: UInt32 = UInt32(1)) -> Self:
        return Self(kind=2, wire=List[Byte](), error_code=error_code)

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def encode_frame[
    origin: Origin
](
    frame_type: UInt8,
    flags: UInt8,
    stream_id: UInt32,
    payload: Span[Byte, origin],
    max_frame_size: Int = 16384,
) -> FrameEncodeResult:
    if (
        max_frame_size < 0
        or max_frame_size > 0xFFFFFF
        or len(payload) > max_frame_size
        or stream_id > UInt32(0x7FFFFFFF)
    ):
        return FrameEncodeResult.failure()

    var payload_length = len(payload)
    var wire = List[Byte]()
    wire.reserve(9 + payload_length)
    wire.append(Byte((payload_length >> 16) & 0xFF))
    wire.append(Byte((payload_length >> 8) & 0xFF))
    wire.append(Byte(payload_length & 0xFF))
    wire.append(Byte(frame_type))
    wire.append(Byte(flags))
    wire.append(Byte((stream_id >> 24) & UInt32(0x7F)))
    wire.append(Byte((stream_id >> 16) & UInt32(0xFF)))
    wire.append(Byte((stream_id >> 8) & UInt32(0xFF)))
    wire.append(Byte(stream_id & UInt32(0xFF)))
    for i in range(payload_length):
        wire.append(payload[i])
    return FrameEncodeResult.complete(wire^)
