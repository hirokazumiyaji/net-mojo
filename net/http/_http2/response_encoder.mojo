"""Encode a buffered shared response into HTTP/2 response frames."""

from net.http.response import ResponseWriter, has_body_for_status

from .frame_encoder import FrameEncodeResult
from .hpack import Http2HpackDeflater
from .response_frames import encode_headers_block
from .response_headers import (
    encode_http2_response_headers,
    encode_http2_response_trailers,
)


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


def encode_http2_response_trailer_frames[
    origin: MutOrigin
](
    mut deflater: Http2HpackDeflater,
    writer: ResponseWriter,
    is_head: Bool,
    stream_id: UInt32,
    max_header_list_size: Int,
    max_header_fields: Int,
    max_frame_size: Int,
    max_output_bytes: Int,
    compressed_trailers: Span[mut=True, Byte, origin],
) -> FrameEncodeResult:
    var trailers = encode_http2_response_trailers(
        writer, is_head, max_header_list_size, max_header_fields
    )
    if not trailers.is_valid():
        return FrameEncodeResult.failure()
    if trailers.field_count == 0:
        return FrameEncodeResult.complete(List[Byte]())

    var compressed = deflater.encode_no_index(
        Span(trailers.fields),
        max_header_list_size,
        max_header_fields,
        compressed_trailers,
    )
    if not compressed.is_success():
        return FrameEncodeResult.failure()

    return encode_headers_block(
        stream_id,
        compressed_trailers[0 : compressed.output_length],
        True,
        max_frame_size,
        max_output_bytes,
    )
