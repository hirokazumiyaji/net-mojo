from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net import Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Headers,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.http._detach import (
    _consume_detach_bytes,
    _release_detach_state,
    _take_batch,
    _detach_state,
    _DetachTarget,
    MSG_KIND_ABORT,
    MSG_KIND_FINISH,
)
from net.http._encoder import encode_chunked_start, encode_response
from net.http._http2.response_headers import encode_http2_response_headers
from tests.support import _content_length_of, _status_of
from tests.test_http_detach import (
    _DeferredHandler,
    _tick_until_detached,
    _tick_and_read,
    _body_of,
)


def _length_headers(length: Int) raises -> Headers:
    var headers = Headers()
    headers.add("Content-Length", String(length))
    return headers^


def test_known_length_sender_finishes_only_after_exact_admission() raises:
    var writer = ResponseWriter(8)
    var sender = writer.detach()
    var accepted = False
    try:
        sender.start(200, _length_headers(5))
        accepted = True
    except:
        pass
    if accepted:
        assert_true(sender.send("hello".as_bytes()))
        sender.finish()
        var batch = _take_batch(_detach_state(writer._detach_state_addr))
        assert_equal(batch.terminal_kind, MSG_KIND_FINISH)
        assert_false(sender.is_cancelled())
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    assert_true(accepted)


def test_known_length_sender_underflow_aborts() raises:
    var writer = ResponseWriter(8)
    var sender = writer.detach()
    var accepted = False
    var rejected = False
    try:
        sender.start(200, _length_headers(5))
        accepted = True
    except:
        pass
    if accepted:
        assert_true(sender.send("four".as_bytes()))
        try:
            sender.finish()
        except e:
            rejected = e.kind == NetErrorKind.invalid_argument()
        assert_true(sender.is_cancelled())
        var batch = _take_batch(_detach_state(writer._detach_state_addr))
        assert_equal(batch.terminal_kind, MSG_KIND_ABORT)
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    assert_true(accepted)
    assert_true(rejected)


def test_known_length_sender_overflow_aborts_without_excess_chunk() raises:
    var writer = ResponseWriter(8)
    var sender = writer.detach()
    var accepted = False
    var rejected = False
    try:
        sender.start(200, _length_headers(3))
        accepted = True
    except:
        pass
    if accepted:
        try:
            _ = sender.send("four".as_bytes())
        except e:
            rejected = e.kind == NetErrorKind.invalid_argument()
        assert_true(sender.is_cancelled())
        var batch = _take_batch(_detach_state(writer._detach_state_addr))
        assert_equal(batch.terminal_kind, MSG_KIND_ABORT)
        assert_equal(len(batch.messages), 1)
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    assert_true(accepted)
    assert_true(rejected)


def test_known_length_backpressure_does_not_count_unadmitted_bytes() raises:
    var writer = ResponseWriter(8, queue_limit=2)
    writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
    var sender = writer.detach()
    var accepted = False
    try:
        sender.start(200, _length_headers(4))
        accepted = True
    except:
        pass
    if accepted:
        assert_true(sender.send("ab".as_bytes()))
        assert_false(sender.send("cd".as_bytes()))
        _consume_detach_bytes(writer._detach_state_addr, 2)
        assert_true(sender.send("cd".as_bytes()))
        sender.finish()
        assert_false(sender.is_cancelled())
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    assert_true(accepted)


def test_known_length_stream_rejects_trailers() raises:
    var writer = ResponseWriter(8)
    var sender = writer.detach()
    var accepted = False
    var rejected = False
    try:
        sender.start(200, _length_headers(0))
        accepted = True
    except:
        pass
    if accepted:
        var trailers = Headers()
        trailers.add("X-Checksum", "ok")
        try:
            sender.finish(trailers^)
        except e:
            rejected = e.kind == NetErrorKind.invalid_argument()
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    assert_true(accepted)
    assert_true(rejected)


def test_known_length_h1_headers_omit_chunked_coding() raises:
    var writer = ResponseWriter(0)
    writer.headers = _length_headers(1073741824)
    var accepted = False
    var wire = List[Byte]()
    try:
        wire = encode_chunked_start(writer, False, "date", 32, 4096)
        accepted = True
    except:
        pass
    assert_true(accepted)
    var text = String(from_utf8_lossy=Span(wire))
    assert_true(text.find("Content-Length: 1073741824\r\n") >= 0)
    assert_equal(text.find("Transfer-Encoding:"), -1)


def test_known_length_h2_headers_preserve_declared_length() raises:
    var writer = ResponseWriter(0)
    writer.headers = _length_headers(1073741824)
    var fields = encode_http2_response_headers(
        writer, False, "date", 4096, 32, streaming=True
    )
    assert_true(fields.is_valid())
    var text = String(from_utf8_lossy=Span(fields.fields))
    assert_true(text.find("content-length1073741824") >= 0)


