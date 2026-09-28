"""Peer HTTP/2 settings and their protocol value constraints."""

from .settings import Setting


@fieldwise_init
struct SettingsApplyResult(Movable):
    var error_code: UInt32

    @staticmethod
    def success() -> Self:
        return Self(error_code=UInt32(0))

    @staticmethod
    def failure(error_code: UInt32) -> Self:
        return Self(error_code=error_code)

    def is_success(self) -> Bool:
        return self.error_code == UInt32(0)

    def is_error(self) -> Bool:
        return self.error_code != UInt32(0)


struct Http2PeerSettings(Movable):
    var header_table_size: UInt32
    var max_concurrent_streams: UInt32
    var initial_window_size: UInt32
    var max_frame_size: UInt32
    var max_header_list_size: UInt32

    def __init__(out self):
        self.header_table_size = UInt32(4096)
        self.max_concurrent_streams = UInt32(0xFFFFFFFF)
        self.initial_window_size = UInt32(65535)
        self.max_frame_size = UInt32(16384)
        self.max_header_list_size = UInt32(0xFFFFFFFF)

    def apply[
        origin: Origin
    ](mut self, settings: Span[Setting, origin]) -> SettingsApplyResult:
        for i in range(len(settings)):
            var identifier = settings[i].identifier
            var value = settings[i].value

            if identifier == UInt16(1):
                self.header_table_size = value
            elif identifier == UInt16(2):
                if value > UInt32(1):
                    return SettingsApplyResult.failure(UInt32(1))
            elif identifier == UInt16(3):
                self.max_concurrent_streams = value
            elif identifier == UInt16(4):
                if value > UInt32(0x7FFFFFFF):
                    return SettingsApplyResult.failure(UInt32(3))
                self.initial_window_size = value
            elif identifier == UInt16(5):
                if value < UInt32(16384) or value > UInt32(0xFFFFFF):
                    return SettingsApplyResult.failure(UInt32(1))
                self.max_frame_size = value
            elif identifier == UInt16(6):
                self.max_header_list_size = value

        return SettingsApplyResult.success()
