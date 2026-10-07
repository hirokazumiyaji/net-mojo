"""Bounded assembly of HTTP/2 HEADERS and CONTINUATION payloads."""

from .frame import FrameParseResult


@fieldwise_init
struct HeaderBlockResult(Movable):
    var kind: Int

    @staticmethod
    def pending() -> Self:
        return Self(kind=0)

    @staticmethod
    def complete() -> Self:
        return Self(kind=1)

    @staticmethod
    def error() -> Self:
        return Self(kind=2)

    def is_pending(self) -> Bool:
        return self.kind == 0

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


struct Http2HeaderBlock(Movable):
    var max_compressed_size: Int
    var max_continuation_frames: Int
    var stream_id: UInt32
    var end_stream: Bool
    var pending: Bool
    var failed: Bool
    var continuation_count: Int
    var bytes: List[Byte]

    def __init__(
        out self,
        max_compressed_size: Int,
        max_continuation_frames: Int = 32,
    ):
        self.max_compressed_size = max_compressed_size
        self.max_continuation_frames = max_continuation_frames
        self.stream_id = UInt32(0)
        self.end_stream = False
        self.pending = False
        self.failed = max_compressed_size < 0 or max_continuation_frames < 0
        self.continuation_count = 0
        self.bytes = List[Byte]()

    def begin[
        origin: Origin
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, origin],
    ) -> HeaderBlockResult:
        if (
            self.failed
            or self.pending
            or not frame.is_complete()
            or frame.frame_type != Byte(1)
            or frame.stream_id == UInt32(0)
            or frame.payload_length != len(payload)
        ):
            self.failed = True
            self.pending = False
            return HeaderBlockResult.error()

        self.bytes.clear()
        self.continuation_count = 0
        self.stream_id = frame.stream_id
        self.end_stream = (frame.flags & Byte(1)) != Byte(0)
        var fragment = Self._headers_fragment(frame.flags, payload)
        if fragment.kind != 0:
            self.failed = True
            return HeaderBlockResult.error()

        if not self._append(payload, fragment.start, fragment.end):
            self.failed = True
            return HeaderBlockResult.error()

        if (frame.flags & Byte(4)) != Byte(0):
            return HeaderBlockResult.complete()
        self.pending = True
        return HeaderBlockResult.pending()

    def continue_with[
        origin: Origin
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, origin],
    ) -> HeaderBlockResult:
        if (
            self.failed
            or not self.pending
            or not frame.is_complete()
            or frame.frame_type != Byte(9)
            or frame.stream_id != self.stream_id
            or frame.payload_length != len(payload)
        ):
            self.failed = True
            self.pending = False
            return HeaderBlockResult.error()

        self.continuation_count += 1
        if self.continuation_count > self.max_continuation_frames:
            self.failed = True
            self.pending = False
            return HeaderBlockResult.error()

        if not self._append(payload, 0, len(payload)):
            self.failed = True
            self.pending = False
            return HeaderBlockResult.error()

        if (frame.flags & Byte(4)) != Byte(0):
            self.pending = False
            return HeaderBlockResult.complete()
        return HeaderBlockResult.pending()

    def compressed_block(self) -> List[Byte]:
        return self.bytes.copy()

    def _append[
        origin: Origin
    ](mut self, payload: Span[Byte, origin], start: Int, end: Int) -> Bool:
        if start < 0 or end < start or end > len(payload):
            return False
        var fragment_length = end - start
        if fragment_length > self.max_compressed_size - len(self.bytes):
            return False
        self.bytes.extend(payload[start:end])
        return True

    @staticmethod
    def _headers_fragment[
        origin: Origin
    ](flags: UInt8, payload: Span[Byte, origin]) -> HeaderFragment:
        var start = 0
        var end = len(payload)
        if (flags & Byte(8)) != Byte(0):
            if end == 0:
                return HeaderFragment.error()
            var padding = Int(payload[0])
            start = 1
            if padding > end - start:
                return HeaderFragment.error()
            end -= padding
        if (flags & Byte(0x20)) != Byte(0):
            if end - start < 5:
                return HeaderFragment.error()
            start += 5
        return HeaderFragment.complete(start, end)


@fieldwise_init
struct HeaderFragment(Movable):
    var kind: Int
    var start: Int
    var end: Int

    @staticmethod
    def error() -> Self:
        return Self(kind=1, start=0, end=0)

    @staticmethod
    def complete(start: Int, end: Int) -> Self:
        return Self(kind=0, start=start, end=end)
