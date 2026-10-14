from std.sys import size_of
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)
from net.http import (
    CompressionConfig,
    CompressingSender,
    Headers,
    HttpVersion,
    Request,
    ResponseWriter,
)
from net.http._buffer import SharedBufferBudget
from net.http._detach import (
    _detach_state,
    _take_batch,
    _consume_detach_bytes,
    _cancel_detach_state,
    _DetachTarget,
    MSG_KIND_CHUNK,
    MSG_KIND_START,
    MSG_KIND_FINISH,
    MSG_KIND_ABORT,
    _SharedDetachState,
)


def _request(method: StringSlice = "GET") raises -> Request:
    var req = Request(String(method), "/", "/", "", HttpVersion.http11())
    req.headers.add("Accept-Encoding", "gzip")
    return req^


def _config(buffer_size: Int = 32) -> CompressionConfig:
    var cfg = CompressionConfig.default()
    cfg.buffer_size = buffer_size
    return cfg^


def _collect(addr: Int, mut output: List[Byte]) -> UInt8:
    var batch = _take_batch(_detach_state(addr))
    for i in range(len(batch.messages)):
        if batch.messages[i].kind == MSG_KIND_CHUNK:
            output.extend(Span(batch.messages[i].body))
            _consume_detach_bytes(addr, len(batch.messages[i].body))
    return batch.terminal_kind


def test_unknown_length_stream_compresses_below_minimum() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(initial.messages[0].kind, MSG_KIND_START)
    assert_equal(
        initial.messages[0].headers.get_first("Content-Encoding").value(),
        "gzip",
    )
    assert_true(sender.send("tiny".as_bytes()))
    assert_true(sender.finish())
    var bytes = List[Byte]()
    assert_equal(_collect(writer._detach_state_addr, bytes), MSG_KIND_FINISH)
    assert_equal(bytes[0], Byte(0x1F))
    assert_equal(bytes[1], Byte(0x8B))
    assert_true(len(bytes) > 4)


def test_absent_provider_stream_preserves_headers_and_bytes() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(req, _config(), None)
    var headers = Headers()
    headers.add("Vary", "Origin")
    sender.start(200, headers^)
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(initial.messages[0].headers.count("Content-Encoding"), 0)
    assert_equal(initial.messages[0].headers.count("Vary"), 1)
    assert_true(sender.send("tiny".as_bytes()))
    assert_true(sender.finish())
    var bytes = List[Byte]()
    _ = _collect(writer._detach_state_addr, bytes)
    assert_equal(len(bytes), 4)
    assert_equal(bytes[0], Byte(ord("t")))


def test_known_source_length_is_removed_and_validated() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var cfg = _config()
    cfg.min_size = 0
    var sender = writer.detach_compressed(
        req, cfg^, Optional[String]("build/compression/libnet_zlib")
    )
    var headers = Headers()
    headers.add("Content-Length", "4")
    headers.add("ETag", '"source"')
    sender.start(200, headers^)
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(initial.messages[0].headers.count("Content-Length"), 0)
    assert_equal(
        initial.messages[0].headers.get_first("ETag").value(), 'W/"source"'
    )
    assert_true(sender.send("abc".as_bytes()))
    with assert_raises():
        _ = sender.finish()
    assert_equal(
        _detach_state(writer._detach_state_addr)[].terminal_kind, MSG_KIND_ABORT
    )


