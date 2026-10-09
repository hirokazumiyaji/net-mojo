from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.http._http2.hpack import Http2HpackDeflater, Http2HpackInflater
from net.http._http2.frame import FrameParseResult, parse_frame
from net.http._http2.header_decoder import Http2HeaderDecoder
from net.http._http2.request_session import Http2RequestSession
from net.http._http2.response_scheduler import Http2ResponseScheduler
from net.http._http2.frame_encoder import encode_frame
from net.http._http2.control_frames import parse_rst_stream_frame
from net.http._http2.control_frames import parse_goaway_frame
from net.http._http2.window_update import parse_window_update_frame
from net.http._http2.response_encoder import (
    encode_http2_response_header_frames,
)
from net.http._http2.response_headers import (
    encode_http2_response_headers,
    encode_http2_response_trailers,
)
from net.http._http2.request_headers import decode_http2_request_headers
from net.http.response import ResponseWriter
from net.http.request import HttpVersion
from tests.support import _append_hpack_field


def _enqueue_response(
    mut scheduler: Http2ResponseScheduler,
    stream_id: UInt32,
    status: Int,
    var body: List[Byte],
) raises -> Bool:
    var writer = ResponseWriter(len(body) + 16)
    writer.set_status(status)
    writer.write(Span(body))
    var fields = encode_http2_response_headers(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 4096, 32
    )
    assert_true(fields.is_valid())
    var fields_bytes = fields.fields^
    fields.fields = List[Byte]()
    var count = fields.field_count
    return scheduler.enqueue(
        stream_id,
        fields_bytes^,
        count,
        4096,
        32,
        4096,
        body^,
    )


def _make_deflater() raises -> Http2HpackDeflater:
    return Http2HpackDeflater("build/http2/libnet_hpack", 4096)


def _append_frame[
    origin: Origin
](
    mut wire: List[Byte],
    frame_type: UInt8,
    flags: UInt8,
    stream_id: UInt32,
    payload: Span[Byte, origin],
):
    var frame = encode_frame(frame_type, flags, stream_id, payload)
    for i in range(len(frame.wire)):
        wire.append(frame.wire[i])


def test_hpack_inflater_decodes_huffman_header_block() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var block: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x8C),
        Byte(0xF1),
        Byte(0xE3),
        Byte(0xC2),
        Byte(0xE5),
        Byte(0xF2),
        Byte(0x3A),
        Byte(0x6B),
        Byte(0xA0),
        Byte(0xAB),
        Byte(0x90),
        Byte(0xF4),
        Byte(0xFF),
    ]
    var output = Array[Byte, 512](fill=0)
    var result = inflater.decode(Span(block), 1024, 16, Span(output))
    assert_true(result.is_success())
    assert_equal(result.field_count, 4)
    assert_true(result.output_length > 0)
    assert_equal(output[0], Byte(0))
    assert_equal(output[3], Byte(7))
    assert_equal(output[8], Byte(ord(":")))


def test_hpack_deflater_encodes_bounded_header_fields() raises:
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var fields = List[Byte]()
    _append_hpack_field(fields, String(":status"), String("200"))
    _append_hpack_field(fields, String("content-type"), String("text/plain"))
    var too_small = Array[Byte, 1](fill=0)
    var result = deflater.encode(Span(fields), 1024, 8, Span(too_small))
    assert_true(result.is_too_large())
    assert_equal(result.output_length, 0)
    result = deflater.encode(Span(fields), 1024, 1, Span(too_small))
    assert_true(result.is_too_large())
    result = deflater.encode(Span(fields), -1, 8, Span(too_small))
    assert_true(result.is_invalid())

    var output = Array[Byte, 128](fill=0)
    result = deflater.encode(Span(fields), 1024, 8, Span(output))
    assert_true(result.is_success())
    assert_true(result.output_length > 0)

    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var decoded = inflater.decode(
        Span(output)[0 : result.output_length], 1024, 8, Span(fields)
    )
    assert_true(decoded.is_success())
    assert_equal(decoded.field_count, 2)
    assert_equal(decoded.output_length, len(fields))


def test_shared_response_encodes_to_http2_header_frames() raises:
    var writer = ResponseWriter(64)
    writer.set_status(201)
    writer.headers.add("X-Trace", "abc")
    writer.write_string("body")
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var compressed = Array[Byte, 1024](fill=0)
    var encoded = encode_http2_response_header_frames(
        deflater,
        writer,
        False,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        UInt32(1),
        4096,
        32,
        16384,
        8192,
        Span[mut=True](compressed),
    )
    assert_true(encoded.is_complete())
    var headers = parse_frame(Span(encoded.wire))
    assert_true(headers.is_complete())
    assert_equal(headers.frame_type, Byte(1))
    assert_equal(headers.flags, Byte(4))
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var decoded_fields = Array[Byte, 1024](fill=0)
    var decoded = inflater.decode(
        Span(encoded.wire)[9 : headers.consumed],
        4096,
        32,
        Span(decoded_fields),
    )
    assert_true(decoded.is_success())
    assert_equal(decoded.field_count, 4)
    assert_equal(headers.consumed, len(encoded.wire))


def test_failed_response_encoding_poisoned_deflater() raises:
    var writer = ResponseWriter(64)
    writer.write_string("body")
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var compressed = Array[Byte, 1024](fill=0)
    var failed = encode_http2_response_header_frames(
        deflater,
        writer,
        False,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        UInt32(1),
        4096,
        32,
        16384,
        16,
        Span[mut=True](compressed),
    )
    assert_true(failed.is_error())
    var retried = encode_http2_response_header_frames(
        deflater,
        writer,
        False,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        UInt32(1),
        4096,
        32,
        16384,
        8192,
        Span[mut=True](compressed),
    )
    assert_true(retried.is_error())


def test_hpack_inflater_preserves_dynamic_table_after_limit() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var literal: List[Byte] = [
        Byte(0x40),
        Byte(0x06),
        Byte(ord("x")),
        Byte(ord("-")),
        Byte(ord("t")),
        Byte(ord("e")),
        Byte(ord("s")),
        Byte(ord("t")),
        Byte(0x05),
        Byte(ord("f")),
        Byte(ord("i")),
        Byte(ord("r")),
        Byte(ord("s")),
        Byte(ord("t")),
    ]
    var output = Array[Byte, 128](fill=0)
    var result = inflater.decode(Span(literal), 0, 16, Span(output))
    assert_true(result.is_too_large())
    assert_equal(result.field_count, 1)

    var indexed: List[Byte] = [Byte(0xBE)]
    result = inflater.decode(Span(indexed), 1024, 16, Span(output))
    assert_true(result.is_success())
    assert_equal(result.field_count, 1)
    assert_equal(result.output_length, 19)
    assert_equal(output[8], Byte(ord("x")))
    assert_equal(output[14], Byte(ord("f")))


