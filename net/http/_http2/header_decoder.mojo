"""Connection-level bounded header assembly and HPACK decoding."""

from .frame import FrameParseResult
from .hpack import HpackDecodeResult, Http2HpackInflater
from .header_block import HeaderBlockResult, Http2HeaderBlock


@fieldwise_init
struct Http2HeaderDecodeResult(Copyable):
    var status: Int
    var output_length: Int
    var field_count: Int
    var decoded_size: Int
    var stream_id: UInt32
    var end_stream: Bool

    @staticmethod
    def pending() -> Self:
        return Self(
            status=0,
            output_length=0,
            field_count=0,
            decoded_size=0,
            stream_id=UInt32(0),
            end_stream=False,
        )

    @staticmethod
    def complete(
        decoded: HpackDecodeResult, stream_id: UInt32, end_stream: Bool
    ) -> Self:
        return Self(
            status=1,
            output_length=decoded.output_length,
            field_count=decoded.field_count,
            decoded_size=decoded.decoded_size,
            stream_id=stream_id,
            end_stream=end_stream,
        )

    @staticmethod
    def too_large(decoded: HpackDecodeResult, stream_id: UInt32) -> Self:
        return Self(
            status=2,
            output_length=decoded.output_length,
            field_count=decoded.field_count,
            decoded_size=decoded.decoded_size,
            stream_id=stream_id,
            end_stream=False,
        )

    @staticmethod
    def protocol_error() -> Self:
        return Self(
            status=3,
            output_length=0,
            field_count=0,
            decoded_size=0,
            stream_id=UInt32(0),
            end_stream=False,
        )

    @staticmethod
    def compression_error() -> Self:
        return Self(
            status=4,
            output_length=0,
            field_count=0,
            decoded_size=0,
            stream_id=UInt32(0),
            end_stream=False,
        )

    @staticmethod
    def flooded() -> Self:
        return Self(
            status=5,
            output_length=0,
            field_count=0,
            decoded_size=0,
            stream_id=UInt32(0),
            end_stream=False,
        )

    def is_pending(self) -> Bool:
        return self.status == 0

    def is_complete(self) -> Bool:
        return self.status == 1

    def is_too_large(self) -> Bool:
        return self.status == 2

    def is_protocol_error(self) -> Bool:
        return self.status == 3

    def is_compression_error(self) -> Bool:
        return self.status == 4

    def is_flooded(self) -> Bool:
        return self.status == 5


struct Http2HeaderDecoder(Movable):
    var _block: Http2HeaderBlock
    var _inflater: Http2HpackInflater
    var _failed: Bool

    def __init__(
        out self,
        var library_path: String,
        max_table_size: Int,
        max_compressed_size: Int,
        max_continuation_frames: Int = 32,
    ) raises:
        self._block = Http2HeaderBlock(
            max_compressed_size, max_continuation_frames=max_continuation_frames
        )
        self._inflater = Http2HpackInflater(library_path^, max_table_size)
        self._failed = False

    def set_max_table_size(mut self, size: Int) -> Bool:
        return self._inflater.set_max_table_size(size)

    def consume[
        payload_origin: Origin,
        output_origin: MutOrigin,
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, payload_origin],
        max_header_list_size: Int,
        max_fields: Int,
        output: Span[mut=True, Byte, output_origin],
    ) -> Http2HeaderDecodeResult:
        if self._failed:
            return Http2HeaderDecodeResult.protocol_error()

        var assembled: HeaderBlockResult
        if self._block.pending:
            assembled = self._block.continue_with(frame, payload)
        else:
            assembled = self._block.begin(frame, payload)
        if assembled.is_flooded():
            self._failed = True
            return Http2HeaderDecodeResult.flooded()
        if assembled.is_error():
            self._failed = True
            return Http2HeaderDecodeResult.protocol_error()
        if assembled.is_pending():
            return Http2HeaderDecodeResult.pending()

        var compressed = self._block.compressed_block()
        var stream_id = self._block.stream_id
        var end_stream = self._block.end_stream
        var decoded = self._inflater.decode(
            Span(compressed), max_header_list_size, max_fields, output
        )
        if decoded.is_success():
            return Http2HeaderDecodeResult.complete(
                decoded, stream_id, end_stream
            )
        if decoded.is_too_large():
            return Http2HeaderDecodeResult.too_large(decoded, stream_id)
        self._failed = True
        return Http2HeaderDecodeResult.compression_error()
