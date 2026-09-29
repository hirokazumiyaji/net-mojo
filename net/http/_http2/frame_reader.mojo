"""Incremental bounded reader for one owned HTTP/2 frame."""

from .frame import parse_frame


@fieldwise_init
struct Http2FrameReadResult(Movable):
    var kind: UInt8
    var consumed: Int
    var frame_type: UInt8
    var flags: UInt8
    var stream_id: UInt32
    var payload: List[Byte]

    @staticmethod
    def need_more(consumed: Int) -> Self:
        return Self(
            kind=1,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=UInt32(0),
            payload=List[Byte](),
        )

    @staticmethod
    def frame(
        consumed: Int,
        frame_type: UInt8,
        flags: UInt8,
        stream_id: UInt32,
        var payload: List[Byte],
    ) -> Self:
        return Self(
            kind=2,
            consumed=consumed,
            frame_type=frame_type,
            flags=flags,
            stream_id=stream_id,
            payload=payload^,
        )

    @staticmethod
    def error(consumed: Int) -> Self:
        return Self(
            kind=3,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=UInt32(0),
            payload=List[Byte](),
        )

    def is_need_more(self) -> Bool:
        return self.kind == 1

    def is_frame(self) -> Bool:
        return self.kind == 2

    def is_error(self) -> Bool:
        return self.kind == 3


struct Http2FrameReader(Movable):
    var _max_frame_size: Int
    var _frame: List[Byte]
    var _failed: Bool

    def __init__(out self, max_frame_size: Int = 16384):
        self._max_frame_size = max_frame_size
        self._frame = List[Byte]()
        self._failed = max_frame_size < 0 or max_frame_size > 0xFFFFFF

    def assembling_headers_stream(self) -> UInt32:
        """Stream id of an incomplete HEADERS frame, else 0.

        Exposed so sessions can arm the header deadline as soon as the
        frame type byte identifies HEADERS, before the full 9-byte header
        or payload is buffered.
        """
        if self._failed or len(self._frame) < 4:
            return UInt32(0)
        if self._frame[3] != Byte(1):
            return UInt32(0)
        if len(self._frame) < 9:
            # Type known; stream id not yet complete. Nonzero signals arming.
            return UInt32(0xFFFFFFFF)
        var stream_word = (
            (UInt32(self._frame[5]) << 24)
            | (UInt32(self._frame[6]) << 16)
            | (UInt32(self._frame[7]) << 8)
            | UInt32(self._frame[8])
        )
        return stream_word & UInt32(0x7FFFFFFF)

    def consume[
        origin: Origin
    ](mut self, data: Span[Byte, origin]) -> Http2FrameReadResult:
        if self._failed:
            return Http2FrameReadResult.error(0)

        var consumed = 0
        while consumed < len(data):
            self._frame.append(data[consumed])
            consumed += 1
            var frame = parse_frame(Span(self._frame), self._max_frame_size)
            if frame.is_error():
                self._failed = True
                return Http2FrameReadResult.error(consumed)
            if not frame.is_complete():
                continue

            var payload = List[Byte]()
            payload.reserve(frame.payload_length)
            for i in range(frame.payload_length):
                payload.append(self._frame[9 + i])
            self._frame.clear()
            return Http2FrameReadResult.frame(
                consumed,
                frame.frame_type,
                frame.flags,
                frame.stream_id,
                payload^,
            )

        return Http2FrameReadResult.need_more(consumed)

    def is_failed(self) -> Bool:
        return self._failed
