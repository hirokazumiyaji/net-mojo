from std.testing import assert_equal, assert_false, assert_true, TestSuite
from net.http.request import HttpVersion

from net.http._http2.frame import FrameParseResult, parse_frame
from net.http._http2.frame_encoder import encode_frame
from net.http._http2.bootstrap import Http2ServerBootstrap
from net.http._http2.settings_state import Http2PeerSettings
from net.http._http2.stream_state import Http2StreamState
from net.http._http2.stream_table import Http2ActiveStreams
from net.http._http2.preface import parse_client_preface
from net.http._http2.settings import (
    Setting,
    encode_settings_payload,
    parse_settings_payload,
)
from net.http._http2.settings_frame import parse_settings_frame
from net.http._http2.header_block import Http2HeaderBlock
from net.http._http2.flow_window import Http2FlowWindow
from net.http._http2.frame_sequence import Http2ContinuationSequence
from net.http._http2.window_update import parse_window_update_frame
from net.http._http2.control_frames import (
    encode_goaway_frame,
    parse_goaway_frame,
    parse_ping_frame,
    parse_rst_stream_frame,
)
from net.http._http2.request_headers import decode_http2_request_headers


def test_header_block_collects_headers_payload_until_end_headers() raises:
    var block = Http2HeaderBlock(16)
    var first: List[Byte] = [Byte(1), Byte(2)]
    var initial = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 2)
    var result = block.begin(initial, Span(first))
    assert_true(result.is_pending())

    var second: List[Byte] = [Byte(3)]
    var continuation = FrameParseResult.complete(
        Byte(9), Byte(4), UInt32(1), 1
    )
    result = block.continue_with(continuation, Span(second))
    assert_true(result.is_complete())
    var decoded = block.compressed_block()
    assert_equal(len(decoded), 3)
    assert_equal(decoded[0], Byte(1))
    assert_equal(decoded[2], Byte(3))


def test_header_block_skips_padding_and_priority_fields() raises:
    var block = Http2HeaderBlock(16)
    var payload: List[Byte] = [
        Byte(1), Byte(0), Byte(0), Byte(0), Byte(1), Byte(0), Byte(7), Byte(8)
    ]
    var frame = FrameParseResult.complete(Byte(1), Byte(0x2C), UInt32(3), 8)
    var result = block.begin(frame, Span(payload))
    assert_true(result.is_complete())
    var decoded = block.compressed_block()
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0], Byte(7))


def test_header_block_rejects_wrong_stream_continuation() raises:
    var block = Http2HeaderBlock(16)
    var payload: List[Byte] = [Byte(1)]
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 1)
    assert_true(block.begin(headers, Span(payload)).is_pending())
    var wrong = FrameParseResult.complete(Byte(9), Byte(4), UInt32(3), 1)
    assert_true(block.continue_with(wrong, Span(payload)).is_error())


def test_header_block_rejects_compressed_block_over_limit() raises:
    var block = Http2HeaderBlock(2)
    var payload: List[Byte] = [Byte(1), Byte(2)]
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 2)
    assert_true(block.begin(headers, Span(payload)).is_pending())
    var continuation = FrameParseResult.complete(Byte(9), Byte(4), UInt32(1), 1)
    assert_true(block.continue_with(continuation, Span(payload[0:1])).is_error())


def test_http2_flow_window_tracks_data_and_credit_separately() raises:
    var window = Http2FlowWindow(10, 8)
    assert_true(window.consume_outbound(6))
    assert_equal(window.send_window(), 4)
    assert_true(window.receive_data(7))
    assert_equal(window.receive_window(), 1)
    assert_equal(window.pending_receive_credit(), 7)
    assert_true(window.release_received(5))
    assert_equal(window.receive_window(), 6)
    assert_equal(window.pending_receive_credit(), 2)
    assert_false(window.release_received(3))


def test_http2_flow_window_rejects_data_beyond_available_credit() raises:
    var window = Http2FlowWindow(5, 5)
    assert_false(window.consume_outbound(6))
    assert_false(window.receive_data(6))
    assert_equal(window.send_window(), 5)
    assert_equal(window.receive_window(), 5)


def test_http2_flow_window_validates_window_updates() raises:
    var window = Http2FlowWindow(10, 10)
    assert_false(window.apply_window_update(0))
    assert_true(window.apply_window_update(5))
    assert_equal(window.send_window(), 15)
    assert_true(window.receive_data(3))
    assert_equal(window.receive_window(), 7)
    assert_true(window.release_received(3))
    assert_equal(window.receive_window(), 10)
    assert_equal(window.pending_receive_credit(), 0)


