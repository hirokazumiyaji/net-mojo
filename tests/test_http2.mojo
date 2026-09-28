from std.testing import assert_equal, assert_true, TestSuite

from net.http._http2.frame import parse_frame
from net.http._http2.preface import parse_client_preface
from net.http._http2.settings import (
    Setting,
    encode_settings_payload,
    parse_settings_payload,
)


def test_partial_client_preface_needs_more_data() raises:
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for length in range(24):
        var result = parse_client_preface(preface[0:length])
        assert_true(result.is_need_more())


def test_complete_client_preface_reports_consumed_bytes() raises:
    var wire = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        wire.append(preface[i])
    wire.append(Byte(0))
    var result = parse_client_preface(Span(wire))
    assert_true(result.is_complete())
    assert_equal(result.consumed, 24)


def test_invalid_client_preface_is_rejected() raises:
    var result = parse_client_preface(
        "XRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    )
    assert_true(result.is_error())


def _frame(
    frame_type: Int,
    flags: Int,
    stream_id: Int,
    payload: List[Byte],
) -> List[Byte]:
    var out = List[Byte]()
    out.append(Byte(len(payload) >> 16))
    out.append(Byte((len(payload) >> 8) & 0xFF))
    out.append(Byte(len(payload) & 0xFF))
    out.append(Byte(frame_type))
    out.append(Byte(flags))
    out.append(Byte((stream_id >> 24) & 0xFF))
    out.append(Byte((stream_id >> 16) & 0xFF))
    out.append(Byte((stream_id >> 8) & 0xFF))
    out.append(Byte(stream_id & 0xFF))
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


def test_payload_at_configured_frame_limit_is_accepted() raises:
    var payload = List[Byte]()
    payload.append(Byte(1))
    payload.append(Byte(2))
    payload.append(Byte(3))
    var wire = _frame(0, 1, 7, payload)
    var result = parse_frame(Span(wire), 3)
    assert_true(result.is_complete())
    assert_equal(result.frame_type, Byte(0))
    assert_equal(result.flags, Byte(1))
    assert_equal(result.stream_id, UInt32(7))
    assert_equal(result.payload_length, 3)
    assert_equal(result.consumed, 12)


def test_partial_header_and_payload_need_more() raises:
    var payload = List[Byte]()
    payload.append(Byte(1))
    payload.append(Byte(2))
    var wire = _frame(1, 0, 3, payload)
    var header_only = List[Byte]()
    for i in range(9):
        header_only.append(wire[i])
    assert_true(parse_frame(Span(header_only)).is_need_more())
    var partial_payload = List[Byte]()
    for i in range(10):
        partial_payload.append(wire[i])
    assert_true(parse_frame(Span(partial_payload)).is_need_more())

    var partial_header = List[Byte]()
    for i in range(8):
        partial_header.append(wire[i])
    assert_true(parse_frame(Span(partial_header)).is_need_more())


def test_oversized_payload_is_rejected_from_header() raises:
    var payload = List[Byte]()
    var wire = _frame(0, 0, 1, payload)
    wire[0] = Byte(0)
    wire[1] = Byte(0)
    wire[2] = Byte(5)
    var result = parse_frame(Span(wire), 4)
    assert_true(result.is_error())


def test_negative_frame_limit_is_rejected() raises:
    var wire = _frame(0, 0, 1, List[Byte]())
    assert_true(parse_frame(Span(wire), -1).is_error())


def test_reserved_stream_bit_is_ignored() raises:
    var wire = _frame(0, 0, 1, List[Byte]())
    wire[5] = Byte(0x80)
    var result = parse_frame(Span(wire))
    assert_true(result.is_complete())
    assert_equal(result.stream_id, UInt32(1))


def test_unknown_frame_type_and_concatenated_frames() raises:
    var first = _frame(0xF0, 0xA5, 0, List[Byte]())
    var second = _frame(6, 1, 0, List[Byte]())
    for i in range(len(second)):
        first.append(second[i])
    var parsed_first = parse_frame(Span(first))
    assert_true(parsed_first.is_complete())
    assert_equal(parsed_first.frame_type, Byte(0xF0))
    assert_equal(parsed_first.consumed, 9)
    var remainder = Span(first)[parsed_first.consumed :]
    var parsed_second = parse_frame(remainder)
    assert_true(parsed_second.is_complete())
    assert_equal(parsed_second.frame_type, Byte(6))


def test_empty_settings_payload_round_trips() raises:
    var parsed = parse_settings_payload(Span(List[Byte]()))
    assert_true(parsed.is_complete())
    assert_equal(len(parsed.settings), 0)
    assert_equal(len(encode_settings_payload(Span(parsed.settings))), 0)


def test_settings_payload_preserves_known_and_unknown_entries() raises:
    var wire = List[Byte]()
    for byte in [Byte(0), Byte(1), Byte(0), Byte(0), Byte(0), Byte(128)]:
        wire.append(byte)
    for byte in [Byte(255), Byte(254), Byte(1), Byte(2), Byte(3), Byte(4)]:
        wire.append(byte)

    var parsed = parse_settings_payload(Span(wire))
    assert_true(parsed.is_complete())
    assert_equal(len(parsed.settings), 2)
    assert_equal(parsed.settings[0].identifier, UInt16(1))
    assert_equal(parsed.settings[0].value, UInt32(128))
    assert_equal(parsed.settings[1].identifier, UInt16(65534))
    assert_equal(parsed.settings[1].value, UInt32(0x01020304))

    var encoded = encode_settings_payload(Span(parsed.settings))
    assert_equal(len(encoded), len(wire))
    for i in range(len(wire)):
        assert_equal(encoded[i], wire[i])


def test_settings_payload_rejects_partial_entry() raises:
    var wire = List[Byte]()
    for _ in range(5):
        wire.append(Byte(0))
    var parsed = parse_settings_payload(Span(wire))
    assert_true(parsed.is_error())
    assert_equal(len(parsed.settings), 0)


def test_setting_encoder_uses_network_byte_order() raises:
    var settings = List[Setting]()
    settings.append(
        Setting(identifier=UInt16(0x1234), value=UInt32(0x01020304))
    )
    var wire = encode_settings_payload(Span(settings))
    assert_equal(wire[0], Byte(0x12))
    assert_equal(wire[1], Byte(0x34))
    assert_equal(wire[2], Byte(0x01))
    assert_equal(wire[3], Byte(0x02))
    assert_equal(wire[4], Byte(0x03))
    assert_equal(wire[5], Byte(0x04))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
