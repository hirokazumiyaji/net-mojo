"""Bounded, socket-independent HTTP/2 frame parsing."""


@fieldwise_init
struct FrameParseResult(Movable):
    var kind: UInt8
    var frame_type: UInt8
    var flags: UInt8
    var stream_id: UInt32
    var payload_length: Int
    var consumed: Int
    var error_code: UInt32

    @staticmethod
    def need_more() -> Self:
        return Self(
            kind=0,
            frame_type=0,
            flags=0,
            stream_id=UInt32(0),
            payload_length=0,
            consumed=0,
            error_code=UInt32(0),
        )

    @staticmethod
    def complete(
        frame_type: UInt8,
        flags: UInt8,
        stream_id: UInt32,
        payload_length: Int,
    ) -> Self:
        return Self(
            kind=1,
            frame_type=frame_type,
            flags=flags,
            stream_id=stream_id,
            payload_length=payload_length,
            consumed=9 + payload_length,
            error_code=UInt32(0),
        )

    @staticmethod
    def failure(error_code: UInt32 = UInt32(1)) -> Self:
        return Self(
            kind=2,
            frame_type=0,
            flags=0,
            stream_id=UInt32(0),
            payload_length=0,
            consumed=0,
            error_code=error_code,
        )

    def is_need_more(self) -> Bool:
        return self.kind == 0

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def parse_frame[
    origin: Origin
](data: Span[Byte, origin], max_frame_size: Int = 16384) -> FrameParseResult:
    if max_frame_size < 0:
        return FrameParseResult.failure()
    if len(data) < 9:
        return FrameParseResult.need_more()

    var payload_length = (
        (Int(data[0]) << 16) | (Int(data[1]) << 8) | Int(data[2])
    )
    if payload_length > max_frame_size:
        return FrameParseResult.failure(UInt32(6))

    var stream_word = (
        (UInt32(data[5]) << 24)
        | (UInt32(data[6]) << 16)
        | (UInt32(data[7]) << 8)
        | UInt32(data[8])
    )
    if len(data) < 9 + payload_length:
        return FrameParseResult.need_more()

    return FrameParseResult.complete(
        data[3], data[4], stream_word & UInt32(0x7FFFFFFF), payload_length
    )
