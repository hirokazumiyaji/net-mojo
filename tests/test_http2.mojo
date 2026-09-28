from std.testing import assert_equal, assert_false, assert_true, TestSuite
from net.http.request import HttpVersion

from net.http._http2.frame import FrameParseResult, parse_frame
from net.http._http2.frame_encoder import encode_frame
from net.http._http2.response_frames import (
    encode_data_frames,
    encode_headers_block,
)
from net.http._http2.data_frame import parse_data_frame
from net.http._http2.request_body import Http2RequestBody
from net.http._http2.request_stream import Http2RequestStream
from net.http._http2.response_headers import encode_http2_response_headers
from net.http.response import ResponseWriter
from net.http._http2.bootstrap import Http2ServerBootstrap
from net.http._http2.connection_bootstrap import Http2ConnectionBootstrap
from net.http._http2.frame_dispatcher import Http2FrameDispatcher
from net.http._http2.frame_reader import Http2FrameReader
from net.http._http2.settings_state import (
    Http2PeerSettings,
    Http2PeerSettingsSnapshot,
)
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
from net.http._http2.request_headers import (
    decode_http2_request_headers,
    decode_http2_trailers,
)


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


def test_http2_data_frame_extracts_payload_and_end_stream() raises:
    var payload: List[Byte] = [Byte(10), Byte(11), Byte(12)]
    var frame = FrameParseResult.complete(Byte(0), Byte(1), UInt32(1), 3)
    var parsed = parse_data_frame(frame, Span(payload))
    assert_true(parsed.is_valid())
    assert_equal(parsed.data_offset, 0)
    assert_equal(parsed.data_length, 3)
    assert_true(parsed.end_stream)

    var padded_payload: List[Byte] = [Byte(2), Byte(10), Byte(11), Byte(0), Byte(0)]
    var padded = FrameParseResult.complete(Byte(0), Byte(9), UInt32(1), 5)
    parsed = parse_data_frame(padded, Span(padded_payload))
    assert_true(parsed.is_valid())
    assert_equal(parsed.data_offset, 1)
    assert_equal(parsed.data_length, 2)
    assert_true(parsed.end_stream)


def test_http2_data_frame_rejects_invalid_padding_and_shape() raises:
    var empty: List[Byte] = []
    var padded_empty = FrameParseResult.complete(Byte(0), Byte(8), UInt32(1), 0)
    assert_true(parse_data_frame(padded_empty, Span(empty)).is_error())

    var invalid_padding_payload: List[Byte] = [Byte(3), Byte(10)]
    var invalid_padding = FrameParseResult.complete(
        Byte(0), Byte(8), UInt32(1), 2
    )
    assert_true(
        parse_data_frame(invalid_padding, Span(invalid_padding_payload)).is_error()
    )

    var payload: List[Byte] = [Byte(1)]
    var connection = FrameParseResult.complete(Byte(0), Byte(0), UInt32(0), 1)
    assert_true(parse_data_frame(connection, Span(payload)).is_error())
    var mismatched = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 2)
    assert_true(parse_data_frame(mismatched, Span(payload)).is_error())


def test_http2_request_body_collects_data_until_end_stream() raises:
    var body = Http2RequestBody(4)
    var first_payload: List[Byte] = [Byte(1), Byte(2)]
    var first_frame = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 2)
    var first_data = parse_data_frame(first_frame, Span(first_payload))
    assert_true(body.append_data(first_data, Span(first_payload)).is_accepted())
    assert_false(body.is_complete())

    var final_payload: List[Byte] = [Byte(1), Byte(3), Byte(4), Byte(0)]
    var final_frame = FrameParseResult.complete(Byte(0), Byte(9), UInt32(1), 4)
    var final_data = parse_data_frame(final_frame, Span(final_payload))
    assert_true(body.append_data(final_data, Span(final_payload)).is_accepted())
    assert_true(body.is_complete())
    var collected = body.bytes()
    assert_equal(len(collected), 4)
    assert_equal(collected[0], Byte(1))
    assert_equal(collected[1], Byte(2))
    assert_equal(collected[2], Byte(3))
    assert_equal(collected[3], Byte(4))


