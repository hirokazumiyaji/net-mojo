"""Encode a buffered shared response into HTTP/2 response frames."""

from net.http.response import ResponseWriter, has_body_for_status

from .frame_encoder import FrameEncodeResult
from .hpack import Http2HpackDeflater
from .response_frames import encode_headers_block
from .response_headers import (
    encode_http2_response_headers,
    encode_http2_response_trailers,
)


def _append_hpack_integer(mut output: List[Byte], prefix: UInt8, value: Int):
    # RFC 7541 §5.1 integer with a 7-bit prefix combined with `prefix` bits.
    if value < 127:
        output.append(prefix | Byte(value))
        return
    output.append(prefix | Byte(0x7F))
    var remainder = value - 127
    while remainder >= 128:
        output.append(Byte((remainder & 0x7F) | 0x80))
        remainder >>= 7
    output.append(Byte(remainder))


def _encode_literal_never_indexed_block[
    origin: ImmOrigin
](fields: Span[Byte, origin]) -> List[Byte]:
    # RFC 7541 §6.2.3 Literal Header Field Never Indexed with a new name,
    # written one entry per field. Hand-written so the trailer block is
    # independent of the connection HPACK dynamic table on both ends: no
    # dynamic insertion, and no indexed-name reference whose dynamic index
    # could resolve to a different entry after other streams' HEADERS run
    # through the deflater between encode time and send time.
    var output = List[Byte]()
    var offset = 0
    while offset < len(fields):
        var name_length = (
            (Int(fields[offset]) << 24)
            | (Int(fields[offset + 1]) << 16)
            | (Int(fields[offset + 2]) << 8)
            | Int(fields[offset + 3])
        )
        var value_length = (
            (Int(fields[offset + 4]) << 24)
            | (Int(fields[offset + 5]) << 16)
            | (Int(fields[offset + 6]) << 8)
            | Int(fields[offset + 7])
        )
        offset += 8
        output.append(Byte(0x10))
        _append_hpack_integer(output, Byte(0), name_length)
        output.extend(Span(fields)[offset : offset + name_length])
        offset += name_length
        _append_hpack_integer(output, Byte(0), value_length)
        output.extend(Span(fields)[offset : offset + value_length])
        offset += value_length
    return output^


def encode_http2_response_header_frames[
    origin: MutOrigin
](
    mut deflater: Http2HpackDeflater,
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    stream_id: UInt32,
    max_header_list_size: Int,
    max_header_fields: Int,
    max_frame_size: Int,
    max_output_bytes: Int,
    compressed_headers: Span[mut=True, Byte, origin],
) -> FrameEncodeResult:
    var headers = encode_http2_response_headers(
        writer, is_head, date, max_header_list_size, max_header_fields
    )
    if not headers.is_valid():
        return FrameEncodeResult.failure()

    var compressed = deflater.encode(
        Span(headers.fields),
        max_header_list_size,
        max_header_fields,
        compressed_headers,
    )
    if not compressed.is_success():
        return FrameEncodeResult.failure()

    var end_on_headers = not headers.send_body or len(writer.body) == 0
    var header_frames = encode_headers_block(
        stream_id,
        compressed_headers[0 : compressed.output_length],
        end_on_headers,
        max_frame_size,
        max_output_bytes,
    )
    if not header_frames.is_complete():
        deflater.fail()
    return header_frames^


def encode_http2_response_trailer_frames(
    writer: ResponseWriter,
    is_head: Bool,
    stream_id: UInt32,
    max_header_list_size: Int,
    max_header_fields: Int,
    max_frame_size: Int,
    max_output_bytes: Int,
) -> FrameEncodeResult:
    var trailers = encode_http2_response_trailers(
        writer, is_head, max_header_list_size, max_header_fields
    )
    if not trailers.is_valid():
        return FrameEncodeResult.failure()
    if trailers.field_count == 0:
        return FrameEncodeResult.complete(List[Byte]())

    var block = _encode_literal_never_indexed_block(Span(trailers.fields))
    return encode_headers_block(
        stream_id,
        Span(block),
        True,
        max_frame_size,
        max_output_bytes,
    )
