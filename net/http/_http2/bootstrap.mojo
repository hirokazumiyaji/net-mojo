"""Socket-independent HTTP/2 server preface and initial SETTINGS state."""

from .frame import FrameParseResult
from .frame_encoder import FrameEncodeResult, encode_frame
from .preface import PrefaceParseResult, parse_client_preface
from .settings_frame import parse_settings_frame


struct Http2ServerBootstrap(Movable):
    var preface_complete: Bool
    var server_settings_sent: Bool
    var client_settings_received: Bool
    var failed: Bool

    def __init__(out self):
        self.preface_complete = False
        self.server_settings_sent = False
        self.client_settings_received = False
        self.failed = False

    def consume_client_preface[
        origin: Origin
    ](mut self, data: Span[Byte, origin]) -> PrefaceParseResult:
        if self.failed or self.preface_complete:
            return PrefaceParseResult.failure()

        var result = parse_client_preface(data)
        if result.is_error():
            self.failed = True
        elif result.is_complete():
            self.preface_complete = True
        return result^

    def server_settings(mut self) -> FrameEncodeResult:
        if (
            self.failed
            or not self.preface_complete
            or self.server_settings_sent
        ):
            return FrameEncodeResult.failure()

        var payload = List[Byte]()
        var frame = encode_frame(Byte(4), Byte(0), UInt32(0), Span(payload))
        if frame.is_complete():
            self.server_settings_sent = True
        return frame^

    def accept_initial_client_settings[
        origin: Origin
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, origin],
    ) -> FrameEncodeResult:
        if (
            self.failed
            or not self.preface_complete
            or not self.server_settings_sent
            or self.client_settings_received
        ):
            self.failed = True
            return FrameEncodeResult.failure()

        var settings = parse_settings_frame(frame, payload)
        if not settings.is_settings():
            self.failed = True
            return FrameEncodeResult.failure()

        self.client_settings_received = True
        var empty_payload = List[Byte]()
        return encode_frame(Byte(4), Byte(1), UInt32(0), Span(empty_payload))

    def is_ready(self) -> Bool:
        return self.client_settings_received and not self.failed

    def is_failed(self) -> Bool:
        return self.failed