def test_http2_flow_window_applies_initial_window_delta() raises:
    var window = Http2FlowWindow(10, 10)
    assert_true(window.consume_outbound(8))
    assert_true(window.update_initial_send_window(6))
    assert_equal(window.send_window(), -2)
    assert_false(window.consume_outbound(1))
    assert_true(window.apply_window_update(4))
    assert_equal(window.send_window(), 2)
    assert_true(window.update_initial_send_window(14))
    assert_equal(window.send_window(), 10)


def test_http2_flow_window_rejects_updates_that_overflow() raises:
    var window = Http2FlowWindow(0x7FFFFFFF, 0x7FFFFFFF)
    assert_false(window.apply_window_update(1))
    assert_false(window.release_received(1))
    assert_false(window.update_initial_send_window(0x80000000))
    assert_false(window.consume_outbound(-1))
    assert_false(window.receive_data(-1))


def test_http2_connection_and_stream_windows_are_independent() raises:
    var connection = Http2FlowWindow(100, 100)
    var stream = Http2FlowWindow(20, 20)
    assert_true(connection.receive_data(8))
    assert_true(stream.receive_data(8))
    assert_true(stream.release_received(8))
    assert_equal(connection.receive_window(), 92)
    assert_equal(connection.pending_receive_credit(), 8)
    assert_equal(stream.receive_window(), 20)


def test_http2_continuation_sequence_accepts_matching_fragment_chain() raises:
    var sequence = Http2ContinuationSequence()
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 4)
    assert_true(sequence.accept(headers))
    var first = FrameParseResult.complete(Byte(9), Byte(0), UInt32(1), 3)
    assert_true(sequence.accept(first))
    var final = FrameParseResult.complete(Byte(9), Byte(4), UInt32(1), 2)
    assert_true(sequence.accept(final))
    var ping = FrameParseResult.complete(Byte(6), Byte(0), UInt32(0), 8)
    assert_true(sequence.accept(ping))


def test_http2_continuation_sequence_rejects_interleaving() raises:
    var sequence = Http2ContinuationSequence()
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 1)
    assert_true(sequence.accept(headers))
    var ping = FrameParseResult.complete(Byte(6), Byte(0), UInt32(0), 8)
    assert_false(sequence.accept(ping))
    var continuation = FrameParseResult.complete(Byte(9), Byte(4), UInt32(1), 1)
    assert_false(sequence.accept(continuation))


def test_http2_continuation_sequence_rejects_orphan_and_wrong_stream() raises:
    var orphan_sequence = Http2ContinuationSequence()
    var orphan = FrameParseResult.complete(Byte(9), Byte(4), UInt32(1), 1)
    assert_false(orphan_sequence.accept(orphan))

    var wrong_stream_sequence = Http2ContinuationSequence()
    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(1), 1)
    assert_true(wrong_stream_sequence.accept(headers))
    var wrong_stream = FrameParseResult.complete(
        Byte(9), Byte(4), UInt32(3), 1
    )
    assert_false(wrong_stream_sequence.accept(wrong_stream))


def test_http2_continuation_sequence_rejects_push_promise_from_client() raises:
    var sequence = Http2ContinuationSequence()
    var push = FrameParseResult.complete(Byte(5), Byte(4), UInt32(1), 4)
    assert_false(sequence.accept(push))


def test_http2_window_update_parses_connection_and_stream_credit() raises:
    var payload: List[Byte] = [Byte(0x80), Byte(0), Byte(0), Byte(5)]
    var connection = FrameParseResult.complete(Byte(8), Byte(0), UInt32(0), 4)
    var parsed = parse_window_update_frame(connection, Span(payload))
    assert_true(parsed.is_valid())
    assert_equal(parsed.stream_id, UInt32(0))
    assert_equal(parsed.increment, UInt32(5))
    var connection_window = Http2FlowWindow(2, 10)
    assert_true(parsed.apply_to(connection_window))
    assert_equal(connection_window.send_window(), 7)

    var stream = FrameParseResult.complete(Byte(8), Byte(0), UInt32(7), 4)
    parsed = parse_window_update_frame(stream, Span(payload))
    assert_true(parsed.is_valid())
    assert_equal(parsed.stream_id, UInt32(7))


def test_http2_window_update_rejects_zero_increment() raises:
    var payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(0)]
    var frame = FrameParseResult.complete(Byte(8), Byte(0), UInt32(0), 4)
    assert_true(parse_window_update_frame(frame, Span(payload)).is_error())


def test_http2_window_update_rejects_invalid_frame_shape() raises:
    var payload: List[Byte] = [Byte(0), Byte(0), Byte(0)]
    var partial = FrameParseResult.complete(Byte(8), Byte(0), UInt32(0), 3)
    assert_true(parse_window_update_frame(partial, Span(payload)).is_error())
    var wrong_type = FrameParseResult.complete(Byte(6), Byte(0), UInt32(0), 3)
    assert_true(parse_window_update_frame(wrong_type, Span(payload)).is_error())
    assert_true(
        parse_window_update_frame(FrameParseResult.failure(), Span(payload)).is_error()
    )