def test_footer_retry_keeps_trailers_and_bounded_pending_bytes() raises:
    var req = _request()
    var writer = ResponseWriter(64, queue_limit=2)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(8), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    assert_true(sender.send("tiny".as_bytes()))
    var trailers = Headers()
    trailers.add("x-digest", "ok")
    assert_false(sender.finish(trailers^))
    var output = List[Byte]()
    var done = False
    var count = 0
    while not done and count < 100:
        assert_true(
            _detach_state(writer._detach_state_addr)[].queued_bytes <= 2
        )
        _ = _collect(writer._detach_state_addr, output)
        done = sender.finish()
        count += 1
    assert_true(done)
    var final = _take_batch(_detach_state(writer._detach_state_addr))
    for i in range(len(final.messages)):
        if final.messages[i].kind == MSG_KIND_CHUNK:
            output.extend(Span(final.messages[i].body))
            _consume_detach_bytes(
                writer._detach_state_addr, len(final.messages[i].body)
            )
    assert_equal(final.terminal_kind, MSG_KIND_FINISH)
    assert_equal(final.trailers.get_first("x-digest").value(), "ok")
    assert_true(len(output) > 4)


def test_new_source_is_not_owned_when_prior_wire_is_blocked() raises:
    var req = _request()
    var writer = ResponseWriter(64, queue_limit=2)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(8), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    assert_true(sender.send("first".as_bytes()))
    assert_false(sender.send("second".as_bytes()))
    assert_equal(sender._source_seen, 5)
    assert_false(sender.is_cancelled())
    sender.abort()


def test_cancelled_stream_refuses_new_source_and_releases_buffers() raises:
    var budget = SharedBufferBudget(65536)
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_mailbox_budget(budget.copy())
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    _cancel_detach_state(writer._detach_state_addr)
    assert_true(sender.is_cancelled())
    assert_false(sender.send("tiny".as_bytes()))
    assert_equal(sender._source_seen, 0)
    assert_equal(sender._input_ticket.amount, 0)
    assert_equal(sender._output_ticket.amount, 0)
    _ = sender^
    assert_equal(budget.used(), 0)


def test_known_small_stream_stays_identity() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("build/compression/libnet_zlib")
    )
    var headers = Headers()
    headers.add("Content-Length", "4")
    sender.start(200, headers^)
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(initial.messages[0].headers.count("Content-Encoding"), 0)
    assert_equal(
        initial.messages[0].headers.get_first("Content-Length").value(), "4"
    )
    assert_true(sender.send("tiny".as_bytes()))
    assert_true(sender.finish())


def test_request_snapshot_is_owned_before_detachment() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("build/compression/libnet_zlib")
    )
    req.path = "/asset.gz"
    req.headers.clear()
    req.headers.add("Accept-Encoding", "gzip;q=0")
    sender.start()
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(
        initial.messages[0].headers.get_first("Content-Encoding").value(),
        "gzip",
    )
    assert_true(sender.finish())


def test_oversized_source_chunk_is_rejected_before_ownership() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    var sender = writer.detach_compressed(
        req, _config(2), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    with assert_raises():
        _ = sender.send("tiny".as_bytes())
    assert_equal(sender._source_seen, 0)
    assert_true(sender.finish())


def test_head_stream_retains_identity_representation_length() raises:
    var req = _request("HEAD")
    var writer = ResponseWriter(64, is_head=True)
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("build/compression/libnet_zlib")
    )
    var headers = Headers()
    headers.add("Content-Length", "4096")
    sender.start(200, headers^)
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(initial.messages[0].headers.count("Content-Encoding"), 0)
    assert_equal(
        initial.messages[0].headers.get_first("Content-Length").value(), "4096"
    )
    assert_true(sender.finish())


def test_working_buffer_reservation_failure_refunds_before_abort() raises:
    comptime state_size = size_of[_SharedDetachState]()
    var budget = SharedBufferBudget(state_size + 96)
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_mailbox_budget(budget.copy())
    var sender = writer.detach_compressed(
        req, _config(64), Optional[String]("build/compression/libnet_zlib")
    )
    with assert_raises():
        sender.start()
    assert_equal(sender._input_ticket.amount, 0)
    assert_equal(sender._output_ticket.amount, 0)
    assert_equal(budget.used(), state_size)
    _cancel_detach_state(writer._detach_state_addr)
    _ = sender^
    assert_equal(budget.used(), 0)


