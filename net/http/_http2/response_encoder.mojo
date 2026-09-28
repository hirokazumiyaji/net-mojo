"""Encode a buffered shared response into HTTP/2 response frames."""

from net.http.response import ResponseWriter, has_body_for_status

from .frame_encoder import FrameEncodeResult
from .hpack import Http2HpackDeflater
from .response_frames import encode_data_frames, encode_headers_block
from .response_headers import encode_http2_response_headers


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


def encode_http2_response[
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
    var header_frames = encode_http2_response_header_frames(
        deflater,
        writer,
        is_head,
        date,
        stream_id,
        max_header_list_size,
        max_header_fields,
        max_frame_size,
        max_output_bytes,
        compressed_headers,
    )
    if not header_frames.is_complete():
        return FrameEncodeResult.failure()
    var body_length = len(writer.body)
    if not has_body_for_status(writer.status, is_head) or body_length == 0:
        return header_frames^

    var data_budget = max_output_bytes - len(header_frames.wire)
    var data_frames = encode_data_frames(
        stream_id, Span(writer.body), True, max_frame_size, data_budget
    )
    if not data_frames.is_complete():
        deflater.fail()
        return FrameEncodeResult.failure()

    header_frames.wire.reserve(
        len(header_frames.wire) + len(data_frames.wire)
    )
    for i in range(len(data_frames.wire)):
        header_frames.wire.append(data_frames.wire[i])
    return header_frames^