def test_http2_rst_stream_parses_stream_and_error_code() raises:
    var payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(8)]
    var frame = FrameParseResult.complete(Byte(3), Byte(0), UInt32(7), 4)
    var reset = parse_rst_stream_frame(frame, Span(payload))
    assert_true(reset.is_valid())
    assert_equal(reset.stream_id, UInt32(7))
    assert_equal(reset.error_code, UInt32(8))


def test_http2_rst_stream_rejects_invalid_shape_or_connection_stream() raises:
    var payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(0)]
    var connection = FrameParseResult.complete(Byte(3), Byte(0), UInt32(0), 4)
    assert_true(parse_rst_stream_frame(connection, Span(payload)).is_error())
    var wrong_length = FrameParseResult.complete(Byte(3), Byte(0), UInt32(1), 3)
    assert_true(parse_rst_stream_frame(wrong_length, Span(payload[0:3])).is_error())


def test_http2_ping_echoes_opaque_data_only_for_non_ack() raises:
    var payload: List[Byte] = [
        Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8)
    ]
    var frame = FrameParseResult.complete(Byte(6), Byte(0), UInt32(0), 8)
    var ping = parse_ping_frame(frame, Span(payload))
    assert_true(ping.is_valid())
    assert_false(ping.is_ack())
    var ack = ping.encode_ack()
    assert_true(ack.is_complete())
    assert_equal(ack.wire[4], Byte(1))
    for i in range(8):
        assert_equal(ack.wire[9 + i], payload[i])


def test_http2_ping_rejects_ack_response_and_invalid_shape() raises:
    var payload: List[Byte] = [
        Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)
    ]
    var ack_frame = FrameParseResult.complete(Byte(6), Byte(1), UInt32(0), 8)
    var ack = parse_ping_frame(ack_frame, Span(payload))
    assert_true(ack.is_valid())
    assert_true(ack.is_ack())
    assert_true(ack.encode_ack().is_error())
    var wrong_stream = FrameParseResult.complete(Byte(6), Byte(0), UInt32(1), 8)
    assert_true(parse_ping_frame(wrong_stream, Span(payload)).is_error())


def test_http2_goaway_parses_last_stream_and_encodes_frame() raises:
    var payload: List[Byte] = [
        Byte(0xFF), Byte(0xFF), Byte(0xFF), Byte(0xFF),
        Byte(0), Byte(0), Byte(0), Byte(2), Byte(99),
    ]
    var frame = FrameParseResult.complete(Byte(7), Byte(0), UInt32(0), 9)
    var goaway = parse_goaway_frame(frame, Span(payload))
    assert_true(goaway.is_valid())
    assert_equal(goaway.last_stream_id, UInt32(0x7FFFFFFF))
    assert_equal(goaway.error_code, UInt32(2))

    var encoded = encode_goaway_frame(UInt32(7), UInt32(0))
    assert_true(encoded.is_complete())
    assert_equal(encoded.wire[3], Byte(7))
    assert_equal(encoded.wire[12], Byte(7))


def test_http2_goaway_rejects_invalid_shape_or_stream() raises:
    var payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)]
    var frame = FrameParseResult.complete(Byte(7), Byte(0), UInt32(0), 7)
    assert_true(parse_goaway_frame(frame, Span(payload)).is_error())
    var wrong_stream = FrameParseResult.complete(Byte(7), Byte(0), UInt32(1), 8)
    assert_true(parse_goaway_frame(wrong_stream, Span(payload[0:7])).is_error())


def _append_hpack_field(mut wire: List[Byte], name: String, value: String):
    var name_bytes = name.as_bytes()
    var value_bytes = value.as_bytes()
    wire.append(Byte((len(name_bytes) >> 24) & 0xFF))
    wire.append(Byte((len(name_bytes) >> 16) & 0xFF))
    wire.append(Byte((len(name_bytes) >> 8) & 0xFF))
    wire.append(Byte(len(name_bytes) & 0xFF))
    wire.append(Byte((len(value_bytes) >> 24) & 0xFF))
    wire.append(Byte((len(value_bytes) >> 16) & 0xFF))
    wire.append(Byte((len(value_bytes) >> 8) & 0xFF))
    wire.append(Byte(len(value_bytes) & 0xFF))
    for i in range(len(name_bytes)):
        wire.append(name_bytes[i])
    for i in range(len(value_bytes)):
        wire.append(value_bytes[i])


