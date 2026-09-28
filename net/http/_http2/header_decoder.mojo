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

    @staticmethod
    def pending() -> Self:
        return Self(status=0, output_length=0, field_count=0, decoded_size=0)

    @staticmethod
    def complete(decoded: HpackDecodeResult) -> Self:
        return Self(
            status=1,
            output_length=decoded.output_length,
            field_count=decoded.field_count,
            decoded_size=decoded.decoded_size,
        )

    @staticmethod
    def too_large(decoded: HpackDecodeResult) -> Self:
        return Self(
            status=2,
            output_length=decoded.output_length,
            field_count=decoded.field_count,
            decoded_size=decoded.decoded_size,
        )

    @staticmethod
    def protocol_error() -> Self:
        return Self(status=3, output_length=0, field_count=0, decoded_size=0)

    @staticmethod
    def compression_error() -> Self:
        return Self(status=4, output_length=0, field_count=0, decoded_size=0)

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


struct Http2HeaderDecoder(Movable):
    var _block: Http2HeaderBlock
    var _inflater: Http2HpackInflater
    var _failed: Bool

    def __init__(
        out self,
        var library_path: String,
        max_table_size: Int,
        max_compressed_size: Int,
    ) raises:
        self._block = Http2HeaderBlock(max_compressed_size)
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
        if assembled.is_error():
            self._failed = True
            return Http2HeaderDecodeResult.protocol_error()
        if assembled.is_pending():
            return Http2HeaderDecodeResult.pending()

        var compressed = self._block.compressed_block()
        var decoded = self._inflater.decode(
            Span(compressed), max_header_list_size, max_fields, output
        )
        if decoded.is_success():
            return Http2HeaderDecodeResult.complete(decoded)
        if decoded.is_too_large():
            return Http2HeaderDecodeResult.too_large(decoded)
        self._failed = True
        return Http2HeaderDecodeResult.compression_error()
