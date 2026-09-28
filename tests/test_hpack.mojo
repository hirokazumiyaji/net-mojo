from std.testing import assert_equal, assert_true, TestSuite

from net.http._http2.hpack import Http2HpackInflater


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
