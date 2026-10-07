"""Connection-level dispatch for complete HTTP/2 frames."""

from .._deadline import now_ns
from .control_frames import (
    parse_goaway_frame,
    parse_ping_frame,
    parse_rst_stream_frame,
)
from .frame import FrameParseResult
from .frame_sequence import Http2ContinuationSequence
from .settings_frame import parse_settings_frame
from .settings_state import Http2PeerSettings, Http2PeerSettingsSnapshot
from .window_update import parse_window_update_frame

# Tumbling 1-second windows (reset at first event after prior window ends);
# not a sliding deque of timestamps.
comptime _RATE_WINDOW_NS: Int = 1_000_000_000


@fieldwise_init
struct Http2DispatchResult(Movable):
    var kind: UInt8
    var stream_id: UInt32
    var value: UInt32
    var output: List[Byte]

    @staticmethod
    def ignored() -> Self:
        return Self(
            kind=1, stream_id=UInt32(0), value=UInt32(0), output=List[Byte]()
        )

    @staticmethod
    def output_frame(var output: List[Byte]) -> Self:
        return Self(
            kind=2, stream_id=UInt32(0), value=UInt32(0), output=output^
        )

    @staticmethod
    def event(kind: UInt8, stream_id: UInt32, value: UInt32) -> Self:
        return Self(
            kind=kind, stream_id=stream_id, value=value, output=List[Byte]()
        )

    @staticmethod
    def error() -> Self:
        return Self(
            kind=6, stream_id=UInt32(0), value=UInt32(0), output=List[Byte]()
        )

    @staticmethod
    def flood() -> Self:
        # Session encodes GOAWAY ENHANCE_YOUR_CALM with its last_stream_id.
        return Self(
            kind=7, stream_id=UInt32(0), value=UInt32(11), output=List[Byte]()
        )

    def is_ignored(self) -> Bool:
        return self.kind == 1

    def is_output(self) -> Bool:
        return self.kind == 2

    def is_window_update(self) -> Bool:
        return self.kind == 3

    def is_reset(self) -> Bool:
        return self.kind == 4

    def is_goaway(self) -> Bool:
        return self.kind == 5

    def is_error(self) -> Bool:
        return self.kind == 6

    def is_flood(self) -> Bool:
        return self.kind == 7