def test_http2_request_headers_map_pseudo_and_regular_fields() raises:
    var encoded = List[Byte]()
    _append_hpack_field(encoded, String(":method"), String("GET"))
    _append_hpack_field(encoded, String(":scheme"), String("https"))
    _append_hpack_field(encoded, String(":authority"), String("example.com"))
    _append_hpack_field(encoded, String(":path"), String("/items?q=1"))
    _append_hpack_field(encoded, String("content-type"), String("application/json"))
    _append_hpack_field(encoded, String("x-tag"), String("one"))
    _append_hpack_field(encoded, String("x-tag"), String("two"))
    var result = decode_http2_request_headers(Span(encoded), 7)
    assert_true(result.is_valid())
    var request = result^.into_request()
    assert_equal(request.method, "GET")
    assert_equal(request.target, "/items?q=1")
    assert_equal(request.path, "/items")
    assert_equal(request.query, "q=1")
    assert_equal(request.scheme, "https")
    assert_equal(request.authority, "example.com")
    assert_equal(request.version, HttpVersion.http2())
    assert_equal(request.headers.count("x-tag"), 2)


def test_http2_request_headers_require_pseudo_fields_before_regular() raises:
    var encoded = List[Byte]()
    _append_hpack_field(encoded, String("x-tag"), String("one"))
    _append_hpack_field(encoded, String(":method"), String("GET"))
    _append_hpack_field(encoded, String(":scheme"), String("https"))
    _append_hpack_field(encoded, String(":path"), String("/"))
    assert_true(decode_http2_request_headers(Span(encoded), 4).is_error())


def test_http2_request_headers_reject_duplicates_and_unknown_pseudo() raises:
    var duplicate = List[Byte]()
    _append_hpack_field(duplicate, String(":method"), String("GET"))
    _append_hpack_field(duplicate, String(":method"), String("POST"))
    _append_hpack_field(duplicate, String(":scheme"), String("https"))
    _append_hpack_field(duplicate, String(":path"), String("/"))
    assert_true(decode_http2_request_headers(Span(duplicate), 4).is_error())

    var unknown = List[Byte]()
    _append_hpack_field(unknown, String(":method"), String("GET"))
    _append_hpack_field(unknown, String(":protocol"), String("websocket"))
    _append_hpack_field(unknown, String(":scheme"), String("https"))
    _append_hpack_field(unknown, String(":path"), String("/"))
    assert_true(decode_http2_request_headers(Span(unknown), 4).is_error())


def test_http2_request_headers_reject_connection_fields_and_invalid_te() raises:
    var connection = List[Byte]()
    _append_hpack_field(connection, String(":method"), String("GET"))
    _append_hpack_field(connection, String(":scheme"), String("https"))
    _append_hpack_field(connection, String(":path"), String("/"))
    _append_hpack_field(connection, String("connection"), String("close"))
    assert_true(decode_http2_request_headers(Span(connection), 4).is_error())

    var te = List[Byte]()
    _append_hpack_field(te, String(":method"), String("GET"))
    _append_hpack_field(te, String(":scheme"), String("https"))
    _append_hpack_field(te, String(":path"), String("/"))
    _append_hpack_field(te, String(":authority"), String("example.com"))
    _append_hpack_field(te, String("te"), String("trailers"))
    assert_true(decode_http2_request_headers(Span(te), 5).is_valid())

    var invalid_te = List[Byte]()
    _append_hpack_field(invalid_te, String(":method"), String("GET"))
    _append_hpack_field(invalid_te, String(":scheme"), String("https"))
    _append_hpack_field(invalid_te, String(":path"), String("/"))
    _append_hpack_field(invalid_te, String(":authority"), String("example.com"))
    _append_hpack_field(invalid_te, String("te"), String("trailers, gzip"))
    assert_true(decode_http2_request_headers(Span(invalid_te), 5).is_error())


def test_http2_request_headers_reject_host_authority_mismatch() raises:
    var encoded = List[Byte]()
    _append_hpack_field(encoded, String(":method"), String("GET"))
    _append_hpack_field(encoded, String(":scheme"), String("https"))
    _append_hpack_field(encoded, String(":authority"), String("example.com"))
    _append_hpack_field(encoded, String(":path"), String("/"))
    _append_hpack_field(encoded, String("host"), String("other.example"))
    assert_true(decode_http2_request_headers(Span(encoded), 5).is_error())


def test_http2_request_headers_validate_authority_port_syntax() raises:
    var encoded = List[Byte]()
    _append_hpack_field(encoded, String(":method"), String("GET"))
    _append_hpack_field(encoded, String(":scheme"), String("https"))
    _append_hpack_field(encoded, String(":authority"), String("example.com:http"))
    _append_hpack_field(encoded, String(":path"), String("/"))
    assert_true(decode_http2_request_headers(Span(encoded), 4).is_error())


def test_http2_request_headers_reject_truncated_serialized_fields() raises:
    var encoded: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(7)]
    assert_true(decode_http2_request_headers(Span(encoded), 1).is_error())


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
    assert_equal(result.error_code, UInt32(6))


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