def test_hpack_inflater_reports_decoded_output_limit() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var block: List[Byte] = [Byte(0x82), Byte(0x86)]
    var output = Array[Byte, 4](fill=0)
    var result = inflater.decode(Span(block), 1024, 16, Span(output))
    assert_true(result.is_too_large())
    assert_equal(result.field_count, 2)


def test_hpack_inflater_applies_table_limit_between_blocks() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    assert_true(inflater.set_max_table_size(32))
    var update: List[Byte] = [Byte(0x3F), Byte(0x01)]
    var output = Array[Byte, 8](fill=0)
    var result = inflater.decode(Span(update), 1024, 16, Span(output))
    assert_true(result.is_success())
    assert_equal(result.field_count, 0)


def test_header_decoder_handles_fragmented_header_block() raises:
    var decoder = Http2HeaderDecoder("build/http2/libnet_hpack", 4096, 1024)
    var first: List[Byte] = [Byte(0x82), Byte(0x86)]
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 2)
    var output = Array[Byte, 128](fill=0)
    var result = decoder.consume(headers, Span(first), 1024, 16, Span(output))
    assert_true(result.is_pending())

    var continuation: List[Byte] = [
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    var continuation_frame = FrameParseResult.complete(
        Byte(9), Byte(4), UInt32(1), len(continuation)
    )
    result = decoder.consume(
        continuation_frame, Span(continuation), 1024, 16, Span(output)
    )
    assert_true(result.is_complete())
    assert_equal(result.stream_id, UInt32(1))
    assert_true(not result.end_stream)
    assert_equal(result.field_count, 4)
    assert_true(result.output_length > 0)


def test_header_decoder_preserves_end_stream_on_fragmented_headers() raises:
    var decoder = Http2HeaderDecoder("build/http2/libnet_hpack", 4096, 1024)
    var first: List[Byte] = [Byte(0x82)]
    var headers = FrameParseResult.complete(Byte(1), Byte(1), UInt32(5), 1)
    var output = Array[Byte, 128](fill=0)
    var result = decoder.consume(headers, Span(first), 1024, 16, Span(output))
    assert_true(result.is_pending())

    var continuation: List[Byte] = [Byte(0x86)]
    var continuation_frame = FrameParseResult.complete(
        Byte(9), Byte(4), UInt32(5), 1
    )
    result = decoder.consume(
        continuation_frame, Span(continuation), 1024, 16, Span(output)
    )
    assert_true(result.is_complete())
    assert_equal(result.stream_id, UInt32(5))
    assert_true(result.end_stream)


def test_header_decoder_distinguishes_size_and_compression_errors() raises:
    var decoder = Http2HeaderDecoder("build/http2/libnet_hpack", 4096, 1024)
    var block: List[Byte] = [Byte(0x82), Byte(0x86)]
    var output = Array[Byte, 128](fill=0)
    var headers = FrameParseResult.complete(Byte(1), Byte(4), UInt32(1), 2)
    var too_large = decoder.consume(headers, Span(block), 0, 16, Span(output))
    assert_true(too_large.is_too_large())
    assert_equal(too_large.field_count, 2)

    var invalid_decoder = Http2HeaderDecoder(
        "build/http2/libnet_hpack", 4096, 1024
    )
    var invalid_block: List[Byte] = [Byte(0xFF)]
    var invalid_headers = FrameParseResult.complete(
        Byte(1), Byte(4), UInt32(1), 1
    )
    var invalid = invalid_decoder.consume(
        invalid_headers, Span(invalid_block), 1024, 16, Span(output)
    )
    assert_true(invalid.is_compression_error())


def test_header_decoder_fails_connection_on_invalid_continuation_sequence() raises:
    var decoder = Http2HeaderDecoder("build/http2/libnet_hpack", 4096, 8)
    var first: List[Byte] = [Byte(0x82)]
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 1)
    var output = Array[Byte, 64](fill=0)
    var result = decoder.consume(headers, Span(first), 1024, 16, Span(output))
    assert_true(result.is_pending())

    var continuation: List[Byte] = [Byte(0x86)]
    var wrong_stream = FrameParseResult.complete(Byte(9), Byte(4), UInt32(3), 1)
    result = decoder.consume(
        wrong_stream, Span(continuation), 1024, 16, Span(output)
    )
    assert_true(result.is_protocol_error())
    var next_headers = FrameParseResult.complete(Byte(1), Byte(4), UInt32(3), 1)
    result = decoder.consume(
        next_headers, Span(continuation), 1024, 16, Span(output)
    )
    assert_true(result.is_protocol_error())


def test_hpack_headers_become_a_shared_http2_request() raises:
    var decoder = Http2HeaderDecoder("build/http2/libnet_hpack", 4096, 1024)
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    var frame = FrameParseResult.complete(
        Byte(1), Byte(4), UInt32(1), len(compressed)
    )
    var output = Array[Byte, 512](fill=0)
    var decoded = decoder.consume(
        frame, Span(compressed), 1024, 16, Span(output)
    )
    assert_true(decoded.is_complete())
    var serialized = List[Byte]()
    for i in range(decoded.output_length):
        serialized.append(output[i])
    var request_head = decode_http2_request_headers(
        Span(serialized), decoded.field_count
    )
    assert_true(request_head.is_valid())
    var request = request_head^.into_request()
    assert_equal(request.version, HttpVersion.http2())
    assert_equal(request.method, "GET")
    assert_equal(request.path, "/")
    assert_equal(request.authority, "www.example.com")


