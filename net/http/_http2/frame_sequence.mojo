"""HTTP/2 connection sequencing for header-block continuation frames."""

from .frame import FrameParseResult


struct Http2ContinuationSequence(Movable):
    var _continuation_stream_id: UInt32
    var _waiting_for_continuation: Bool
    var _failed: Bool

    def __init__(out self):
        self._continuation_stream_id = UInt32(0)
        self._waiting_for_continuation = False
        self._failed = False

    def accept(mut self, frame: FrameParseResult) -> Bool:
        if self._failed or not frame.is_complete():
            self._failed = True
            return False

        if frame.frame_type == Byte(9):
            if (
                not self._waiting_for_continuation
                or frame.stream_id != self._continuation_stream_id
            ):
                self._failed = True
                return False
            if (frame.flags & Byte(4)) != Byte(0):
                self._waiting_for_continuation = False
                self._continuation_stream_id = UInt32(0)
            return True

        if (
            self._waiting_for_continuation
            or frame.frame_type == Byte(5)
            or (frame.frame_type == Byte(1) and frame.stream_id == UInt32(0))
        ):
            self._failed = True
            return False

        if frame.frame_type == Byte(1) and (frame.flags & Byte(4)) == Byte(0):
            self._waiting_for_continuation = True
            self._continuation_stream_id = frame.stream_id
        return True
