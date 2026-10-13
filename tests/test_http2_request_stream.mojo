from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.http._body_pipe import _BodyPipe
from net.http._buffer import SharedBufferBudget
from net.http._http2.data_frame import parse_data_frame
from net.http._http2.frame import FrameParseResult
from net.http._http2.request_stream import Http2RequestStream
from tests.support import _append_hpack_field


def _head(length: Int = -1) raises -> List[Byte]:
    var head = List[Byte]()
    _append_hpack_field(head, String(":method"), String("POST"))
    _append_hpack_field(head, String(":scheme"), String("https"))
    _append_hpack_field(head, String(":authority"), String("example.com"))
    _append_hpack_field(head, String(":path"), String("/upload"))
    if length >= 0:
        _append_hpack_field(head, String("content-length"), String(length))
    return head^


def test_receive_window_storage_survives_partial_and_empty_consumption() raises:
    var budget = SharedBufferBudget(8)
    var pipe = _BodyPipe(8, budget.copy(), reserve_capacity=True)
    assert_equal(budget.used(), 8)
    assert_true(pipe.push(String("abcdefgh").as_bytes()))
    var buffer = Array[Byte, 2](fill=0)
    assert_equal(pipe.pop(Span(buffer)), 2)
    assert_equal(pipe.writable_bytes(), 2)
    assert_true(pipe.push(String("ij").as_bytes()))
    var all = Array[Byte, 8](fill=0)
    assert_equal(pipe.pop(Span(all)), 8)
    assert_equal(String(from_utf8_lossy=Span(all)), "cdefghij")
    assert_equal(budget.used(), 8)
    assert_true(pipe.push(String("next").as_bytes()))
    pipe.push_eof()
    assert_equal(pipe.pop(Span(all)), 4)
    assert_equal(budget.used(), 0)
    assert_true(pipe.is_eof())


def test_receive_window_admission_is_budgeted_and_cancellation_refunds() raises:
    var budget = SharedBufferBudget(7)
    var rejected = False
    try:
        _ = _BodyPipe(8, budget.copy(), reserve_capacity=True)
    except:
        rejected = True
    assert_true(rejected)
    assert_equal(budget.used(), 0)
    var pipe = _BodyPipe(7, budget.copy(), reserve_capacity=True)
    assert_equal(budget.used(), 7)
    pipe.cancel()
    assert_equal(budget.used(), 0)


def test_stream_head_precedes_large_body_and_dispatches_once() raises:
    var budget = SharedBufferBudget(64)
    var pipe = _BodyPipe(4, budget.copy(), reserve_capacity=True)
    var stream = Http2RequestStream(4, Optional(pipe.copy()))
    var head = _head(8)
    assert_true(stream.receive_headers(Span(head), 5, False).is_pending())
    assert_true(stream.head_ready())
    var request = stream.take_head()
    assert_equal(request.path, "/upload")
    assert_false(stream.head_ready())
    var reader = request.body_reader()
    assert_true(reader.is_streaming())
    var first = String("abcd")
    var frame = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 4)
    assert_true(
        stream.receive_data(
            parse_data_frame(frame, first.as_bytes()), first.as_bytes()
        ).is_pending()
    )
    var buffer = Array[Byte, 4](fill=0)
    assert_equal(reader.read(Span(buffer)), 4)
    assert_equal(pipe.take_consumed(), 4)
    var last = String("efgh")
    frame = FrameParseResult.complete(Byte(0), Byte(1), UInt32(1), 4)
    assert_true(
        stream.receive_data(
            parse_data_frame(frame, last.as_bytes()), last.as_bytes()
        ).is_complete()
    )
    assert_equal(reader.read(Span(buffer)), 4)
    assert_equal(String(from_utf8_lossy=Span(buffer)), "efgh")
    assert_equal(reader.read(Span(buffer)), 0)
    assert_equal(reader.total_decoded(), 8)
    assert_false(stream.head_ready())
    _ = stream^
    assert_equal(budget.used(), 0)


def test_streamed_content_length_mismatch_cancels_owned_reader() raises:
    var budget = SharedBufferBudget(64)
    var pipe = _BodyPipe(8, budget.copy(), reserve_capacity=True)
    var stream = Http2RequestStream(8, Optional(pipe.copy()))
    var head = _head(3)
    assert_true(stream.receive_headers(Span(head), 5, False).is_pending())
    var request = stream.take_head()
    var reader = request.body_reader()
    var frame = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 4)
    var data = String("body")
    assert_true(
        stream.receive_data(
            parse_data_frame(frame, data.as_bytes()), data.as_bytes()
        ).is_malformed()
    )
    assert_true(pipe.is_cancelled())
    assert_equal(pipe.total_decoded(), 0)
    assert_equal(budget.used(), 0)
    _ = reader.detach()


