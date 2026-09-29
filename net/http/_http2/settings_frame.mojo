"""HTTP/2 SETTINGS frame validation and payload parsing."""

from .frame import FrameParseResult
from .settings import SettingsParseResult, parse_settings_payload


@fieldwise_init
struct SettingsFrameResult(Movable):
    var kind: UInt8
    var parsed: SettingsParseResult
    var error_code: UInt32

    @staticmethod
    def received(var parsed: SettingsParseResult) -> Self:
        return Self(kind=1, parsed=parsed^, error_code=UInt32(0))

    @staticmethod
    def ack() -> Self:
        return Self(
            kind=2, parsed=SettingsParseResult.failure(), error_code=UInt32(0)
        )

    @staticmethod
    def failure(error_code: UInt32 = UInt32(1)) -> Self:
        return Self(
            kind=3,
            parsed=SettingsParseResult.failure(),
            error_code=error_code,
        )

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
        return SettingsFrameResult.failure(UInt32(1))

    if (frame.flags & Byte(1)) != Byte(0):
        if len(payload) != 0:
            return SettingsFrameResult.failure(UInt32(6))
        return SettingsFrameResult.ack()

    var decoded = parse_settings_payload(payload)
    if decoded.is_error():
        return SettingsFrameResult.failure(UInt32(6))
    return SettingsFrameResult.received(decoded^)