struct Http2FrameDispatcher(Movable):
    var _sequence: Http2ContinuationSequence
    var _peer_settings: Http2PeerSettings
    var _failed: Bool
    var _max_control_frames_per_second: Int
    var _max_resets_per_second: Int
    var _max_new_streams_per_second: Int
    var _new_stream_window_start_ns: Int
    var _new_stream_count: Int
    var _last_headers_stream_id: UInt32
    var _control_window_start_ns: Int
    var _control_count: Int
    var _reset_window_start_ns: Int
    var _reset_count: Int

    def __init__(
        out self,
        initial_settings: Http2PeerSettingsSnapshot,
        max_control_frames_per_second: Int = 1000,
        max_resets_per_second: Int = 100,
        max_new_streams_per_second: Int = 10000,
    ):
        self._sequence = Http2ContinuationSequence()
        self._peer_settings = Http2PeerSettings()
        self._peer_settings.header_table_size = (
            initial_settings.header_table_size
        )
        self._peer_settings.max_concurrent_streams = (
            initial_settings.max_concurrent_streams
        )
        self._peer_settings.initial_window_size = (
            initial_settings.initial_window_size
        )
        self._peer_settings.max_frame_size = initial_settings.max_frame_size
        self._peer_settings.max_header_list_size = (
            initial_settings.max_header_list_size
        )
        self._failed = False
        self._max_control_frames_per_second = max_control_frames_per_second
        self._max_resets_per_second = max_resets_per_second
        self._max_new_streams_per_second = max_new_streams_per_second
        self._new_stream_window_start_ns = 0
        self._new_stream_count = 0
        self._last_headers_stream_id = UInt32(0)
        self._control_window_start_ns = 0
        self._control_count = 0
        self._reset_window_start_ns = 0
        self._reset_count = 0

    def _flood(mut self) -> Http2DispatchResult:
        self._failed = True
        return Http2DispatchResult.flood()

    def _control_exceeded(mut self) -> Bool:
        var now = now_ns()
        if (
            self._control_window_start_ns == 0
            or now - self._control_window_start_ns >= _RATE_WINDOW_NS
        ):
            self._control_window_start_ns = now
            self._control_count = 0
        self._control_count += 1
        return self._control_count > self._max_control_frames_per_second

    def _reset_exceeded(mut self) -> Bool:
        var now = now_ns()
        if (
            self._reset_window_start_ns == 0
            or now - self._reset_window_start_ns >= _RATE_WINDOW_NS
        ):
            self._reset_window_start_ns = now
            self._reset_count = 0
        self._reset_count += 1
        return self._reset_count > self._max_resets_per_second

    def _new_stream_exceeded(mut self, now: Int) -> Bool:
        if (
            self._new_stream_window_start_ns == 0
            or now - self._new_stream_window_start_ns >= _RATE_WINDOW_NS
        ):
            self._new_stream_window_start_ns = now
            self._new_stream_count = 0
        self._new_stream_count += 1
        return self._new_stream_count > self._max_new_streams_per_second

    def accept[
        origin: Origin
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, origin],
    ) -> Http2DispatchResult:
        if self._failed or not self._sequence.accept(frame):
            self._failed = True
            return Http2DispatchResult.error()

        if frame.frame_type == Byte(1):
            if (frame.stream_id & UInt32(1)) == UInt32(0):
                self._failed = True
                return Http2DispatchResult.error()
            if frame.stream_id > self._last_headers_stream_id:
                if self._new_stream_exceeded(now_ns()):
                    return self._flood()
                self._last_headers_stream_id = frame.stream_id
            return Http2DispatchResult.ignored()

        if frame.frame_type == Byte(4):
            var settings = parse_settings_frame(frame, payload)
            if settings.is_error():
                self._failed = True
                return Http2DispatchResult.error()
            if self._control_exceeded():
                return self._flood()
            if settings.is_ack():
                return Http2DispatchResult.ignored()
            var applied = self._peer_settings.apply(
                Span(settings.parsed.settings)
            )
            if applied.is_error():
                self._failed = True
                return Http2DispatchResult.error()
            var ack_wire: List[Byte] = [
                Byte(0),
                Byte(0),
                Byte(0),
                Byte(4),
                Byte(1),
                Byte(0),
                Byte(0),
                Byte(0),
                Byte(0),
            ]
            return Http2DispatchResult.output_frame(ack_wire^)

        if frame.frame_type == Byte(6):
            var ping = parse_ping_frame(frame, payload)
            if ping.is_error():
                self._failed = True
                return Http2DispatchResult.error()
            if self._control_exceeded():
                return self._flood()
            if ping.is_ack():
                return Http2DispatchResult.ignored()
            var ack = ping.encode_ack()
            if not ack.is_complete():
                self._failed = True
                return Http2DispatchResult.error()
            var wire = ack.wire.copy()
            return Http2DispatchResult.output_frame(wire^)

        if frame.frame_type == Byte(8):
            var update = parse_window_update_frame(frame, payload)
            if update.is_error():
                self._failed = True
                return Http2DispatchResult.error()
            if self._control_exceeded():
                return self._flood()
            return Http2DispatchResult.event(
                3, update.stream_id, update.increment
            )

        if frame.frame_type == Byte(3):
            var reset = parse_rst_stream_frame(frame, payload)
            if reset.is_error():
                self._failed = True
                return Http2DispatchResult.error()
            if self._reset_exceeded():
                return self._flood()
            return Http2DispatchResult.event(
                4, reset.stream_id, reset.error_code
            )

        if frame.frame_type == Byte(7):
            var goaway = parse_goaway_frame(frame, payload)
            if goaway.is_error():
                self._failed = True
                return Http2DispatchResult.error()
            return Http2DispatchResult.event(
                5, goaway.last_stream_id, goaway.error_code
            )

        if frame.frame_type == Byte(2):
            if self._control_exceeded():
                return self._flood()
            return Http2DispatchResult.ignored()

        if (
            frame.frame_type == Byte(0)
            and frame.payload_length == 0
            and (frame.flags & Byte(1)) == Byte(0)
        ):
            if self._control_exceeded():
                return self._flood()
            return Http2DispatchResult.ignored()

        return Http2DispatchResult.ignored()

    def peer_settings(self) -> Http2PeerSettingsSnapshot:
        return self._peer_settings.snapshot()

    def is_failed(self) -> Bool:
        return self._failed
