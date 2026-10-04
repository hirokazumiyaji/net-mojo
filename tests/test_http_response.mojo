from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.error import NetErrorKind
from net.http._buffer import BufferBudget
from net.http import ResponseWriter, has_body_for_status
from net.http._encoder import (
    current_http_date,
    encode_100_continue,
    encode_error,
    encode_response,
    http_date,
    _encode_response_budgeted,
    _measure_response,
)


def test_budgeted_wire_exact_capacity_matches_framing_and_raw_headers() raises:
    for status in [100, 200, 204, 205, 304]:
        for is_head in [False, True]:
            var writer = ResponseWriter(32)
            writer.status = status
            writer.should_close = True
            writer.write_string("hello")
            writer.headers.add(String("Content-Length"), String("5"))
            writer.headers.add(String("Date"), String("custom date"))
            writer.headers.add(
                String("Connection"), String("keep-alive, close")
            )
            var raw: Array[Byte, 2] = [128, 255]
            writer.headers.add_bytes(String("X-Bin"), Span(raw))
            var expected = encode_response(
                writer, is_head, "unused", 100, 32768
            )
            var budget = BufferBudget(1024)
            assert_true(budget.try_reserve(writer.body.capacity()))
            var wire = _encode_response_budgeted(
                writer, is_head, "unused", 100, 32768, budget
            )
            assert_equal(wire.capacity(), len(expected))
            assert_equal(len(wire), len(expected))
            assert_equal(budget.used, writer.body.capacity() + wire.capacity())
            for i in range(len(wire)):
                assert_equal(wire[i], expected[i])


def test_budgeted_wire_requires_body_and_wire_capacity_together() raises:
    var writer = ResponseWriter(32)
    writer.write_string("12345678")
    var size = _measure_response(writer, False, "date", 100, 32768)
    var budget = BufferBudget(8 + size - 1)
    assert_true(budget.try_reserve(8))
    var rejected = False
    try:
        _ = _encode_response_budgeted(writer, False, "date", 100, 32768, budget)
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)
    assert_equal(budget.used, 8)
    assert_equal(writer.body.capacity(), 8)
    budget.total += 1
    var wire = _encode_response_budgeted(
        writer, False, "date", 100, 32768, budget
    )
    assert_equal(wire.capacity(), size)
    assert_equal(budget.used, 8 + size)
    _ = wire^
    budget.release(size)
    assert_equal(budget.used, 8)


def test_budgeted_wire_validation_failure_preserves_reservation() raises:
    for invalid in range(3):
        var writer = ResponseWriter(32)
        writer.write_string("hello")
        if invalid == 0:
            writer.headers.add(String("Content-Length"), String("999"))
        if invalid == 2:
            writer.status = 99
        var date = String("date\r\n") if invalid == 1 else String("date")
        var budget = BufferBudget(512)
        assert_true(budget.try_reserve(5))
        var rejected = False
        try:
            _ = _encode_response_budgeted(
                writer, False, date, 100, 32768, budget
            )
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_true(rejected)
        assert_equal(budget.used, 5)


def _bytes_to_string[origin: Origin](bytes: Span[Byte, origin]) -> String:
    return String(from_utf8_lossy=bytes)


def test_http_date_vectors() raises:
    assert_equal(http_date(0), "Thu, 01 Jan 1970 00:00:00 GMT")
    assert_equal(http_date(946684800), "Sat, 01 Jan 2000 00:00:00 GMT")
    assert_equal(http_date(1788756101), "Mon, 07 Sep 2026 04:41:41 GMT")
    var now = current_http_date()
    assert_true(now.endswith(" GMT"))


def test_normal_response_has_length_and_date() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Content-Type"), String("text/plain"))
    writer.write_string("hello")
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.startswith("HTTP/1.1 200 OK\r\n"))
    assert_true(text.find("Content-Type: text/plain\r\n") >= 0)
    assert_true(text.find("Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n") >= 0)
    assert_true(text.find("Content-Length: 5\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\nhello"))


def test_head_keeps_length_but_omits_body() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Content-Type"), String("text/plain"))
    writer.write_string("hello")
    var wire = encode_response(
        writer, True, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Content-Length: 5\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\n"))
    assert_false(has_body_for_status(200, True))


def test_no_body_statuses_drop_body_and_length() raises:
    for status in [204, 205, 304]:
        var writer = ResponseWriter(1024)
        writer.set_status(status)
        writer.headers.add(String("Content-Type"), String("text/plain"))
        writer.write_string("dropped")
        var wire = encode_response(
            writer,
            False,
            "Thu, 01 Jan 1970 00:00:00 GMT",
            100,
            32768,
        )
        var text = _bytes_to_string(Span(wire))
        assert_true(text.find("Content-Length") < 0)
        assert_true(text.endswith("\r\n\r\n"))
        assert_false(has_body_for_status(status, False))
    var informational = ResponseWriter(1024)
    informational.set_status(100)
    var wire_info = encode_response(
        informational,
        False,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        100,
        32768,
    )
    var text_info = _bytes_to_string(Span(wire_info))
    assert_true(text_info.find("Content-Length") < 0)


def test_duplicate_response_headers_preserved() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("X-Multi"), String("1"))
    writer.headers.add(String("x-multi"), String("2"))
    writer.write_string("ok")
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("X-Multi: 1\r\n") >= 0)
    assert_true(text.find("x-multi: 2\r\n") >= 0)
    # Never comma-joined into a single line.
    assert_true(text.find("1, 2") < 0)