def test_successful_finish_releases_fixed_working_buffers() raises:
    var budget = SharedBufferBudget(65536)
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_mailbox_budget(budget.copy())
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(64), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    assert_equal(sender._input_ticket.amount, 64)
    assert_equal(sender._output_ticket.amount, 64)
    assert_true(sender.send("tiny".as_bytes()))
    assert_true(sender.finish())
    assert_equal(sender._input_ticket.amount, 0)
    assert_equal(sender._output_ticket.amount, 0)
    _cancel_detach_state(writer._detach_state_addr)
    _ = sender^
    assert_equal(budget.used(), 0)


def test_missing_stream_provider_aborts_and_refunds_buffers() raises:
    var budget = SharedBufferBudget(65536)
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_mailbox_budget(budget.copy())
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("missing-gzip-provider")
    )
    with assert_raises():
        sender.start()
    assert_equal(sender._input_ticket.amount, 0)
    assert_equal(sender._output_ticket.amount, 0)
    assert_equal(
        _detach_state(writer._detach_state_addr)[].terminal_kind, MSG_KIND_ABORT
    )
    _cancel_detach_state(writer._detach_state_addr)
    _ = sender^
    assert_equal(budget.used(), 0)


def test_known_gzip_source_allows_wire_trailers_after_exact_admission() raises:
    var req = _request()
    var writer = ResponseWriter(64)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var cfg = _config()
    cfg.min_size = 0
    var sender = writer.detach_compressed(
        req, cfg^, Optional[String]("build/compression/libnet_zlib")
    )
    var headers = Headers()
    headers.add("Content-Length", "4")
    sender.start(200, headers^)
    assert_true(sender.send("tiny".as_bytes()))
    var trailers = Headers()
    trailers.add("x-digest", "ok")
    assert_true(sender.finish(trailers^))
    var final = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(final.terminal_kind, MSG_KIND_FINISH)
    assert_equal(final.trailers.get_first("x-digest").value(), "ok")


def test_stream_quality_zero_selects_identity() raises:
    var req = _request()
    req.headers.clear()
    req.headers.add("Accept-Encoding", "gzip;q=0, *")
    var writer = ResponseWriter(64)
    var sender = writer.detach_compressed(
        req, _config(), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    var initial = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(initial.messages[0].headers.count("Content-Encoding"), 0)
    assert_equal(
        initial.messages[0].headers.get_first("Vary").value(), "Accept-Encoding"
    )
    assert_true(sender.send("tiny".as_bytes()))
    assert_true(sender.finish())


def test_finish_on_cancelled_stream_raises_and_refunds() raises:
    var req = _request()
    var writer = ResponseWriter(64, queue_limit=2)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(8), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    assert_true(sender.send("tiny".as_bytes()))
    _cancel_detach_state(writer._detach_state_addr)
    with assert_raises():
        _ = sender.finish()
    assert_equal(sender._input_ticket.amount, 0)
    assert_equal(sender._output_ticket.amount, 0)


def test_cancellation_poll_releases_pending_buffers_and_trailers() raises:
    comptime state_size = size_of[_SharedDetachState]()
    var budget = SharedBufferBudget(65536)
    var req = _request()
    var writer = ResponseWriter(64, queue_limit=2)
    writer._set_mailbox_budget(budget.copy())
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach_compressed(
        req, _config(8), Optional[String]("build/compression/libnet_zlib")
    )
    sender.start()
    assert_true(sender.send("tiny".as_bytes()))
    var trailers = Headers()
    trailers.add("x-digest", "ok")
    assert_false(sender.finish(trailers^))
    _cancel_detach_state(writer._detach_state_addr)
    assert_true(sender.is_cancelled())
    assert_equal(sender._input_ticket.amount, 0)
    assert_equal(sender._output_ticket.amount, 0)
    assert_equal(len(sender._trailers), 0)
    assert_equal(budget.used(), state_size)
    _ = sender^
    assert_equal(budget.used(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