def test_peer_settings_apply_known_values_in_order_and_ignore_unknown() raises:
    var peer = Http2PeerSettings()
    var settings = List[Setting]()
    settings.append(Setting(identifier=UInt16(1), value=UInt32(1024)))
    settings.append(Setting(identifier=UInt16(1), value=UInt32(2048)))
    settings.append(Setting(identifier=UInt16(2), value=UInt32(1)))
    settings.append(Setting(identifier=UInt16(3), value=UInt32(100)))
    settings.append(Setting(identifier=UInt16(4), value=UInt32(32768)))
    settings.append(Setting(identifier=UInt16(5), value=UInt32(32768)))
    settings.append(Setting(identifier=UInt16(6), value=UInt32(65536)))
    settings.append(Setting(identifier=UInt16(0xFF00), value=UInt32(99)))

    var result = peer.apply(Span(settings))
    assert_true(result.is_success())
    assert_equal(peer.header_table_size, UInt32(2048))
    assert_equal(peer.max_concurrent_streams, UInt32(100))
    assert_equal(peer.initial_window_size, UInt32(32768))
    assert_equal(peer.max_frame_size, UInt32(32768))
    assert_equal(peer.max_header_list_size, UInt32(65536))


def test_peer_settings_reject_invalid_enable_push_value() raises:
    var peer = Http2PeerSettings()
    var settings = List[Setting]()
    settings.append(Setting(identifier=UInt16(2), value=UInt32(2)))
    var result = peer.apply(Span(settings))
    assert_true(result.is_error())
    assert_equal(result.error_code, UInt32(1))


def test_peer_settings_reject_initial_window_overflow() raises:
    var peer = Http2PeerSettings()
    var settings = List[Setting]()
    settings.append(Setting(identifier=UInt16(4), value=UInt32(0x80000000)))
    var result = peer.apply(Span(settings))
    assert_true(result.is_error())
    assert_equal(result.error_code, UInt32(3))


def test_peer_settings_reject_frame_size_out_of_range() raises:
    var too_small = List[Setting]()
    too_small.append(Setting(identifier=UInt16(5), value=UInt32(16383)))
    var peer = Http2PeerSettings()
    var result = peer.apply(Span(too_small))
    assert_true(result.is_error())
    assert_equal(result.error_code, UInt32(1))

    var too_large = List[Setting]()
    too_large.append(Setting(identifier=UInt16(5), value=UInt32(16777216)))
    var another_peer = Http2PeerSettings()
    var oversized = another_peer.apply(Span(too_large))
    assert_true(oversized.is_error())
    assert_equal(oversized.error_code, UInt32(1))


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


def test_frame_encoder_emits_header_in_network_byte_order() raises:
    var payload = List[Byte]()
    payload.append(Byte(0xA5))
    var encoded = encode_frame(
        Byte(0xF0), Byte(0x03), UInt32(0x1234567), Span(payload)
    )
    assert_true(encoded.is_complete())
    assert_equal(len(encoded.wire), 10)
    assert_equal(encoded.wire[0], Byte(0))
    assert_equal(encoded.wire[1], Byte(0))
    assert_equal(encoded.wire[2], Byte(1))
    assert_equal(encoded.wire[3], Byte(0xF0))
    assert_equal(encoded.wire[4], Byte(0x03))
    assert_equal(encoded.wire[5], Byte(0x01))
    assert_equal(encoded.wire[6], Byte(0x23))
    assert_equal(encoded.wire[7], Byte(0x45))
    assert_equal(encoded.wire[8], Byte(0x67))
    assert_equal(encoded.wire[9], Byte(0xA5))

    var parsed = parse_frame(Span(encoded.wire))
    assert_true(parsed.is_complete())
    assert_equal(parsed.frame_type, Byte(0xF0))
    assert_equal(parsed.flags, Byte(0x03))
    assert_equal(parsed.stream_id, UInt32(0x1234567))


def test_frame_encoder_accepts_empty_payload_at_zero_limit() raises:
    var encoded = encode_frame(
        Byte(4), Byte(0), UInt32(0), Span(List[Byte]()), 0
    )
    assert_true(encoded.is_complete())
    assert_equal(len(encoded.wire), 9)
    assert_equal(encoded.wire[8], Byte(0))


def test_frame_encoder_rejects_invalid_stream_id_and_size() raises:
    var payload = List[Byte]()
    payload.append(Byte(1))
    assert_true(
        encode_frame(
            Byte(0), Byte(0), UInt32(0x80000000), Span(payload)
        ).is_error()
    )
    assert_true(
        encode_frame(Byte(0), Byte(0), UInt32(0), Span(payload), 0).is_error()
    )
    assert_true(
        encode_frame(Byte(0), Byte(0), UInt32(0), Span(payload), -1).is_error()
    )
    assert_true(
        encode_frame(
            Byte(0), Byte(0), UInt32(0), Span(List[Byte]()), 16777216
        ).is_error()
    )