def test_response_injection_rejected() raises:
    var writer = ResponseWriter(1024)
    var rejected = False
    try:
        writer.headers.add(String("X-Bad"), String("a\r\nB: 1"))
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)


def test_content_length_consistency_enforced() raises:
    var matching = ResponseWriter(1024)
    matching.headers.add(String("Content-Length"), String("2"))
    matching.write_string("ab")
    var wire = encode_response(
        matching, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Content-Length: 2\r\n") >= 0)
    var mismatch = ResponseWriter(1024)
    mismatch.headers.add(String("Content-Length"), String("99"))
    mismatch.write_string("ab")
    var failed = False
    try:
        _ = encode_response(
            mismatch, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
        )
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        failed = True
    assert_true(failed)


def test_transfer_encoding_on_response_is_rejected() raises:
    # Emitting Transfer-Encoding alongside Content-Length would create a
    # smuggling vector (RFC 9112 6.1); handlers must not set it.
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Transfer-Encoding"), String("chunked"))
    writer.write_string("hello")
    var failed = False
    try:
        _ = encode_response(
            writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
        )
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        failed = True
    assert_true(failed)


def test_caller_date_is_kept() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Date"), String("Thu, 01 Jan 1970 00:00:00 GMT"))
    writer.write_string("hi")
    var wire = encode_response(
        writer, False, "Sat, 01 Jan 2000 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n") >= 0)
    assert_true(text.find("Sat, 01 Jan 2000") < 0)


def test_connection_close_advertised() raises:
    var writer = ResponseWriter(1024)
    writer.set_should_close(True)
    writer.write_string("bye")
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Connection: close\r\n") >= 0)


def test_connection_close_needs_whole_token() raises:
    # `x-close` must not suppress the real header; `Keep-Alive, close`
    # must.
    var tricky = ResponseWriter(1024)
    tricky.set_should_close(True)
    tricky.headers.add(String("Connection"), String("x-close"))
    tricky.write_string("bye")
    var tricky_wire = encode_response(
        tricky,
        False,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        100,
        32768,
    )
    var tricky_text = _bytes_to_string(Span(tricky_wire))
    assert_true(tricky_text.find("Connection: close\r\n") >= 0)
    var listed = ResponseWriter(1024)
    listed.set_should_close(True)
    listed.headers.add(String("Connection"), String("Keep-Alive, close"))
    listed.write_string("bye")
    var listed_wire = encode_response(
        listed,
        False,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        100,
        32768,
    )
    var listed_text = _bytes_to_string(Span(listed_wire))
    assert_true(listed_text.find("Connection: close\r\n") < 0)


def test_response_header_limits_are_enforced() raises:
    var many = ResponseWriter(1024)
    for _ in range(101):
        many.headers.add(String("X-A"), String("1"))
    many.write_string("x")
    var failed_count = False
    try:
        _ = encode_response(
            many, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
        )
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        failed_count = True
    assert_true(failed_count)
    var big = ResponseWriter(1024)
    big.headers.add(String("X-A"), String("y") * 40000)
    big.write_string("x")
    var failed_bytes = False
    try:
        _ = encode_response(
            big, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
        )
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        failed_bytes = True
    assert_true(failed_bytes)
    # Exactly at the limits still encodes.
    var edge = ResponseWriter(1024)
    edge.headers.add(String("X-A"), String("1"))
    edge.write_string("x")
    var wire = encode_response(
        edge, False, "Thu, 01 Jan 1970 00:00:00 GMT", 1, 32768
    )
    assert_true(len(wire) > 0)


def test_obs_text_header_value_emitted_verbatim() raises:
    # A stored 0x80 byte must reach the wire unchanged, not as U+FFFD.
    var writer = ResponseWriter(1024)
    var raw = List[Byte]()
    raw.append(Byte(ord("a")))
    raw.append(Byte(128))
    writer.headers.add_bytes(String("X-Bin"), Span(raw))
    writer.write_string("ok")
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var found = False
    for i in range(len(wire) - 2):
        if (
            wire[i] == Byte(ord("a"))
            and wire[i + 1] == Byte(128)
            and wire[i + 2] == Byte(ord("\r"))
        ):
            found = True
            break
    assert_true(found)


def test_100_continue_encoding() raises:
    var wire = encode_100_continue()
    var text = _bytes_to_string(Span(wire))
    assert_equal(text, "HTTP/1.1 100 Continue\r\n\r\n")


def test_invalid_status_codes_are_rejected() raises:
    for bad in [99, 1000]:
        var writer = ResponseWriter(1024)
        writer.set_status(bad)
        writer.write_string("x")
        var failed = False
        try:
            _ = encode_response(
                writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
            )
        except error:
            assert_equal(error.kind, NetErrorKind.invalid_argument())
            failed = True
        assert_true(failed)


def test_error_encoding_is_bounded() raises:
    var wire = encode_error(400, True, "Thu, 01 Jan 1970 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.startswith("HTTP/1.1 400 Bad Request\r\n"))
    assert_true(text.find("Connection: close\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\n400 Bad Request"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
