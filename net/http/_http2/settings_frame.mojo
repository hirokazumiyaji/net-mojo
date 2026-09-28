"""HTTP/2 SETTINGS frame validation and payload parsing."""

from .frame import FrameParseResult
from .settings import SettingsParseResult, parse_settings_payload


@fieldwise_init
struct SettingsFrameResult(Movable):
    var kind: UInt8
    var parsed: SettingsParseResult

    @staticmethod
    def received(var parsed: SettingsParseResult) -> Self:
        return Self(kind=1, parsed=parsed^)

    @staticmethod
    def ack() -> Self:
        return Self(kind=2, parsed=SettingsParseResult.failure())

    @staticmethod
    def failure() -> Self:
        return Self(kind=3, parsed=SettingsParseResult.failure())

    def is_settings(self) -> Bool:
        return self.kind == 1

    def is_ack(self) -> Bool:
        return self.kind == 2

    def is_error(self) -> Bool:
        return self.kind == 3


def parse_settings_frame[
    origin: Origin
](frame: FrameParseResult, payload: Span[Byte, origin]) -> SettingsFrameResult:
    if (
        not frame.is_complete()
        or frame.frame_type != Byte(4)
        or frame.stream_id != UInt32(0)
        or frame.payload_length != len(payload)
    ):
        return SettingsFrameResult.failure()

    if (frame.flags & Byte(1)) != Byte(0):
        if len(payload) != 0:
            return SettingsFrameResult.failure()
        return SettingsFrameResult.ack()

    var decoded = parse_settings_payload(payload)
    if decoded.is_error():
        return SettingsFrameResult.failure()
    return SettingsFrameResult.received(decoded^)
