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
from net.http._http2.response_encoder import encode_http2_response
from net.http._http2.request_headers import decode_http2_request_headers
from net.http.response import ResponseWriter
from net.http.request import HttpVersion


def _append_field(mut fields: List[Byte], name: String, value: String):
    var name_bytes = name.as_bytes()
    var value_bytes = value.as_bytes()
    fields.append(Byte((len(name_bytes) >> 24) & 0xFF))
    fields.append(Byte((len(name_bytes) >> 16) & 0xFF))
    fields.append(Byte((len(name_bytes) >> 8) & 0xFF))
    fields.append(Byte(len(name_bytes) & 0xFF))
    fields.append(Byte((len(value_bytes) >> 24) & 0xFF))
    fields.append(Byte((len(value_bytes) >> 16) & 0xFF))
    fields.append(Byte((len(value_bytes) >> 8) & 0xFF))
    fields.append(Byte(len(value_bytes) & 0xFF))
    for i in range(len(name_bytes)):
        fields.append(name_bytes[i])
    for i in range(len(value_bytes)):
        fields.append(value_bytes[i])


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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x8C), Byte(0xF1),
        Byte(0xE3), Byte(0xC2), Byte(0xE5), Byte(0xF2), Byte(0x3A), Byte(0x6B),
        Byte(0xA0), Byte(0xAB), Byte(0x90), Byte(0xF4), Byte(0xFF),
    ]
    var output = Array[Byte, 512](fill=0)
    var result = inflater.decode(
        Span(block), 1024, 16, Span(output)
    )
    assert_true(result.is_success())
    assert_equal(result.field_count, 4)
    assert_true(result.output_length > 0)
    assert_equal(output[0], Byte(0))
    assert_equal(output[3], Byte(7))
    assert_equal(output[8], Byte(ord(":")))


def test_hpack_deflater_encodes_bounded_header_fields() raises:
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var fields = List[Byte]()
    _append_field(fields, String(":status"), String("200"))
    _append_field(fields, String("content-type"), String("text/plain"))
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