def test_http2_request_session_completes_fragmented_header_only_request() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    var settings = encode_frame(Byte(4), Byte(0), UInt32(0), Span(empty))
    for i in range(len(settings.wire)):
        wire.append(settings.wire[i])
    var first: List[Byte] = [Byte(0x82), Byte(0x86)]
    var headers = encode_frame(Byte(1), Byte(1), UInt32(1), Span(first))
    for i in range(len(headers.wire)):
        wire.append(headers.wire[i])
    var rest: List[Byte] = [
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    var continuation = encode_frame(Byte(9), Byte(4), UInt32(1), Span(rest))
    for i in range(len(continuation.wire)):
        wire.append(continuation.wire[i])

    var result = session.consume(Span(wire))
    assert_true(result.is_request())
    assert_equal(result.consumed, len(wire))
    assert_equal(result.stream_id, UInt32(1))
    assert_equal(result.request.method, "GET")
    assert_equal(result.request.authority, "www.example.com")


def test_http2_request_session_goaway_uses_last_admitted_stream() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var request = session.consume(Span(wire))
    assert_true(request.is_request())
    assert_equal(request.stream_id, UInt32(3))

    var goaway_wire = session.begin_shutdown()
    var frame = parse_frame(Span(goaway_wire))
    assert_true(frame.is_complete())
    assert_equal(frame.frame_type, Byte(7))
    var goaway = parse_goaway_frame(frame, Span(goaway_wire[9:]))
    assert_true(goaway.is_valid())
    assert_equal(goaway.last_stream_id, UInt32(3))


def test_http2_request_session_refuses_new_streams_after_goaway() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    _ = session.consume(Span(wire))
    _ = session.begin_shutdown()

    var compressed: List[Byte] = [Byte(0x82), Byte(0x86), Byte(0x84)]
    var headers = List[Byte]()
    _append_frame(headers, Byte(1), Byte(5), UInt32(1), Span(compressed))
    var result = session.consume(Span(headers))
    assert_true(result.is_pending())
    var reset_frame = parse_frame(Span(result.output))
    assert_true(reset_frame.is_complete())
    assert_equal(reset_frame.frame_type, Byte(3))
    assert_equal(reset_frame.stream_id, UInt32(1))
    var reset = parse_rst_stream_frame(reset_frame, Span(result.output[9:]))
    assert_true(reset.is_valid())
    assert_equal(reset.error_code, UInt32(7))


def _find_goaway_offset(wire: List[Byte]) raises -> Int:
    var offset = 0
    while offset + 9 <= len(wire):
        var frame = parse_frame(Span(wire)[offset:])
        assert_true(frame.is_complete())
        if frame.frame_type == Byte(7):
            return offset
        offset += frame.consumed
    return -1


def test_http2_request_session_reset_flood_uses_last_stream_id() raises:
    var session = Http2RequestSession(
        "build/http2/libnet_hpack",
        4,
        1024,
        max_control_frames_per_second=1000,
        max_resets_per_second=2,
    )
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var request = session.consume(Span(wire))
    assert_true(request.is_request())
    assert_equal(request.stream_id, UInt32(3))

    var reset_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(8)]
    var reset1 = List[Byte]()
    _append_frame(reset1, Byte(3), Byte(0), UInt32(3), Span(reset_payload))
    assert_true(session.consume(Span(reset1)).is_pending())
    var reset2 = List[Byte]()
    _append_frame(reset2, Byte(3), Byte(0), UInt32(3), Span(reset_payload))
    assert_true(session.consume(Span(reset2)).is_pending())
    assert_false(session.is_draining())

    var reset3 = List[Byte]()
    _append_frame(reset3, Byte(3), Byte(0), UInt32(3), Span(reset_payload))
    var flooded = session.consume(Span(reset3))
    assert_true(flooded.is_pending())
    assert_true(session.is_draining())
    assert_true(session.is_failed())
    var goaway_at = _find_goaway_offset(flooded.output)
    assert_true(goaway_at >= 0)
    var goaway_frame = parse_frame(Span(flooded.output)[goaway_at:])
    var goaway = parse_goaway_frame(
        goaway_frame, Span(flooded.output)[goaway_at + 9 :]
    )
    assert_true(goaway.is_valid())
    assert_equal(goaway.error_code, UInt32(11))
    assert_equal(goaway.last_stream_id, UInt32(3))

    var more = List[Byte]()
    _append_frame(more, Byte(1), Byte(5), UInt32(5), Span(compressed))
    assert_false(session.consume(Span(more)).is_request())


def test_http2_request_session_completes_data_body() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    var settings = encode_frame(Byte(4), Byte(0), UInt32(0), Span(empty))
    for i in range(len(settings.wire)):
        wire.append(settings.wire[i])
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    var headers = encode_frame(Byte(1), Byte(4), UInt32(1), Span(compressed))
    for i in range(len(headers.wire)):
        wire.append(headers.wire[i])
    var body: List[Byte] = [Byte(ord("a")), Byte(ord("b")), Byte(ord("c"))]
    var data = encode_frame(Byte(0), Byte(1), UInt32(1), Span(body))
    for i in range(len(data.wire)):
        wire.append(data.wire[i])

    var result = session.consume(Span(wire))
    assert_true(result.is_request())
    assert_equal(result.stream_id, UInt32(1))
    assert_equal(len(result.request.body), 3)
    assert_equal(result.request.body[0], Byte(ord("a")))
    assert_equal(result.request.body[2], Byte(ord("c")))


def test_http2_request_session_keeps_interleaved_bodies_on_their_streams() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))

    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(4), UInt32(1), Span(compressed))
    _append_frame(wire, Byte(1), Byte(4), UInt32(3), Span(compressed))
    var first_body: List[Byte] = [Byte(ord("a"))]
    _append_frame(wire, Byte(0), Byte(0), UInt32(1), Span(first_body))
    var second_body: List[Byte] = [Byte(ord("b"))]
    _append_frame(wire, Byte(0), Byte(0), UInt32(3), Span(second_body))
    var first_end: List[Byte] = [Byte(ord("c"))]
    _append_frame(wire, Byte(0), Byte(1), UInt32(1), Span(first_end))
    var second_end: List[Byte] = [Byte(ord("d"))]
    _append_frame(wire, Byte(0), Byte(1), UInt32(3), Span(second_end))

    var first = session.consume(Span(wire))
    assert_true(first.is_request())
    assert_equal(first.stream_id, UInt32(1))
    assert_equal(first.request.body[0], Byte(ord("a")))
    assert_equal(first.request.body[1], Byte(ord("c")))
    assert_true(first.consumed < len(wire))
    var second = session.consume(Span(wire)[first.consumed :])
    assert_true(second.is_request())
    assert_equal(second.stream_id, UInt32(3))
    assert_equal(second.request.body[0], Byte(ord("b")))
    assert_equal(second.request.body[1], Byte(ord("d")))