def test_streamed_trailers_are_available_after_consumed_eof() raises:
    var budget = SharedBufferBudget(4096)
    var pipe = _BodyPipe(4, budget.copy(), reserve_capacity=True)
    var stream = Http2RequestStream(4, Optional(pipe.copy()))
    var head = _head(4)
    assert_true(stream.receive_headers(Span(head), 5, False).is_pending())
    var request = stream.take_head()
    var reader = request.body_reader()
    var frame = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 4)
    var data = String("body")
    assert_true(
        stream.receive_data(
            parse_data_frame(frame, data.as_bytes()), data.as_bytes()
        ).is_pending()
    )
    var trailers = List[Byte]()
    _append_hpack_field(trailers, String("x-end"), String("done"))
    assert_true(stream.receive_headers(Span(trailers), 1, True).is_complete())
    var buffer = Array[Byte, 4](fill=0)
    assert_equal(reader.read(Span(buffer)), 4)
    assert_equal(reader.read(Span(buffer)), 0)
    var final_trailers = reader.trailers()
    assert_equal(final_trailers.get_first("x-end").value(), "done")
    _ = stream^


def test_empty_stream_head_has_eof_and_refunds_reserved_window() raises:
    var budget = SharedBufferBudget(8)
    var pipe = _BodyPipe(8, budget.copy(), reserve_capacity=True)
    var stream = Http2RequestStream(8, Optional(pipe.copy()))
    var head = _head(0)
    assert_true(stream.receive_headers(Span(head), 5, True).is_complete())
    assert_true(stream.head_ready())
    var request = stream.take_head()
    var reader = request.body_reader()
    assert_true(reader.is_eof())
    assert_equal(budget.used(), 0)


def test_completed_body_outlives_its_protocol_stream() raises:
    var budget = SharedBufferBudget(64)
    var pipe = _BodyPipe(4, budget.copy(), reserve_capacity=True)
    var stream = Http2RequestStream(4, Optional(pipe.copy()))
    var head = _head(4)
    assert_true(stream.receive_headers(Span(head), 5, False).is_pending())
    var request = stream.take_head()
    var frame = FrameParseResult.complete(Byte(0), Byte(1), UInt32(1), 4)
    var data = String("body")
    assert_true(
        stream.receive_data(
            parse_data_frame(frame, data.as_bytes()), data.as_bytes()
        ).is_complete()
    )
    _ = stream^
    assert_false(pipe.is_cancelled())
    var reader = request.body_reader()
    var buffer = Array[Byte, 4](fill=0)
    assert_equal(reader.read(Span(buffer)), 4)
    assert_equal(String(from_utf8_lossy=Span(buffer)), "body")
    assert_equal(reader.read(Span(buffer)), 0)


def _terminal_trailers_release_or_cancel(
    budget_size: Int, oversized: Bool
) raises:
    var budget = SharedBufferBudget(budget_size)
    var pipe = _BodyPipe(budget_size, budget.copy(), reserve_capacity=True)
    var stream = Http2RequestStream(budget_size, Optional(pipe.copy()))
    var head = _head(4)
    assert_true(stream.receive_headers(Span(head), 5, False).is_pending())
    var request = stream.take_head()
    var reader = request.body_reader()
    var data = String("body")
    var frame = FrameParseResult.complete(Byte(0), Byte(0), UInt32(1), 4)
    assert_true(
        stream.receive_data(
            parse_data_frame(frame, data.as_bytes()), data.as_bytes()
        ).is_pending()
    )
    var buffer = Array[Byte, 4](fill=0)
    assert_equal(reader.read(Span(buffer)), 4)
    var trailers = List[Byte]()
    _append_hpack_field(trailers, String("x-end"), String("done"))
    if oversized:
        try:
            _ = stream.receive_headers(Span(trailers), 1, True)
        except:
            pass
        assert_true(pipe.is_cancelled())
        assert_false(stream.is_complete())
    else:
        assert_true(
            stream.receive_headers(Span(trailers), 1, True).is_complete()
        )
        assert_true(reader.is_eof())
        assert_equal(reader.trailers().get_first("x-end").value(), "done")


def test_terminal_trailers_reclaim_empty_reserved_window() raises:
    _terminal_trailers_release_or_cancel(1024, False)


def test_oversized_terminal_trailers_cancel_owned_reader() raises:
    _terminal_trailers_release_or_cancel(4, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