def test_http2_request_body_enforces_limit_and_completion() raises:
    var body = Http2RequestBody(1)
    var oversized_payload: List[Byte] = [Byte(1), Byte(2)]
    var oversized_frame = FrameParseResult.complete(
        Byte(0), Byte(1), UInt32(1), 2
    )
    var oversized = parse_data_frame(oversized_frame, Span(oversized_payload))
    assert_true(body.append_data(oversized, Span(oversized_payload)).is_too_large())

    var complete = Http2RequestBody(1)
    var payload: List[Byte] = [Byte(9)]
    var frame = FrameParseResult.complete(Byte(0), Byte(1), UInt32(1), 1)
    var data = parse_data_frame(frame, Span(payload))
    assert_true(complete.append_data(data, Span(payload)).is_accepted())
    assert_true(complete.append_data(data, Span(payload)).is_invalid_state())


def test_http2_response_headers_map_shared_response() raises:
    var writer = ResponseWriter(16)
    writer.set_status(201)
    writer.headers.add("X-Trace", "abc")
    writer.write_string("hello")
    var encoded = encode_http2_response_headers(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 1024, 8
    )
    assert_true(encoded.is_valid())
    assert_true(encoded.send_body)
    assert_equal(encoded.field_count, 4)
    var status_name = String(from_utf8_lossy=Span(encoded.fields)[8:15])
    var status_value = String(from_utf8_lossy=Span(encoded.fields)[15:18])
    assert_equal(status_name, ":status")
    assert_equal(status_value, "201")


def test_http2_response_headers_reject_forbidden_and_mismatched_fields() raises:
    var connection = ResponseWriter(16)
    connection.headers.add("Connection", "close")
    assert_true(
        encode_http2_response_headers(connection, False, "date", 1024, 8)
        .is_error()
    )

    var mismatch = ResponseWriter(16)
    mismatch.headers.add("Content-Length", "3")
    mismatch.write_string("hello")
    assert_true(
        encode_http2_response_headers(mismatch, False, "date", 1024, 8)
        .is_error()
    )

    var invalid_status = ResponseWriter(16)
    invalid_status.set_status(101)
    assert_true(
        encode_http2_response_headers(invalid_status, False, "date", 1024, 8)
        .is_error()
    )


def test_http2_response_headers_keep_head_length_and_drop_no_body_length() raises:
    var head = ResponseWriter(16)
    head.write_string("hello")
    var head_fields = encode_http2_response_headers(
        head, True, "date", 1024, 8
    )
    assert_true(head_fields.is_valid())
    assert_false(head_fields.send_body)
    assert_equal(head_fields.field_count, 3)

    var no_content = ResponseWriter(16)
    no_content.set_status(204)
    no_content.headers.add("Content-Length", "5")
    no_content.write_string("hello")
    var no_content_fields = encode_http2_response_headers(
        no_content, False, "date", 1024, 8
    )
    assert_true(no_content_fields.is_valid())
    assert_false(no_content_fields.send_body)
    assert_equal(no_content_fields.field_count, 2)


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



def test_http2_dispatcher_acknowledges_ping_and_rejects_interleaving() raises:
    var dispatcher = Http2FrameDispatcher(Http2PeerSettings().snapshot())
    var payload: List[Byte] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8)]
    var ping = FrameParseResult.complete(Byte(6), Byte(0), UInt32(0), 8)
    var result = dispatcher.accept(ping, Span(payload))
    assert_true(result.is_output())
    assert_equal(result.output[4], Byte(1))
    assert_equal(result.output[16], Byte(8))

    var headers = FrameParseResult.complete(Byte(1), Byte(0), UInt32(3), 1)
    var empty: List[Byte] = [Byte(0)]
    result = dispatcher.accept(headers, Span(empty))
    assert_true(result.is_ignored())
    result = dispatcher.accept(ping, Span(payload))
    assert_true(result.is_error())


def test_http2_dispatcher_applies_peer_settings_and_emits_ack() raises:
    var initial = Http2PeerSettingsSnapshot(
        header_table_size=UInt32(128),
        max_concurrent_streams=UInt32(64),
        initial_window_size=UInt32(65535),
        max_frame_size=UInt32(16384),
        max_header_list_size=UInt32(4096),
    )
    var dispatcher = Http2FrameDispatcher(initial)
    var payload: List[Byte] = [Byte(0), Byte(5), Byte(0), Byte(0), Byte(128), Byte(0)]
    var frame = FrameParseResult.complete(Byte(4), Byte(0), UInt32(0), 6)
    var result = dispatcher.accept(frame, Span(payload))
    assert_true(result.is_output())
    assert_equal(result.output[4], Byte(1))
    var settings = dispatcher.peer_settings()
    assert_equal(settings.header_table_size, UInt32(128))
    assert_equal(settings.max_frame_size, UInt32(32768))