def test_http2_request_session_refuses_over_limit_stream_without_failing_connection() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 1, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(4), UInt32(1), Span(compressed))
    _append_frame(wire, Byte(1), Byte(4), UInt32(3), Span(compressed))
    var refused_body: List[Byte] = [Byte(ord("b"))]
    _append_frame(wire, Byte(0), Byte(1), UInt32(3), Span(refused_body))

    var refused = session.consume(Span(wire))
    assert_true(refused.is_pending())
    var server_settings = parse_frame(Span(refused.output))
    assert_true(server_settings.is_complete())
    assert_equal(server_settings.frame_type, Byte(4))
    assert_equal(server_settings.payload_length, 6)
    assert_equal(Span(refused.output)[9], Byte(0))
    assert_equal(Span(refused.output)[10], Byte(3))
    assert_equal(Span(refused.output)[11], Byte(0))
    assert_equal(Span(refused.output)[12], Byte(0))
    assert_equal(Span(refused.output)[13], Byte(0))
    assert_equal(Span(refused.output)[14], Byte(1))
    var server_ack = parse_frame(
        Span(refused.output)[server_settings.consumed :]
    )
    assert_true(server_ack.is_complete())
    assert_equal(server_ack.flags, Byte(1))
    var rst_offset = server_settings.consumed + server_ack.consumed
    var rst = parse_frame(Span(refused.output)[rst_offset:])
    assert_true(rst.is_complete())
    assert_equal(rst.frame_type, Byte(3))
    assert_equal(rst.stream_id, UInt32(3))
    var rst_fields = parse_rst_stream_frame(
        rst, Span(refused.output)[rst_offset + 9 :]
    )
    assert_true(rst_fields.is_valid())
    assert_equal(rst_fields.error_code, UInt32(7))

    var body: List[Byte] = [Byte(ord("a"))]
    var first_body = List[Byte]()
    _append_frame(first_body, Byte(0), Byte(1), UInt32(1), Span(body))
    var first = session.consume(Span(first_body))
    assert_true(first.is_request())
    assert_equal(first.stream_id, UInt32(1))

    var queued = List[Byte]()
    _append_frame(queued, Byte(1), Byte(5), UInt32(5), Span(compressed))
    var queued_result = session.consume(Span(queued))
    assert_true(queued_result.is_pending())
    var queued_reset = parse_frame(Span(queued_result.output))
    assert_true(queued_reset.is_complete())
    assert_equal(queued_reset.stream_id, UInt32(5))
    var queued_reset_fields = parse_rst_stream_frame(
        queued_reset, Span(queued_result.output)[9:]
    )
    assert_true(queued_reset_fields.is_valid())
    assert_equal(queued_reset_fields.error_code, UInt32(7))

    session.finish_response(UInt32(1))

    var later = List[Byte]()
    _append_frame(later, Byte(1), Byte(5), UInt32(7), Span(compressed))
    var accepted = session.consume(Span(later))
    assert_true(accepted.is_request())
    assert_equal(accepted.stream_id, UInt32(7))


def test_http2_request_session_resets_only_stream_for_oversized_body() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 2)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(4), UInt32(1), Span(compressed))
    var body: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    _append_frame(wire, Byte(0), Byte(1), UInt32(1), Span(body))
    _append_frame(wire, Byte(1), Byte(4), UInt32(3), Span(compressed))
    var next_body: List[Byte] = [Byte(4)]
    _append_frame(wire, Byte(0), Byte(1), UInt32(3), Span(next_body))

    var result = session.consume(Span(wire))
    assert_true(result.is_request())
    assert_equal(result.stream_id, UInt32(3))
    assert_equal(result.request.body[0], Byte(4))
    var output_offset = 0
    var reset_found = False
    var connection_credit_found = False
    while output_offset < len(result.output):
        var output_frame = parse_frame(Span(result.output)[output_offset:])
        assert_true(output_frame.is_complete())
        if output_frame.frame_type == Byte(3):
            var reset_fields = parse_rst_stream_frame(
                output_frame,
                Span(result.output)[output_offset + 9 : output_offset + 13],
            )
            assert_true(reset_fields.is_valid())
            assert_equal(output_frame.stream_id, UInt32(1))
            assert_equal(reset_fields.error_code, UInt32(11))
            reset_found = True
        if output_frame.frame_type == Byte(8) and output_frame.stream_id == 0:
            var update = parse_window_update_frame(
                output_frame,
                Span(result.output)[output_offset + 9 : output_offset + 13],
            )
            assert_true(update.is_valid())
            if update.increment == 3:
                connection_credit_found = True
        output_offset += output_frame.consumed
    assert_true(reset_found)
    assert_true(connection_credit_found)


def test_http2_request_session_bootstraps_before_loading_hpack() raises:
    var session = Http2RequestSession("build/http2/not-present", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))

    var result = session.consume(Span(wire))
    assert_true(result.is_pending())
    assert_equal(len(result.output), 24)


def test_http2_request_session_returns_data_receive_credit() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(4), UInt32(1), Span(compressed))
    var body: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    _append_frame(wire, Byte(0), Byte(0), UInt32(1), Span(body))

    var result = session.consume(Span(wire))
    assert_true(result.is_pending())
    assert_equal(len(result.output), 50)
    var connection_update = parse_frame(Span(result.output)[24:])
    assert_equal(connection_update.frame_type, Byte(8))
    assert_equal(connection_update.stream_id, UInt32(0))
    assert_equal(connection_update.payload_length, 4)
    assert_equal(result.output[33], Byte(0))
    assert_equal(result.output[36], Byte(3))
    var stream_update = parse_frame(Span(result.output)[37:])
    assert_equal(stream_update.frame_type, Byte(8))
    assert_equal(stream_update.stream_id, UInt32(1))


def test_http2_request_session_exposes_peer_stream_send_window() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var settings: List[Byte] = [
        Byte(0),
        Byte(4),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(settings))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))

    var result = session.consume(Span(wire))
    assert_true(result.is_request())
    assert_equal(session.send_window(UInt32(1)), 0)


def test_http2_request_session_debits_connection_window_updates() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var settings: List[Byte] = [
        Byte(0),
        Byte(4),
        Byte(0),
        Byte(1),
        Byte(0x86),
        Byte(0xA0),
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(settings))
    var increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(10)]
    _append_frame(wire, Byte(8), Byte(0), UInt32(0), Span(increment))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))

    var result = session.consume(Span(wire))
    assert_true(result.is_request())
    assert_equal(session.send_window(UInt32(1)), 65545)


def test_http2_request_session_tracks_outbound_credit_per_stream() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var first = session.consume(Span(wire))
    assert_true(first.is_request())
    var second = session.consume(Span(wire)[first.consumed :])
    assert_true(second.is_request())
    assert_equal(session.send_window(UInt32(1)), 65535)
    assert_equal(session.send_window(UInt32(3)), 65535)

    var updates = List[Byte]()
    var connection_increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(10)]
    var first_increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(3)]
    var second_increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(7)]
    _append_frame(
        updates, Byte(8), Byte(0), UInt32(0), Span(connection_increment)
    )
    _append_frame(updates, Byte(8), Byte(0), UInt32(1), Span(first_increment))
    _append_frame(updates, Byte(8), Byte(0), UInt32(3), Span(second_increment))
    var credit = session.consume(Span(updates))
    assert_true(credit.is_pending())
    assert_equal(session.send_window(UInt32(1)), 65538)
    assert_equal(session.send_window(UInt32(3)), 65542)
    assert_true(session.consume_outbound(UInt32(1), 3))
    assert_equal(session.send_window(UInt32(1)), 65535)
    assert_equal(session.send_window(UInt32(3)), 65542)
    session.finish_response(UInt32(1))
    assert_equal(session.send_window(UInt32(1)), 0)
    assert_equal(session.send_window(UInt32(3)), 65542)


