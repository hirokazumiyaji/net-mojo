"""HTTP/2 DATA frame validation."""

from .frame import FrameParseResult


@fieldwise_init
struct DataFrameResult(Copyable, Equatable):
    var kind: UInt8
    var data_offset: Int
    var data_length: Int
    var end_stream: Bool

    @staticmethod
    def valid(data_offset: Int, data_length: Int, end_stream: Bool) -> Self:
        return Self(
            kind=1,
            data_offset=data_offset,
            data_length=data_length,
            end_stream=end_stream,
        )

    @staticmethod
    def error() -> Self:
        return Self(kind=2, data_offset=0, data_length=0, end_stream=False)

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def parse_data_frame[
    origin: Origin
](frame: FrameParseResult, payload: Span[Byte, origin]) -> DataFrameResult:
    if (
        not frame.is_complete()
        or frame.frame_type != Byte(0)
        or frame.stream_id == UInt32(0)
        or frame.payload_length != len(payload)
    ):
        return DataFrameResult.error()

    var offset = 0
    var data_length = len(payload)
    if (frame.flags & Byte(8)) != Byte(0):
        if len(payload) == 0:
            return DataFrameResult.error()
        var padding_length = Int(payload[0])
        offset = 1
        data_length = len(payload) - offset - padding_length
        if data_length < 0:
            return DataFrameResult.error()

    return DataFrameResult.valid(
        offset,
        data_length,
        (frame.flags & Byte(1)) != Byte(0),
    )