def test_http2_dispatcher_returns_window_reset_and_goaway_events() raises:
    var dispatcher = Http2FrameDispatcher(Http2PeerSettings().snapshot())
    var window_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(9)]
    var window = FrameParseResult.complete(Byte(8), Byte(0), UInt32(3), 4)
    var result = dispatcher.accept(window, Span(window_payload))
    assert_true(result.is_window_update())
    assert_equal(result.stream_id, UInt32(3))
    assert_equal(result.value, UInt32(9))

    var reset_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(8)]
    var reset = FrameParseResult.complete(Byte(3), Byte(0), UInt32(3), 4)
    result = dispatcher.accept(reset, Span(reset_payload))
    assert_true(result.is_reset())
    assert_equal(result.stream_id, UInt32(3))
    assert_equal(result.value, UInt32(8))

    var goaway_payload: List[Byte] = [Byte(0), Byte(0), Byte(0), Byte(3), Byte(0), Byte(0), Byte(0), Byte(2)]
    var goaway = FrameParseResult.complete(Byte(7), Byte(0), UInt32(0), 8)
    result = dispatcher.accept(goaway, Span(goaway_payload))
    assert_true(result.is_goaway())
    assert_equal(result.stream_id, UInt32(3))
    assert_equal(result.value, UInt32(2))


def test_http2_frame_reader_retains_fragmented_frame_and_leaves_next() raises:
    var reader = Http2FrameReader(16384)
    var payload: List[Byte] = [Byte(4), Byte(3), Byte(2), Byte(1)]
    var first = _frame(8, 0, 3, payload)
    var partial = reader.consume(Span(first)[0:5])
    assert_true(partial.is_need_more())
    assert_equal(partial.consumed, 5)

    var trailing_payload: List[Byte] = [
        Byte(9), Byte(8), Byte(7), Byte(6), Byte(5), Byte(4), Byte(3), Byte(2)
    ]
    var trailing = _frame(6, 0, 0, trailing_payload)
    var combined = List[Byte]()
    for i in range(5, len(first)):
        combined.append(first[i])
    for i in range(len(trailing)):
        combined.append(trailing[i])
    var result = reader.consume(Span(combined))
    assert_true(result.is_frame())
    assert_equal(result.consumed, len(first) - 5)
    assert_equal(result.frame_type, Byte(8))
    assert_equal(result.stream_id, UInt32(3))
    assert_equal(result.payload[0], Byte(4))
    var next = reader.consume(Span(combined)[result.consumed:])
    assert_true(next.is_frame())
    assert_equal(next.frame_type, Byte(6))


def test_http2_frame_reader_rejects_oversized_length_from_header() raises:
    var reader = Http2FrameReader(16384)
    var oversized: List[Byte] = [
        Byte(0), Byte(0x40), Byte(1), Byte(0), Byte(0),
        Byte(0), Byte(0), Byte(0), Byte(1),
    ]
    var result = reader.consume(Span(oversized))
    assert_true(result.is_error())
    assert_equal(result.consumed, 9)

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


def test_http2_request_stream_combines_headers_body_and_trailers() raises:
    var stream = Http2RequestStream(8)
    var head = List[Byte]()
    _append_hpack_field(head, String(":method"), String("POST"))
    _append_hpack_field(head, String(":scheme"), String("https"))
    _append_hpack_field(head, String(":authority"), String("example.com"))
    _append_hpack_field(head, String(":path"), String("/upload"))
    var result = stream.receive_headers(Span(head), 4, False)
    assert_true(result.is_pending())

    var payload: List[Byte] = [Byte(1), Byte(2)]
    var data_frame = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 2)
    var data = parse_data_frame(data_frame, Span(payload))
    assert_true(stream.receive_data(data, Span(payload)).is_pending())

    var trailing_fields = List[Byte]()
    _append_hpack_field(trailing_fields, String("x-check"), String("done"))
    result = stream.receive_headers(Span(trailing_fields), 1, True)
    assert_true(result.is_complete())

    var request = stream^.take_request()
    assert_equal(request.method, "POST")
    assert_equal(len(request.body), 2)
    assert_equal(request.body[0], Byte(1))
    assert_equal(request.body[1], Byte(2))
    assert_equal(request.trailers.get_first("x-check"), Optional[String]("done"))


