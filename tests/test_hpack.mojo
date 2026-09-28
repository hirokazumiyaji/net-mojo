from std.testing import assert_equal, assert_true, TestSuite

from net.http._http2.hpack import Http2HpackDeflater, Http2HpackInflater
from net.http._http2.frame import FrameParseResult, parse_frame
from net.http._http2.header_decoder import Http2HeaderDecoder
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

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