def test_http2_response_scheduler_resumes_each_stream_after_window_update() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var initial_window: List[Byte] = [
        Byte(0),
        Byte(4),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(2),
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(initial_window))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var first = session.consume(Span(wire))
    assert_true(first.is_request())
    var second = session.consume(Span(wire)[first.consumed :])
    assert_true(second.is_request())
    var stream_three_credit: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(2)]
    var update = List[Byte]()
    _append_frame(
        update, Byte(8), Byte(0), UInt32(3), Span(stream_three_credit)
    )
    assert_true(session.consume(Span(update)).is_pending())

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    var first_body: List[Byte] = [
        Byte(ord("a")),
        Byte(ord("b")),
        Byte(ord("c")),
        Byte(ord("d")),
        Byte(ord("e")),
    ]
    var second_body: List[Byte] = [
        Byte(ord("v")),
        Byte(ord("w")),
        Byte(ord("x")),
        Byte(ord("y")),
        Byte(ord("z")),
    ]
    assert_true(_enqueue_response(scheduler, UInt32(1), 200, first_body^))
    assert_true(_enqueue_response(scheduler, UInt32(3), 200, second_body^))
    var first_batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(first_batch.completed_streams), 0)
    var first_bytes_1 = 0
    var first_bytes_3 = 0
    var saw_end_stream = False
    var offset = 0
    while offset < len(first_batch.wire):
        var frame = parse_frame(Span(first_batch.wire)[offset:])
        if frame.frame_type == Byte(0):
            if frame.stream_id == UInt32(1):
                first_bytes_1 += frame.payload_length
            elif frame.stream_id == UInt32(3):
                first_bytes_3 += frame.payload_length
            if frame.flags & Byte(1) != Byte(0):
                saw_end_stream = True
        offset += frame.consumed
    assert_false(saw_end_stream)
    assert_equal(first_bytes_1, 2)
    assert_equal(first_bytes_3, 4)
    assert_equal(session.send_window(UInt32(1)), 0)
    assert_equal(session.send_window(UInt32(3)), 0)

    var more_credit = List[Byte]()
    var first_increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(3)]
    var second_increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(1)]
    _append_frame(
        more_credit, Byte(8), Byte(0), UInt32(1), Span(first_increment)
    )
    _append_frame(
        more_credit, Byte(8), Byte(0), UInt32(3), Span(second_increment)
    )
    assert_true(session.consume(Span(more_credit)).is_pending())
    var final_batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(final_batch.completed_streams), 2)
    assert_true(final_batch.released_bytes > 0)
    var final_bytes_1 = 0
    var final_bytes_3 = 0
    var end_stream_count = 0
    offset = 0
    while offset < len(final_batch.wire):
        var frame = parse_frame(Span(final_batch.wire)[offset:])
        assert_equal(frame.frame_type, Byte(0))
        if frame.stream_id == UInt32(1):
            final_bytes_1 += frame.payload_length
        elif frame.stream_id == UInt32(3):
            final_bytes_3 += frame.payload_length
        if frame.flags & Byte(1) != Byte(0):
            end_stream_count += 1
        offset += frame.consumed
    assert_equal(end_stream_count, 2)
    assert_equal(final_bytes_1, 3)
    assert_equal(final_bytes_3, 1)
    assert_equal(session.send_window(UInt32(1)), 0)
    assert_equal(session.send_window(UInt32(3)), 0)

    var cancelled = Http2ResponseScheduler()
    var cancel_body: List[Byte] = [Byte(1), Byte(2)]
    assert_true(_enqueue_response(cancelled, UInt32(5), 200, cancel_body^))
    var released_cancel = cancelled.cancel(UInt32(5))
    assert_true(released_cancel > 0)
    assert_equal(cancelled.cancel(UInt32(5)), 0)
    assert_equal(cancelled.queued_count(), 0)


def test_http2_request_session_reports_reset_stream_for_response_cancel() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))
    var request = session.consume(Span(wire))
    assert_true(request.is_request())

    var reset_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(8)]
    var reset = List[Byte]()
    _append_frame(reset, Byte(3), Byte(0), UInt32(1), Span(reset_payload))
    var result = session.consume(Span(reset))
    assert_true(result.is_pending())
    assert_equal(result.reset_stream_id, UInt32(1))


def test_http2_request_session_rejects_reset_on_idle_stream() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var reset_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(0)]
    _append_frame(wire, Byte(3), Byte(0), UInt32(1), Span(reset_payload))

    var result = session.consume(Span(wire))
    assert_true(result.is_error())


def test_http2_request_session_rejects_reset_on_idle_server_stream() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var request = session.consume(Span(wire))
    assert_true(request.is_request())

    var reset_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(0)]
    var reset = List[Byte]()
    _append_frame(reset, Byte(3), Byte(0), UInt32(2), Span(reset_payload))
    assert_true(session.consume(Span(reset)).is_error())


def test_http2_request_session_returns_padding_flow_credit() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty: List[Byte] = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    var compressed: List[Byte] = [
        Byte(0x82),
        Byte(0x86),
        Byte(0x84),
        Byte(0x41),
        Byte(0x0F),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord("w")),
        Byte(ord(".")),
        Byte(ord("e")),
        Byte(ord("x")),
        Byte(ord("a")),
        Byte(ord("m")),
        Byte(ord("p")),
        Byte(ord("l")),
        Byte(ord("e")),
        Byte(ord(".")),
        Byte(ord("c")),
        Byte(ord("o")),
        Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(4), UInt32(1), Span(compressed))
    var padded: List[Byte] = [Byte(2), Byte(ord("x")), Byte(0), Byte(0)]
    _append_frame(wire, Byte(0), Byte(9), UInt32(1), Span(padded))

    var result = session.consume(Span(wire))
    assert_true(result.is_request())
    assert_equal(len(result.request.body), 1)
    assert_equal(len(result.output), 50)
    assert_equal(result.output[36], Byte(4))
    assert_equal(result.output[49], Byte(4))


def _bootstrap_session(mut session: Http2RequestSession) raises:
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var empty = List[Byte]()
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(empty))
    assert_true(session.consume(Span(wire)).is_pending())