def test_settings_frame_accepts_payload_on_stream_zero() raises:
    var payload = List[Byte]()
    for byte in [Byte(0), Byte(1), Byte(0), Byte(0), Byte(0), Byte(128)]:
        payload.append(byte)
    var wire = _frame(4, 0x80, 0, payload)
    var frame = parse_frame(Span(wire))
    var result = parse_settings_frame(frame, Span(wire)[9:])
    assert_true(result.is_settings())
    assert_equal(len(result.parsed.settings), 1)
    assert_equal(result.parsed.settings[0].identifier, UInt16(1))
    assert_equal(result.parsed.settings[0].value, UInt32(128))


def test_settings_frame_accepts_empty_ack() raises:
    var wire = _frame(4, 1, 0, List[Byte]())
    var result = parse_settings_frame(parse_frame(Span(wire)), Span(wire)[9:])
    assert_true(result.is_ack())


def test_settings_frame_rejects_wrong_type_or_stream() raises:
    var wrong_type = _frame(1, 0, 0, List[Byte]())
    assert_true(
        parse_settings_frame(
            parse_frame(Span(wrong_type)), Span(wrong_type)[9:]
        ).is_error()
    )

    var wrong_stream = _frame(4, 0, 1, List[Byte]())
    assert_true(
        parse_settings_frame(
            parse_frame(Span(wrong_stream)), Span(wrong_stream)[9:]
        ).is_error()
    )


def test_settings_frame_rejects_payload_on_ack() raises:
    var payload = List[Byte]()
    payload.append(Byte(0))
    var wire = _frame(4, 1, 0, payload)
    assert_true(
        parse_settings_frame(parse_frame(Span(wire)), Span(wire)[9:]).is_error()
    )


def test_settings_frame_rejects_partial_setting_entry() raises:
    var payload = List[Byte]()
    for _ in range(5):
        payload.append(Byte(0))
    var wire = _frame(4, 0, 0, payload)
    assert_true(
        parse_settings_frame(parse_frame(Span(wire)), Span(wire)[9:]).is_error()
    )


def test_settings_frame_rejects_payload_length_mismatch() raises:
    var wire = _frame(4, 0, 0, List[Byte]())
    var fake = parse_frame(Span(wire))
    fake.payload_length = 6
    var payload = List[Byte]()
    assert_true(parse_settings_frame(fake, Span(payload)).is_error())


def test_http2_bootstrap_waits_for_full_preface_before_server_settings() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface[0:10]).is_need_more())
    assert_true(bootstrap.server_settings().is_error())

    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    var server_settings = bootstrap.server_settings()
    assert_true(server_settings.is_complete())
    var server_frame = parse_frame(Span(server_settings.wire))
    assert_true(server_frame.is_complete())
    assert_equal(server_frame.frame_type, Byte(4))
    assert_equal(server_frame.flags, Byte(0))
    assert_equal(server_frame.stream_id, UInt32(0))
    assert_equal(server_frame.payload_length, 0)
    assert_true(bootstrap.server_settings().is_error())


def test_http2_bootstrap_acknowledges_initial_client_settings() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(1), Byte(0), Byte(0), Byte(0), Byte(128)]:
        payload.append(byte)
    for byte in [Byte(0), Byte(2), Byte(0), Byte(0), Byte(0), Byte(1)]:
        payload.append(byte)
    for byte in [Byte(0), Byte(5), Byte(0), Byte(0), Byte(128), Byte(0)]:
        payload.append(byte)
    var client_wire = _frame(4, 0, 0, payload)
    var ack = bootstrap.accept_client_settings(
        parse_frame(Span(client_wire)), Span(client_wire)[9:]
    )
    assert_true(ack.is_complete())
    assert_true(bootstrap.is_ready())
    var ack_frame = parse_frame(Span(ack.wire))
    assert_equal(ack_frame.frame_type, Byte(4))
    assert_equal(ack_frame.flags, Byte(1))
    assert_equal(ack_frame.stream_id, UInt32(0))
    assert_equal(ack_frame.payload_length, 0)
    assert_equal(bootstrap.peer_settings.max_frame_size, UInt32(32768))


def test_http2_bootstrap_applies_and_acknowledges_followup_settings() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var initial_wire = _frame(4, 0, 0, List[Byte]())
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(initial_wire)), Span(initial_wire)[9:]
        ).is_complete()
    )

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(3), Byte(0), Byte(0), Byte(0), Byte(5)]:
        payload.append(byte)
    for byte in [Byte(0), Byte(3), Byte(0), Byte(0), Byte(0), Byte(10)]:
        payload.append(byte)
    var followup_wire = _frame(4, 0, 0, payload)
    var ack = bootstrap.accept_client_settings(
        parse_frame(Span(followup_wire)), Span(followup_wire)[9:]
    )
    assert_true(ack.is_complete())
    assert_true(bootstrap.is_ready())
    assert_equal(bootstrap.peer_settings.max_concurrent_streams, UInt32(10))
    assert_equal(parse_frame(Span(ack.wire)).flags, Byte(1))