def test_http2_request_stream_reports_body_limit() raises:
    var stream = Http2RequestStream(1)
    var head = List[Byte]()
    _append_hpack_field(head, String(":method"), String("POST"))
    _append_hpack_field(head, String(":scheme"), String("https"))
    _append_hpack_field(head, String(":authority"), String("example.com"))
    _append_hpack_field(head, String(":path"), String("/upload"))
    assert_true(stream.receive_headers(Span(head), 4, False).is_pending())

    var payload: List[Byte] = [Byte(1), Byte(2)]
    var frame = FrameParseResult.complete(Byte(0), Byte(1), UInt32(1), 2)
    var data = parse_data_frame(frame, Span(payload))
    assert_true(stream.receive_data(data, Span(payload)).is_too_large())


def test_http2_trailers_preserve_regular_fields() raises:
    var encoded = List[Byte]()
    _append_hpack_field(encoded, String("grpc-status"), String("0"))
    _append_hpack_field(encoded, String("x-tag"), String("done"))
    var parsed = decode_http2_trailers(Span(encoded), 2)
    assert_true(parsed.is_valid())
    assert_equal(parsed.trailers.get_first("grpc-status"), Optional[String]("0"))
    assert_equal(parsed.trailers.get_first("x-tag"), Optional[String]("done"))


def test_http2_trailers_reject_pseudo_forbidden_and_truncated_fields() raises:
    var pseudo = List[Byte]()
    _append_hpack_field(pseudo, String(":method"), String("GET"))
    assert_true(decode_http2_trailers(Span(pseudo), 1).is_error())

    var framing = List[Byte]()
    _append_hpack_field(framing, String("content-length"), String("4"))
    assert_true(decode_http2_trailers(Span(framing), 1).is_error())

    var uppercase = List[Byte]()
    _append_hpack_field(uppercase, String("X-Tag"), String("value"))
    assert_true(decode_http2_trailers(Span(uppercase), 1).is_error())

    var truncated: List[Byte] = [Byte(0), Byte(0), Byte(0)]
    assert_true(decode_http2_trailers(Span(truncated), 1).is_error())


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


def test_http2_headers_block_fragments_with_continuation() raises:
    var block: List[Byte] = [
        Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7)
    ]
    var encoded = encode_headers_block(UInt32(1), Span(block), True, 3, 64)
    assert_true(encoded.is_complete())

    var offset = 0
    var first = parse_frame(Span(encoded.wire)[offset:], 3)
    assert_true(first.is_complete())
    assert_equal(first.frame_type, Byte(1))
    assert_equal(first.flags, Byte(1))
    assert_equal(first.stream_id, UInt32(1))
    offset += first.consumed

    var second = parse_frame(Span(encoded.wire)[offset:], 3)
    assert_true(second.is_complete())
    assert_equal(second.frame_type, Byte(9))
    assert_equal(second.flags, Byte(0))
    offset += second.consumed

    var final = parse_frame(Span(encoded.wire)[offset:], 3)
    assert_true(final.is_complete())
    assert_equal(final.frame_type, Byte(9))
    assert_equal(final.flags, Byte(4))
    assert_equal(final.payload_length, 1)
    assert_equal(offset + final.consumed, len(encoded.wire))