def test_http2_scheduler_peer_reset_before_headers_sent_drops_entry() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var compressed: List[Byte] = [0x82, 0x86, 0x84, 0x01, 0x01, Byte(ord("x"))]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(compressed))
    _append_frame(opening, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var opened = session.consume(Span(opening))
    assert_true(opened.is_request())
    var sibling = session.consume(Span(opening)[opened.consumed :])
    assert_true(sibling.is_request())

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    var body1: List[Byte] = [Byte(ord("a")), Byte(ord("b"))]
    var body3: List[Byte] = [Byte(ord("c"))]
    assert_true(_enqueue_response(scheduler, UInt32(1), 200, body1^))
    assert_true(_enqueue_response(scheduler, UInt32(3), 200, body3^))

    var reset = scheduler.on_peer_reset(UInt32(1))
    assert_false(reset.kept_headers)
    assert_true(reset.released_bytes > 0)
    assert_equal(scheduler.queued_count(), 1)

    var batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(scheduler.queued_count(), 0)
    assert_equal(len(batch.completed_streams), 1)
    assert_equal(batch.completed_streams[0], UInt32(3))
    # Stream 1 was reset before its HEADERS were encoded, so the scheduler
    # emits nothing on that stream: no HEADERS and no RST_STREAM. HPACK
    # state is unchanged by the cancelled stream, keeping the single
    # connection deflater in sync with the wire for stream 3's HEADERS.
    var saw_any_on_one = False
    var offset = 0
    while offset < len(batch.wire):
        var frame = parse_frame(Span(batch.wire)[offset:])
        if frame.stream_id == UInt32(1):
            saw_any_on_one = True
        offset += frame.consumed
    assert_false(saw_any_on_one)


def test_http2_scheduler_peer_reset_after_headers_sent_removes_entry() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var compressed: List[Byte] = [0x82, 0x86, 0x84, 0x01, 0x01, Byte(ord("x"))]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(compressed))
    var opened = session.consume(Span(opening))
    assert_true(opened.is_request())

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    var body1 = List[Byte](capacity=10000)
    for _ in range(10000):
        body1.append(Byte(ord("x")))
    assert_true(_enqueue_response(scheduler, UInt32(1), 200, body1^))

    # First drain emits HEADERS plus a partial DATA frame; the rest of the
    # body stays queued because the output budget is exhausted.
    var first = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 5000
    )
    assert_equal(len(first.completed_streams), 0)
    assert_true(scheduler.queued_count() > 0)
    var reset = scheduler.on_peer_reset(UInt32(1))
    assert_true(reset.kept_headers)
    assert_true(reset.released_bytes > 0)
    assert_equal(scheduler.queued_count(), 1)
    var second = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(second.completed_streams), 1)
    assert_equal(scheduler.queued_count(), 0)
    # RFC 9113 §5.4.2 forbids replying to a peer RST_STREAM with another
    # RST_STREAM; the scheduler must drop the entry without emitting
    # another frame on the closed stream.
    var saw_rst_on_one = False
    var offset = 0
    while offset < len(second.wire):
        var frame = parse_frame(Span(second.wire)[offset:])
        if frame.frame_type == Byte(3) and frame.stream_id == UInt32(1):
            saw_rst_on_one = True
        offset += frame.consumed
    assert_false(saw_rst_on_one)


def test_http2_scheduler_lazy_encode_keeps_single_inflater_in_sync() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var compressed: List[Byte] = [0x82, 0x86, 0x84, 0x01, 0x01, Byte(ord("x"))]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(compressed))
    _append_frame(opening, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var opened = session.consume(Span(opening))
    assert_true(opened.is_request())
    var sibling = session.consume(Span(opening)[opened.consumed :])
    assert_true(sibling.is_request())

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    var body1: List[Byte] = [Byte(ord("a"))]
    var body3: List[Byte] = [Byte(ord("b"))]
    assert_true(_enqueue_response(scheduler, UInt32(1), 200, body1^))
    assert_true(_enqueue_response(scheduler, UInt32(3), 200, body3^))

    var batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(batch.completed_streams), 2)

    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var offset = 0
    var decoded_streams = List[UInt32]()
    while offset < len(batch.wire):
        var frame = parse_frame(Span(batch.wire)[offset:])
        if frame.frame_type == Byte(1):
            var payload_start = offset + 9
            var block = Span(batch.wire)[
                payload_start : payload_start + frame.payload_length
            ]
            var decode_out = Array[Byte, 512](fill=0)
            var decoded = inflater.decode(block, 4096, 32, Span(decode_out))
            assert_true(decoded.is_success())
            assert_true(decoded.field_count >= 1)
            decoded_streams.append(frame.stream_id)
        offset += frame.consumed
    assert_equal(len(decoded_streams), 2)
    assert_equal(decoded_streams[0], UInt32(1))
    assert_equal(decoded_streams[1], UInt32(3))


def _enqueue_from_writer(
    mut scheduler: Http2ResponseScheduler,
    stream_id: UInt32,
    var body: List[Byte],
    mut writer: ResponseWriter,
) raises -> Bool:
    var trailer_encoded = encode_http2_response_trailers(
        writer, False, 4096, 32
    )
    assert_true(trailer_encoded.is_valid())
    var trailer_fields = trailer_encoded.fields^
    trailer_encoded.fields = List[Byte]()
    var trailer_count = trailer_encoded.field_count
    writer.write(Span(body))
    var fields = encode_http2_response_headers(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 4096, 32
    )
    assert_true(fields.is_valid())
    var fields_bytes = fields.fields^
    fields.fields = List[Byte]()
    var count = fields.field_count
    return scheduler.enqueue(
        stream_id,
        fields_bytes^,
        count,
        4096,
        32,
        4096,
        body^,
        trailers=trailer_fields^,
        trailer_field_count=trailer_count,
    )


def _enqueue_with_trailers(
    mut scheduler: Http2ResponseScheduler,
    stream_id: UInt32,
    var body: List[Byte],
    mut writer: ResponseWriter,
) raises:
    assert_true(_enqueue_from_writer(scheduler, stream_id, body^, writer))


def test_http2_scheduler_sends_trailer_headers_after_data() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var opening_fields: List[Byte] = [
        0x82,
        0x86,
        0x84,
        0x01,
        0x01,
        Byte(ord("x")),
    ]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(opening_fields))
    assert_true(session.consume(Span(opening)).is_request())

    var writer = ResponseWriter(64)
    writer.set_status(200)
    writer.add_trailer(String("x-digest"), String("deadbeef"))
    var body: List[Byte] = [Byte(ord("A")), Byte(ord("B")), Byte(ord("C"))]

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    _enqueue_with_trailers(scheduler, UInt32(1), body^, writer)

    var batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(batch.completed_streams), 1)
    assert_equal(batch.completed_streams[0], UInt32(1))

    var saw_data_without_end = False
    var saw_trailer_headers = False
    var offset = 0
    while offset < len(batch.wire):
        var frame = parse_frame(Span(batch.wire)[offset:])
        assert_true(frame.is_complete())
        if frame.frame_type == Byte(0):
            saw_data_without_end = True
            assert_equal(frame.flags & Byte(1), Byte(0))
        elif frame.frame_type == Byte(1):
            if saw_data_without_end:
                saw_trailer_headers = True
                assert_equal(frame.flags & Byte(1), Byte(1))
                assert_equal(frame.flags & Byte(4), Byte(4))
                var inflater = Http2HpackInflater(
                    "build/http2/libnet_hpack", 4096
                )
                var decoded_fields = Array[Byte, 1024](fill=0)
                var decoded = inflater.decode(
                    Span(batch.wire)[offset + 9 : offset + frame.consumed],
                    4096,
                    32,
                    Span(decoded_fields),
                )
                assert_true(decoded.is_success())
                assert_equal(decoded.field_count, 1)
        offset += frame.consumed
    assert_true(saw_data_without_end)
    assert_true(saw_trailer_headers)