def test_http2_bootstrap_accepts_ack_for_server_settings() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var client_wire = _frame(4, 0, 0, List[Byte]())
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_complete()
    )
    assert_false(bootstrap.is_server_settings_acknowledged())

    var ack_wire = _frame(4, 1, 0, List[Byte]())
    assert_true(
        bootstrap.accept_server_settings_ack(
            parse_frame(Span(ack_wire)), Span(ack_wire)[9:]
        )
    )
    assert_true(bootstrap.is_server_settings_acknowledged())
    assert_true(bootstrap.is_ready())


def test_http2_bootstrap_rejects_invalid_followup_settings() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var initial_wire = _frame(4, 0, 0, List[Byte]())
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(initial_wire)), Span(initial_wire)[9:]
        ).is_complete()
    )

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(4), Byte(128), Byte(0), Byte(0), Byte(0)]:
        payload.append(byte)
    var followup_wire = _frame(4, 0, 0, payload)
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(followup_wire)), Span(followup_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())
    assert_false(bootstrap.is_ready())


def test_http2_bootstrap_rejects_invalid_client_setting_value() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(4), Byte(128), Byte(0), Byte(0), Byte(0)]:
        payload.append(byte)
    var client_wire = _frame(4, 0, 0, payload)
    var rejected = bootstrap.accept_initial_client_settings(
        parse_frame(Span(client_wire)), Span(client_wire)[9:]
    )
    assert_true(rejected.is_error())
    assert_equal(rejected.error_code, UInt32(3))
    assert_true(bootstrap.is_failed())
    assert_equal(bootstrap.connection_error_code(), UInt32(3))


def test_http2_bootstrap_rejects_invalid_max_frame_size() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(5), Byte(0), Byte(0), Byte(0), Byte(0)]:
        payload.append(byte)
    var client_wire = _frame(4, 0, 0, payload)
    var rejected = bootstrap.accept_initial_client_settings(
        parse_frame(Span(client_wire)), Span(client_wire)[9:]
    )
    assert_true(rejected.is_error())
    assert_equal(rejected.error_code, UInt32(1))
    assert_true(bootstrap.is_failed())
    assert_true(not bootstrap.is_ready())
    assert_equal(bootstrap.connection_error_code(), UInt32(1))


def test_http2_bootstrap_rejects_oversized_initial_window() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(4), Byte(128), Byte(0), Byte(0), Byte(0)]:
        payload.append(byte)
    var client_wire = _frame(4, 0, 0, payload)
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())
    assert_true(not bootstrap.is_ready())
    assert_equal(bootstrap.connection_error_code(), UInt32(3))

def test_http2_bootstrap_rejects_partial_settings_with_frame_size_error() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(1), Byte(0), Byte(0), Byte(0)]:
        payload.append(byte)
    var client_wire = _frame(4, 0, 0, payload)
    assert_true(
        bootstrap.accept_initial_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())
    assert_equal(bootstrap.connection_error_code(), UInt32(6))


def test_http2_bootstrap_rejects_oversized_settings_with_frame_size_error(
) raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    var client_wire = _frame(4, 0, 0, payload)
    client_wire[0] = Byte(0)
    client_wire[1] = Byte(0x40)
    client_wire[2] = Byte(1)
    assert_true(
        bootstrap.accept_initial_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())
    assert_equal(bootstrap.connection_error_code(), UInt32(6))


def test_http2_bootstrap_rejects_nonempty_ack_with_frame_size_error() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var payload = List[Byte]()
    for byte in [Byte(0), Byte(1), Byte(0), Byte(0), Byte(0), Byte(1)]:
        payload.append(byte)
    var client_wire = _frame(4, 1, 0, payload)
    assert_true(
        bootstrap.accept_initial_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())
    assert_equal(bootstrap.connection_error_code(), UInt32(6))


def test_http2_bootstrap_rejects_initial_settings_ack() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    assert_true(bootstrap.server_settings().is_complete())

    var client_wire = _frame(4, 1, 0, List[Byte]())
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())


def test_http2_bootstrap_requires_server_settings_before_client_settings() raises:
    var bootstrap = Http2ServerBootstrap()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    assert_true(bootstrap.consume_client_preface(preface).is_complete())
    var client_wire = _frame(4, 0, 0, List[Byte]())
    assert_true(
        bootstrap.accept_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())


def test_http2_bootstrap_fails_on_invalid_client_preface() raises:
    var bootstrap = Http2ServerBootstrap()
    assert_true(
        bootstrap.consume_client_preface(
            "XRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
        ).is_error()
    )
    assert_true(bootstrap.is_failed())


