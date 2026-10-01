"""HTTP/2 WINDOW_UPDATE frame validation."""

from .frame import FrameParseResult
from .flow_window import Http2FlowWindow


@fieldwise_init
struct WindowUpdateFrameResult(Movable):
    var kind: UInt8
    var stream_id: UInt32
    var increment: UInt32

    @staticmethod
    def valid(stream_id: UInt32, increment: UInt32) -> Self:
        return Self(kind=1, stream_id=stream_id, increment=increment)

    @staticmethod
    def error() -> Self:
        return Self(kind=2, stream_id=UInt32(0), increment=UInt32(0))

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def apply_to(mut self, mut window: Http2FlowWindow) -> Bool:
        if not self.is_valid():
            return False
        return window.apply_window_update(Int(self.increment))


def parse_window_update_frame[
    origin: Origin
](
    frame: FrameParseResult, payload: Span[Byte, origin]
) -> WindowUpdateFrameResult:
    if (
        not frame.is_complete()
        or frame.frame_type != Byte(8)
        or frame.payload_length != 4
        or len(payload) != 4
    ):
        return WindowUpdateFrameResult.error()

    var increment = (
        (UInt32(payload[0]) << 24)
        | (UInt32(payload[1]) << 16)
        | (UInt32(payload[2]) << 8)
        | UInt32(payload[3])
    ) & UInt32(0x7FFFFFFF)
    if increment == UInt32(0):
        return WindowUpdateFrameResult.error()
    return WindowUpdateFrameResult.valid(frame.stream_id, increment)