def test_http2_scheduler_withholds_trailers_until_credit_arrives() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var initial_window: List[Byte] = [
        Byte(0),
        Byte(4),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(2),
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(initial_window))
    var opening_fields: List[Byte] = [
        0x82,
        0x86,
        0x84,
        0x01,
        0x01,
        Byte(ord("x")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(opening_fields))
    assert_true(session.consume(Span(wire)).is_request())

    var writer = ResponseWriter(64)
    writer.set_status(200)
    writer.add_trailer(String("x-digest"), String("ff"))
    var body: List[Byte] = [
        Byte(ord("a")),
        Byte(ord("b")),
        Byte(ord("c")),
        Byte(ord("d")),
    ]

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    _enqueue_with_trailers(scheduler, UInt32(1), body^, writer)

    var first = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(first.completed_streams), 0)
    var saw_trailers_before_credit = False
    var offset = 0
    while offset < len(first.wire):
        var frame = parse_frame(Span(first.wire)[offset:])
        if (
            frame.frame_type == Byte(1)
            and frame.stream_id == UInt32(1)
            and (frame.flags & Byte(1)) == Byte(1)
        ):
            saw_trailers_before_credit = True
        offset += frame.consumed
    assert_false(saw_trailers_before_credit)

    var credit = List[Byte]()
    var increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(4)]
    _append_frame(credit, Byte(8), Byte(0), UInt32(1), Span(increment))
    assert_true(session.consume(Span(credit)).is_pending())

    var second = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(second.completed_streams), 1)
    var saw_trailer_headers = False
    offset = 0
    while offset < len(second.wire):
        var frame = parse_frame(Span(second.wire)[offset:])
        if frame.frame_type == Byte(1) and (frame.flags & Byte(1)) == Byte(1):
            saw_trailer_headers = True
        offset += frame.consumed
    assert_true(saw_trailer_headers)


def test_http2_scheduler_interleaved_trailers_decode_in_order() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var opening_fields: List[Byte] = [
        0x82,
        0x86,
        0x84,
        0x01,
        0x01,
        Byte(ord("x")),
    ]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(opening_fields))
    _append_frame(opening, Byte(1), Byte(5), UInt32(3), Span(opening_fields))
    var first = session.consume(Span(opening))
    assert_true(first.is_request())
    var second = session.consume(Span(opening)[first.consumed :])
    assert_true(second.is_request())

    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var writer1 = ResponseWriter(64)
    writer1.set_status(200)
    writer1.headers.add("x-trace", "one")
    writer1.add_trailer(String("x-digest"), String("1111"))
    var writer3 = ResponseWriter(64)
    writer3.set_status(200)
    writer3.headers.add("x-trace", "two")
    writer3.add_trailer(String("x-digest"), String("3333"))

    var scheduler = Http2ResponseScheduler()
    var body1: List[Byte] = [Byte(ord("x")), Byte(ord("y"))]
    var body3: List[Byte] = [Byte(ord("p")), Byte(ord("q"))]
    _enqueue_with_trailers(scheduler, UInt32(1), body1^, writer1)
    _enqueue_with_trailers(scheduler, UInt32(3), body3^, writer3)

    var batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(batch.completed_streams), 2)
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var header_blocks_seen = 0
    var offset = 0
    while offset < len(batch.wire):
        var frame = parse_frame(Span(batch.wire)[offset:])
        if frame.frame_type == Byte(1):
            var decoded_fields = Array[Byte, 2048](fill=0)
            var decoded = inflater.decode(
                Span(batch.wire)[offset + 9 : offset + frame.consumed],
                4096,
                32,
                Span(decoded_fields),
            )
            assert_true(decoded.is_success())
            header_blocks_seen += 1
        offset += frame.consumed
    # Two response HEADERS + two trailer HEADERS, all decoded consistently.
    assert_equal(header_blocks_seen, 4)


def test_http2_scheduler_trailer_decodes_after_intervening_hpack_updates() raises:
    # Regression: trailer HEADERS must decode to exactly the field the
    # handler added even when the deflater's dynamic table has mutated
    # between the trailer's encode time and its wire position. nghttp2's
    # NGHTTP2_NV_FLAG_NO_INDEX still emits "Literal Header Field Never
    # Indexed - Indexed Name" when the name is already present, so a
    # later stream's response HEADERS inserting a new entry shifts the
    # inflater's relative index and the trailer's name resolves to the
    # wrong field. Our encoder sidesteps this by writing literal-name
    # entries that reference no dynamic index.
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    var initial_window: List[Byte] = [
        Byte(0),
        Byte(4),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(initial_window))
    var compressed: List[Byte] = [
        0x82,
        0x86,
        0x84,
        0x01,
        0x01,
        Byte(ord("x")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var first = session.consume(Span(wire))
    assert_true(first.is_request())
    var second = session.consume(Span(wire)[first.consumed :])
    assert_true(second.is_request())

    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var writer_a = ResponseWriter(64)
    writer_a.set_status(200)
    writer_a.headers.add("x-digest", "value-a")
    writer_a.add_trailer(String("x-digest"), String("trailer-z"))
    var writer_b = ResponseWriter(64)
    writer_b.set_status(200)
    writer_b.headers.add("x-other", "value-b")

    var body_a: List[Byte] = [Byte(ord("A")), Byte(ord("B"))]
    var body_b = List[Byte]()

    var scheduler = Http2ResponseScheduler()
    _enqueue_with_trailers(scheduler, UInt32(1), body_a^, writer_a)
    assert_true(_enqueue_from_writer(scheduler, UInt32(3), body_b^, writer_b))

    var first_batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    # Stream 1 is flow-blocked; stream 3 has no body and completes.
    var completed_without_credit = List[UInt32]()
    for i in range(len(first_batch.completed_streams)):
        completed_without_credit.append(first_batch.completed_streams[i])
    assert_equal(len(completed_without_credit), 1)
    assert_equal(completed_without_credit[0], UInt32(3))

    var credit = List[Byte]()
    var increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(2)]
    _append_frame(credit, Byte(8), Byte(0), UInt32(1), Span(increment))
    assert_true(session.consume(Span(credit)).is_pending())
    var second_batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(second_batch.completed_streams), 1)
    assert_equal(second_batch.completed_streams[0], UInt32(1))

    var all_wire = first_batch.wire^
    first_batch.wire = List[Byte]()
    all_wire.extend(Span(second_batch.wire))
    second_batch.wire = List[Byte]()

    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var trailer_name = String()
    var trailer_value = String()
    var saw_trailer = False
    var offset = 0
    while offset < len(all_wire):
        var frame = parse_frame(Span(all_wire)[offset:])
        assert_true(frame.is_complete())
        if frame.frame_type == Byte(1):
            var decoded_fields = Array[Byte, 2048](fill=0)
            var decoded = inflater.decode(
                Span(all_wire)[offset + 9 : offset + frame.consumed],
                4096,
                32,
                Span(decoded_fields),
            )
            assert_true(decoded.is_success())
            if frame.stream_id == UInt32(1) and (frame.flags & Byte(1)) == Byte(
                1
            ):
                saw_trailer = True
                var cursor = 0
                while cursor < decoded.output_length:
                    var nlen = (
                        (Int(decoded_fields[cursor]) << 24)
                        | (Int(decoded_fields[cursor + 1]) << 16)
                        | (Int(decoded_fields[cursor + 2]) << 8)
                        | Int(decoded_fields[cursor + 3])
                    )
                    var vlen = (
                        (Int(decoded_fields[cursor + 4]) << 24)
                        | (Int(decoded_fields[cursor + 5]) << 16)
                        | (Int(decoded_fields[cursor + 6]) << 8)
                        | Int(decoded_fields[cursor + 7])
                    )
                    cursor += 8
                    var name = String(
                        from_utf8_lossy=Span(decoded_fields)[
                            cursor : cursor + nlen
                        ]
                    )
                    cursor += nlen
                    var value = String(
                        from_utf8_lossy=Span(decoded_fields)[
                            cursor : cursor + vlen
                        ]
                    )
                    cursor += vlen
                    trailer_name = name^
                    trailer_value = value^
        offset += frame.consumed

    assert_true(saw_trailer)
    assert_equal(trailer_name, String("x-digest"))
    assert_equal(trailer_value, String("trailer-z"))