def test_http2_data_frames_fragment_and_end_stream() raises:
    var body: List[Byte] = [
        Byte(10), Byte(11), Byte(12), Byte(13), Byte(14), Byte(15), Byte(16)
    ]
    var encoded = encode_data_frames(UInt32(3), Span(body), True, 3, 64)
    assert_true(encoded.is_complete())
    var first = parse_frame(Span(encoded.wire), 3)
    assert_true(first.is_complete())
    assert_equal(first.frame_type, Byte(0))
    assert_equal(first.flags, Byte(0))
    var second = parse_frame(Span(encoded.wire)[first.consumed:], 3)
    assert_true(second.is_complete())
    assert_equal(second.flags, Byte(0))
    var final = parse_frame(
        Span(encoded.wire)[first.consumed + second.consumed :], 3
    )
    assert_true(final.is_complete())
    assert_equal(final.flags, Byte(1))
    assert_equal(final.payload_length, 1)

    var empty: List[Byte] = []
    var end = encode_data_frames(UInt32(3), Span(empty), True, 3, 9)
    assert_true(end.is_complete())
    var empty_frame = parse_frame(Span(end.wire), 3)
    assert_true(empty_frame.is_complete())
    assert_equal(empty_frame.payload_length, 0)
    assert_equal(empty_frame.flags, Byte(1))

    assert_true(
        encode_data_frames(UInt32(3), Span(body), True, 3, 8).is_error()
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
        bootstrap.accept_client_settings(
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
        bootstrap.accept_client_settings(
            parse_frame(Span(client_wire)), Span(client_wire)[9:]
        ).is_error()
    )
    assert_true(bootstrap.is_failed())
    assert_equal(bootstrap.connection_error_code(), UInt32(6))


def test_http2_connection_bootstrap_handles_fragmented_preface_and_settings() raises:
    var input = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        input.append(preface[i])
    var settings_payload: List[Byte] = [
        Byte(0), Byte(1), Byte(0), Byte(0), Byte(0), Byte(128),
        Byte(0), Byte(5), Byte(0), Byte(0), Byte(0x80), Byte(0),
    ]
    var client_settings = _frame(4, 0, 0, settings_payload)
    for i in range(len(client_settings)):
        input.append(client_settings[i])
    var ping_payload: List[Byte] = [
        Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8)
    ]
    var ping = _frame(6, 0, 0, ping_payload)
    for i in range(len(ping)):
        input.append(ping[i])

    var bootstrap = Http2ConnectionBootstrap()
    var result = bootstrap.consume(Span(input))
    assert_true(result.is_ready())
    assert_equal(result.consumed, 24 + len(client_settings))
    assert_equal(len(result.output), 18)
    var server_settings = parse_frame(Span(result.output))
    assert_true(server_settings.is_complete())
    assert_equal(server_settings.frame_type, Byte(4))
    assert_equal(server_settings.flags, Byte(0))
    var settings_ack = parse_frame(Span(result.output)[server_settings.consumed:])
    assert_true(settings_ack.is_complete())
    assert_equal(settings_ack.frame_type, Byte(4))
    assert_equal(settings_ack.flags, Byte(1))
    var peer_settings = bootstrap.peer_settings()
    assert_equal(peer_settings.header_table_size, UInt32(128))
    assert_equal(peer_settings.max_frame_size, UInt32(32768))

    var remainder = parse_frame(Span(input)[result.consumed:])
    assert_true(remainder.is_complete())
    assert_equal(remainder.frame_type, Byte(6))

    var bytewise = Http2ConnectionBootstrap()
    var output = List[Byte]()
    var ready = False
    for i in range(len(input)):
        var part = bytewise.consume(Span(input)[i : i + 1])
        assert_false(part.is_error())
        for j in range(len(part.output)):
            output.append(part.output[j])
        if part.is_ready():
            ready = True
            break
    assert_true(ready)
    assert_equal(len(output), 18)


def test_http2_connection_bootstrap_rejects_bad_preface_and_initial_ack() raises:
    var bad_preface = Http2ConnectionBootstrap()
    var bad = bad_preface.consume("X".as_bytes())
    assert_true(bad.is_error())
    assert_true(bad_preface.is_failed())

    var input = List[Byte]()
    var preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    for i in range(len(preface)):
        input.append(preface[i])
    var ack = _frame(4, 1, 0, List[Byte]())
    for i in range(len(ack)):
        input.append(ack[i])
    var bootstrap = Http2ConnectionBootstrap()
    var result = bootstrap.consume(Span(input))
    assert_true(result.is_error())
    assert_true(bootstrap.is_failed())

    var oversized_input = List[Byte]()
    for i in range(len(preface)):
        oversized_input.append(preface[i])
    for byte in [
        Byte(0), Byte(0x40), Byte(1), Byte(4), Byte(0), Byte(0), Byte(0),
        Byte(0), Byte(0),
    ]:
        oversized_input.append(byte)
    var oversized_bootstrap = Http2ConnectionBootstrap()
    assert_true(oversized_bootstrap.consume(Span(oversized_input)).is_error())



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