def test_known_length_h1_body_and_keepalive() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var box = 0
    var handler = _DeferredHandler(
        Pointer(to=box).unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var client = dial_tcp(
        "127.0.0.1:" + String(server.local_address().port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    _tick_until_detached(server, handler, handler.sender_box)
    var sender = ResponseSender(box)
    var accepted = False
    try:
        sender.start(200, _length_headers(9))
        accepted = True
    except:
        pass
    if accepted:
        assert_true(sender.send("alphabeta".as_bytes()))
        sender.finish()
        var response = _tick_and_read(server, handler, client)
        assert_equal(_status_of(response), 200)
        assert_equal(_content_length_of(response), 9)
        assert_equal(_body_of(response), "alphabeta")
        var text = String(from_utf8_lossy=Span(response))
        assert_equal(text.find("Transfer-Encoding:"), -1)
        client.write_all(
            "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
            Timeout.seconds(2),
        )
        var second = _tick_and_read(server, handler, client)
        assert_equal(_body_of(second), "second-response")
    client.close()
    assert_true(accepted)


def test_head_advertises_unbuffered_representation_length() raises:
    var writer = ResponseWriter(0)
    writer.headers = _length_headers(1073741824)
    var accepted = False
    var wire = List[Byte]()
    try:
        wire = encode_response(writer, True, "date", 32, 4096)
        accepted = True
    except:
        pass
    assert_true(accepted)
    assert_equal(_content_length_of(wire), 1073741824)
    assert_equal(_body_of(wire), "")


def test_h2_head_advertises_unbuffered_representation_length() raises:
    var writer = ResponseWriter(0)
    writer.headers = _length_headers(1073741824)
    var fields = encode_http2_response_headers(writer, True, "date", 4096, 32)
    assert_true(fields.is_valid())
    assert_false(fields.send_body)
    assert_true(
        String(from_utf8_lossy=Span(fields.fields)).find(
            "content-length1073741824"
        )
        >= 0
    )


def test_get_still_rejects_empty_body_with_nonzero_length() raises:
    var writer = ResponseWriter(0)
    writer.headers = _length_headers(1073741824)
    var rejected = False
    try:
        _ = encode_response(writer, False, "date", 32, 4096)
    except e:
        rejected = e.kind == NetErrorKind.invalid_argument()
    assert_true(rejected)
    var fields = encode_http2_response_headers(writer, False, "date", 4096, 32)
    assert_true(fields.is_error())


def test_known_length_h1_head_finishes_without_body_and_keeps_alive() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var box = 0
    var handler = _DeferredHandler(
        Pointer(to=box).unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var client = dial_tcp(
        "127.0.0.1:" + String(server.local_address().port), Timeout.seconds(2)
    )
    client.write_all(
        "HEAD /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    _tick_until_detached(server, handler, handler.sender_box)
    var sender = ResponseSender(box)
    sender.start(200, _length_headers(1073741824))
    sender.finish()
    var response = _tick_and_read(server, handler, client, expect_body=False)
    assert_equal(_status_of(response), 200)
    assert_equal(_content_length_of(response), 1073741824)
    assert_equal(_body_of(response), "")
    client.write_all(
        "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    var second = _tick_and_read(server, handler, client)
    assert_equal(_body_of(second), "second-response")
    client.close()


def test_try_send_preserves_h1_response_during_queue_pressure() raises:
    var writer = ResponseWriter(8, queue_limit=2)
    var sender = writer.detach()
    sender.start(200, _length_headers(4))
    assert_true(sender.try_send("ab".as_bytes()))
    assert_false(sender.try_send("cd".as_bytes()))
    assert_false(sender.is_cancelled())
    var first = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(len(first.messages), 2)
    assert_false(sender.try_send("cd".as_bytes()))
    _consume_detach_bytes(writer._detach_state_addr, 2)
    assert_true(sender.try_send("cd".as_bytes()))
    sender.finish()
    assert_false(sender.is_cancelled())
    _release_detach_state(writer._detach_state_addr, from_sender=False)


def test_try_send_h1_credit_waits_until_pending_socket_output_drains() raises:
    var config = ServerConfig.default()
    config.max_bytes_per_tick = 128
    config.stream_queue_limit = 1024
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var box = 0
    var handler = _DeferredHandler(
        Pointer(to=box).unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var client = dial_tcp(
        "127.0.0.1:" + String(server.local_address().port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    _tick_until_detached(server, handler, handler.sender_box)
    server.config.max_bytes_per_tick = 1
    var sender = ResponseSender(box)
    var chunk = List[Byte](length=1024, fill=Byte(97))
    sender.start(200, _length_headers(2048))
    assert_true(sender.try_send(Span(chunk)))
    assert_false(sender.try_send(Span(chunk)))
    _ = server.tick(handler, Timeout.milliseconds(0))
    assert_false(sender.try_send(Span(chunk)))
    assert_false(sender.is_cancelled())
    for _ in range(1300):
        _ = server.tick(handler, Timeout.milliseconds(0))
    assert_true(sender.try_send(Span(chunk)))
    sender.finish()
    for _ in range(1300):
        _ = server.tick(handler, Timeout.milliseconds(0))
    var response = _tick_and_read(server, handler, client)
    assert_equal(_content_length_of(response), 2048)
    assert_equal(_body_of(response).byte_length(), 2048)
    client.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