def test_shared_response_encodes_to_http2_headers_and_data() raises:
    var writer = ResponseWriter(64)
    writer.set_status(201)
    writer.headers.add("X-Trace", "abc")
    writer.write_string("body")
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var compressed = Array[Byte, 1024](fill=0)
    var encoded = encode_http2_response(
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

    var data = parse_frame(Span(encoded.wire)[headers.consumed:])
    assert_true(data.is_complete())
    assert_equal(data.frame_type, Byte(0))
    assert_equal(data.flags, Byte(1))
    assert_equal(data.payload_length, 4)
    assert_equal(encoded.wire[headers.consumed + 9], Byte(ord("b")))


def test_failed_response_encoding_poisoned_deflater() raises:
    var writer = ResponseWriter(64)
    writer.write_string("body")
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var compressed = Array[Byte, 1024](fill=0)
    var failed = encode_http2_response(
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
    var retried = encode_http2_response(
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
        Byte(0x40), Byte(0x06), Byte(ord("x")), Byte(ord("-")), Byte(ord("t")),
        Byte(ord("e")), Byte(ord("s")), Byte(ord("t")), Byte(0x05), Byte(ord("f")),
        Byte(ord("i")), Byte(ord("r")), Byte(ord("s")), Byte(ord("t")),
    ]
    var output = Array[Byte, 128](fill=0)
    var result = inflater.decode(
        Span(literal), 0, 16, Span(output)
    )
    assert_true(result.is_too_large())
    assert_equal(result.field_count, 1)

    var indexed: List[Byte] = [Byte(0xBE)]
    result = inflater.decode(
        Span(indexed), 1024, 16, Span(output)
    )
    assert_true(result.is_success())
    assert_equal(result.field_count, 1)
    assert_equal(result.output_length, 19)
    assert_equal(output[8], Byte(ord("x")))
    assert_equal(output[14], Byte(ord("f")))


def test_hpack_inflater_reports_decoded_output_limit() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var block: List[Byte] = [Byte(0x82), Byte(0x86)]
    var output = Array[Byte, 4](fill=0)
    var result = inflater.decode(
        Span(block), 1024, 16, Span(output)
    )
    assert_true(result.is_too_large())
    assert_equal(result.field_count, 2)


def test_hpack_inflater_applies_table_limit_between_blocks() raises:
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    assert_true(inflater.set_max_table_size(32))
    var update: List[Byte] = [Byte(0x3F), Byte(0x01)]
    var output = Array[Byte, 8](fill=0)
    var result = inflater.decode(
        Span(update), 1024, 16, Span(output)
    )
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
        Byte(0x84), Byte(0x41), Byte(0x0F), Byte(ord("w")), Byte(ord("w")),
        Byte(ord("w")), Byte(ord(".")), Byte(ord("e")), Byte(ord("x")),
        Byte(ord("a")), Byte(ord("m")), Byte(ord("p")), Byte(ord("l")),
        Byte(ord("e")), Byte(ord(".")), Byte(ord("c")), Byte(ord("o")),
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
    var too_large = decoder.consume(
        headers, Span(block), 0, 16, Span(output)
    )
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
    var wrong_stream = FrameParseResult.complete(
        Byte(9), Byte(4), UInt32(3), 1
    )
    result = decoder.consume(
        wrong_stream, Span(continuation), 1024, 16, Span(output)
    )
    assert_true(result.is_protocol_error())
    var next_headers = FrameParseResult.complete(
        Byte(1), Byte(4), UInt32(3), 1
    )
    result = decoder.consume(
        next_headers, Span(continuation), 1024, 16, Span(output)
    )
    assert_true(result.is_protocol_error())


def test_hpack_headers_become_a_shared_http2_request() raises:
    var decoder = Http2HeaderDecoder("build/http2/libnet_hpack", 4096, 1024)
    var compressed: List[Byte] = [
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x84), Byte(0x41), Byte(0x0F), Byte(ord("w")), Byte(ord("w")),
        Byte(ord("w")), Byte(ord(".")), Byte(ord("e")), Byte(ord("x")),
        Byte(ord("a")), Byte(ord("m")), Byte(ord("p")), Byte(ord("l")),
        Byte(ord("e")), Byte(ord(".")), Byte(ord("c")), Byte(ord("o")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
    assert_false(session.is_failed())
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Span(refused.output)[server_settings.consumed:]
    )
    assert_true(server_ack.is_complete())
    assert_equal(server_ack.flags, Byte(1))
    var rst_offset = server_settings.consumed + server_ack.consumed
    var rst = parse_frame(Span(refused.output)[rst_offset:])
    assert_true(rst.is_complete())
    assert_equal(rst.frame_type, Byte(3))
    assert_equal(rst.stream_id, UInt32(3))
    var rst_fields = parse_rst_stream_frame(
        rst, Span(refused.output)[rst_offset + 9:]
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        var output_frame = parse_frame(
            Span(result.output)[output_offset:]
        )
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0), Byte(4), Byte(0), Byte(0), Byte(0), Byte(0)
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(settings))
    var compressed: List[Byte] = [
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0), Byte(4), Byte(0), Byte(1), Byte(0x86), Byte(0xA0)
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(settings))
    var increment: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(10)]
    _append_frame(wire, Byte(8), Byte(0), UInt32(0), Span(increment))
    var compressed: List[Byte] = [
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
    var connection_increment: List[Byte] = [
        Byte(0), Byte(0), Byte(0), Byte(10)
    ]
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
        Byte(0), Byte(4), Byte(0), Byte(0), Byte(0), Byte(2)
    ]
    _append_frame(wire, Byte(4), Byte(0), UInt32(0), Span(initial_window))
    var compressed: List[Byte] = [
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
    ]
    _append_frame(wire, Byte(1), Byte(5), UInt32(1), Span(compressed))
    _append_frame(wire, Byte(1), Byte(5), UInt32(3), Span(compressed))
    var first = session.consume(Span(wire))
    assert_true(first.is_request())
    var second = session.consume(Span(wire)[first.consumed :])
    assert_true(second.is_request())
    var stream_three_credit: List[Byte] = [
        Byte(0), Byte(0), Byte(0), Byte(2)
    ]
    var update = List[Byte]()
    _append_frame(
        update, Byte(8), Byte(0), UInt32(3), Span(stream_three_credit)
    )
    assert_true(session.consume(Span(update)).is_pending())

    var scheduler = Http2ResponseScheduler()
    var header_payload = List[Byte]()
    var first_headers = List[Byte]()
    var second_headers = List[Byte]()
    _append_frame(first_headers, Byte(1), Byte(0), UInt32(1), Span(header_payload))
    _append_frame(second_headers, Byte(1), Byte(0), UInt32(3), Span(header_payload))
    var first_body: List[Byte] = [
        Byte(ord("a")), Byte(ord("b")), Byte(ord("c")),
        Byte(ord("d")), Byte(ord("e")),
    ]
    var second_body: List[Byte] = [
        Byte(ord("v")), Byte(ord("w")), Byte(ord("x")),
        Byte(ord("y")), Byte(ord("z")),
    ]
    assert_true(
        scheduler.enqueue(UInt32(1), first_headers^, first_body^)
    )
    assert_true(
        scheduler.enqueue(UInt32(3), second_headers^, second_body^)
    )
    var first_batch = scheduler.drain(session, 2, 256)
    assert_equal(len(first_batch.completed_streams), 0)
    var first_data_streams = List[UInt32]()
    var offset = 0
    while offset < len(first_batch.wire):
        var frame = parse_frame(Span(first_batch.wire)[offset:])
        if frame.frame_type == Byte(0):
            first_data_streams.append(frame.stream_id)
            assert_equal(frame.payload_length, 2)
            assert_equal(frame.flags & Byte(1), Byte(0))
        offset += frame.consumed
    assert_equal(first_data_streams[0], UInt32(1))
    assert_equal(first_data_streams[1], UInt32(3))
    assert_equal(first_data_streams[2], UInt32(3))
    assert_equal(session.send_window(UInt32(1)), 0)
    assert_equal(session.send_window(UInt32(3)), 0)

    var more_credit = List[Byte]()
    var first_increment: List[Byte] = [
        Byte(0), Byte(0), Byte(0), Byte(3)
    ]
    var second_increment: List[Byte] = [
        Byte(0), Byte(0), Byte(0), Byte(1)
    ]
    _append_frame(
        more_credit, Byte(8), Byte(0), UInt32(1), Span(first_increment)
    )
    _append_frame(
        more_credit, Byte(8), Byte(0), UInt32(3), Span(second_increment)
    )
    assert_true(session.consume(Span(more_credit)).is_pending())
    var final_batch = scheduler.drain(session, 2, 256)
    assert_equal(len(final_batch.completed_streams), 2)
    assert_equal(final_batch.released_bytes, 28)
    var final_data_streams = List[UInt32]()
    var final_data_flags = List[UInt8]()
    offset = 0
    while offset < len(final_batch.wire):
        var frame = parse_frame(Span(final_batch.wire)[offset:])
        assert_equal(frame.frame_type, Byte(0))
        final_data_streams.append(frame.stream_id)
        final_data_flags.append(frame.flags)
        offset += frame.consumed
    assert_equal(final_data_streams[0], UInt32(1))
    assert_equal(final_data_streams[1], UInt32(3))
    assert_equal(final_data_streams[2], UInt32(1))
    assert_equal(final_data_flags[0] & UInt8(1), UInt8(0))
    assert_equal(final_data_flags[1] & UInt8(1), UInt8(1))
    assert_equal(final_data_flags[2] & UInt8(1), UInt8(1))
    assert_equal(session.send_window(UInt32(1)), 0)
    assert_equal(session.send_window(UInt32(3)), 0)

    var cancelled = Http2ResponseScheduler()
    var cancel_headers = List[Byte]()
    var cancel_body: List[Byte] = [Byte(1), Byte(2)]
    _append_frame(
        cancel_headers, Byte(1), Byte(0), UInt32(5), Span(header_payload)
    )
    assert_true(
        cancelled.enqueue(UInt32(5), cancel_headers^, cancel_body^)
    )
    assert_equal(cancelled.cancel(UInt32(5)), 11)
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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
        Byte(0x82), Byte(0x86), Byte(0x84), Byte(0x41), Byte(0x0F),
        Byte(ord("w")), Byte(ord("w")), Byte(ord("w")), Byte(ord(".")),
        Byte(ord("e")), Byte(ord("x")), Byte(ord("a")), Byte(ord("m")),
        Byte(ord("p")), Byte(ord("l")), Byte(ord("e")), Byte(ord(".")),
        Byte(ord("c")), Byte(ord("o")), Byte(ord("m")),
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

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