def test_http2_scheduler_empty_body_with_trailers_emits_both_blocks() raises:
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var compressed: List[Byte] = [0x82, 0x86, 0x84, 0x01, 0x01, Byte(ord("x"))]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(compressed))
    assert_true(session.consume(Span(opening)).is_request())

    var writer = ResponseWriter(64)
    writer.set_status(200)
    writer.add_trailer(String("x-digest"), String("empty-body"))
    var body = List[Byte]()

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    _enqueue_with_trailers(scheduler, UInt32(1), body^, writer)

    var batch = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(batch.completed_streams), 1)
    assert_equal(batch.completed_streams[0], UInt32(1))
    # Response HEADERS must not carry END_STREAM so trailer HEADERS can
    # follow with END_STREAM.
    var header_frames = 0
    var header_end_streams = 0
    var trailer_end_streams = 0
    var offset = 0
    while offset < len(batch.wire):
        var frame = parse_frame(Span(batch.wire)[offset:])
        if frame.frame_type == Byte(1):
            header_frames += 1
            if header_frames == 1 and frame.flags & Byte(1) != Byte(0):
                header_end_streams += 1
            elif header_frames > 1 and frame.flags & Byte(1) != Byte(0):
                trailer_end_streams += 1
        offset += frame.consumed
    assert_equal(header_frames, 2)
    assert_equal(header_end_streams, 0)
    assert_equal(trailer_end_streams, 1)


def test_http2_scheduler_defers_trailer_block_when_output_room_is_tight() raises:
    # Regression (RFC 9113 §6.10): the trailer HEADERS block must appear
    # on the wire contiguously. If the drain batch cannot fit the full
    # block, the scheduler must defer it rather than emit a prefix that
    # a later control frame could interleave.
    var session = Http2RequestSession("build/http2/libnet_hpack", 4, 1024)
    _bootstrap_session(session)
    var compressed: List[Byte] = [0x82, 0x86, 0x84, 0x01, 0x01, Byte(ord("x"))]
    var opening = List[Byte]()
    _append_frame(opening, Byte(1), Byte(5), UInt32(1), Span(compressed))
    assert_true(session.consume(Span(opening)).is_request())

    # ~300-byte trailer value makes the full trailer block fit within
    # the production drain batch (65536) but not within the tight
    # residual the body phase leaves below.
    var writer = ResponseWriter(2048)
    writer.set_status(200)
    writer.add_trailer(String("x-digest"), String("Z") * 300)

    var scheduler = Http2ResponseScheduler()
    var deflater = _make_deflater()
    # Body: 300 bytes. First drain: budget 2048. Response HEADERS
    # (~120 B) + DATA(300 B) + 9-byte frame header ~= 429 B, which
    # leaves ~1619 B for a trailer worst bound of ~330+128+32 = ~490 B
    # — but the trailer's gate on the pre-encode worst case
    # (len(fields) + 32 + 160) is 300+8+32+160 = ~500 B. Combined with
    # the frame overhead that still exceeds the residual room after
    # the body, forcing deferral.
    var body = List[Byte]()
    for _ in range(300):
        body.append(Byte(ord("A")))
    _enqueue_with_trailers(scheduler, UInt32(1), body^, writer)

    var tight = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 650
    )
    assert_equal(len(tight.completed_streams), 0)
    var tight_header_frames = 0
    var tight_offset = 0
    while tight_offset < len(tight.wire):
        var frame = parse_frame(Span(tight.wire)[tight_offset:])
        assert_true(frame.is_complete())
        if frame.frame_type == Byte(1):
            tight_header_frames += 1
        tight_offset += frame.consumed
    # Only response HEADERS went out; the trailer block was deferred.
    assert_equal(tight_header_frames, 1)

    # Second drain has full room, so the deferred trailer block emits
    # atomically and the stream completes.
    var completing = scheduler.drain(
        session, deflater, "Thu, 01 Jan 1970 00:00:00 GMT", 16384, 65536
    )
    assert_equal(len(completing.completed_streams), 1)
    assert_equal(completing.completed_streams[0], UInt32(1))
    var trailer_header_frames = 0
    var trailer_offset = 0
    while trailer_offset < len(completing.wire):
        var frame = parse_frame(Span(completing.wire)[trailer_offset:])
        assert_true(frame.is_complete())
        if frame.frame_type == Byte(1):
            trailer_header_frames += 1
            assert_equal(frame.flags & Byte(1), Byte(1))
            assert_equal(frame.flags & Byte(4), Byte(4))
        trailer_offset += frame.consumed
    assert_equal(trailer_header_frames, 1)


def test_hpack_deflate_bound_matches_encoded_output() raises:
    # Regression: the scheduler's drain gate must use nghttp2's actual
    # deflate bound. Hand-rolled estimates can push valid responses
    # above the drain batch and trigger a bogus 500 fallback.
    var deflater = _make_deflater()
    var fields = List[Byte]()
    _append_hpack_field(fields, ":status", "200")
    _append_hpack_field(fields, "x-pad", "a" * 1000)
    var bound = deflater.deflate_bound(Span(fields))
    assert_true(bound > 0)
    var output = Array[Byte, 2048](fill=0)
    var encoded = deflater.encode(Span(fields), 65536, 32, Span(output))
    assert_true(encoded.is_success())
    assert_true(encoded.output_length <= bound)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