def test_http2_stream_remote_trailers_and_local_response_close() raises:
    var stream = Http2StreamState()
    assert_true(stream.receive_headers(False))
    assert_true(stream.receive_data(False))
    assert_true(stream.receive_headers(True))
    assert_true(stream.is_remote_closed())
    assert_true(stream.send_headers(False))
    assert_true(stream.send_data(True))
    assert_true(stream.is_local_closed())
    assert_true(stream.is_closed())


def test_http2_stream_early_response_allows_remote_body_to_finish() raises:
    var stream = Http2StreamState()
    assert_true(stream.receive_headers(False))
    assert_true(stream.send_headers(True))
    assert_true(stream.is_local_closed())
    assert_true(stream.receive_data(True))
    assert_true(stream.is_remote_closed())
    assert_true(stream.is_closed())


def test_http2_stream_rejects_invalid_data_and_trailer_order() raises:
    var stream = Http2StreamState()
    assert_false(stream.receive_data(False))
    assert_false(stream.send_data(False))
    assert_true(stream.receive_headers(False))
    assert_false(stream.receive_headers(False))
    assert_true(stream.receive_headers(True))
    assert_false(stream.receive_data(False))


def test_http2_stream_reset_closes_active_stream() raises:
    var idle = Http2StreamState()
    assert_false(idle.reset())

    var active = Http2StreamState()
    assert_true(active.receive_headers(False))
    assert_true(active.reset())
    assert_true(active.is_closed())
    assert_false(active.receive_data(False))
    assert_false(active.reset())


def test_http2_stream_table_enforces_local_limit_and_half_close_count() raises:
    var streams = Http2ActiveStreams(UInt32(1))
    assert_true(streams.receive_headers(UInt32(1), False).is_accepted())
    assert_equal(streams.active_count(), 1)
    assert_true(streams.receive_headers(UInt32(3), False).is_refused())
    assert_equal(streams.active_count(), 1)

    assert_true(streams.receive_headers(UInt32(1), True).is_accepted())
    assert_equal(streams.active_count(), 1)
    assert_true(streams.send_headers(UInt32(1), True))
    assert_equal(streams.active_count(), 0)
    assert_true(streams.receive_headers(UInt32(5), False).is_accepted())
    assert_equal(streams.active_count(), 1)


def test_http2_stream_table_releases_capacity_after_reset() raises:
    var streams = Http2ActiveStreams(UInt32(1))
    assert_true(streams.receive_headers(UInt32(1), False).is_accepted())
    assert_true(streams.reset(UInt32(1)))
    assert_equal(streams.active_count(), 0)
    assert_true(streams.receive_headers(UInt32(3), False).is_accepted())


def test_http2_stream_table_rejects_invalid_or_reused_ids() raises:
    var streams = Http2ActiveStreams(UInt32(2))
    assert_true(streams.receive_headers(UInt32(0), False).is_error())
    assert_true(streams.receive_headers(UInt32(2), False).is_error())
    assert_true(streams.receive_headers(UInt32(0x80000001), False).is_error())
    assert_true(streams.receive_headers(UInt32(3), False).is_accepted())
    assert_true(streams.reset(UInt32(3)))
    assert_true(streams.receive_headers(UInt32(3), False).is_error())
    assert_true(streams.receive_headers(UInt32(1), False).is_error())


def test_http2_stream_table_releases_capacity_after_remote_data_end() raises:
    var streams = Http2ActiveStreams(UInt32(1))
    assert_true(streams.receive_headers(UInt32(1), False).is_accepted())
    assert_true(streams.send_headers(UInt32(1), True))
    assert_equal(streams.active_count(), 1)
    assert_true(streams.receive_data(UInt32(1), True))
    assert_equal(streams.active_count(), 0)
    assert_true(streams.receive_headers(UInt32(3), False).is_accepted())


def test_http2_stream_table_zero_limit_still_consumes_stream_id() raises:
    var streams = Http2ActiveStreams(UInt32(0))
    assert_true(streams.receive_headers(UInt32(1), False).is_refused())
    assert_true(streams.receive_headers(UInt32(1), False).is_error())
    assert_true(streams.receive_headers(UInt32(3), False).is_refused())


def test_http2_peer_stream_limit_does_not_set_local_admission_limit() raises:
    var peer_settings = Http2PeerSettings()
    var setting_values = List[Setting]()
    setting_values.append(Setting(identifier=UInt16(3), value=UInt32(0)))
    assert_true(peer_settings.apply(Span(setting_values)).is_success())
    assert_equal(peer_settings.max_concurrent_streams, UInt32(0))

    var streams = Http2ActiveStreams(UInt32(1))
    assert_true(streams.receive_headers(UInt32(1), False).is_accepted())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
