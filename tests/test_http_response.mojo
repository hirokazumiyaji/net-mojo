from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.error import NetErrorKind
from net.http import ResponseWriter, has_body_for_status
from net.http._encoder import (
    current_http_date,
    encode_100_continue,
    encode_error,
    encode_response,
    http_date,
)


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
    var wire = encode_response(writer, False, "Thu, 01 Jan 1970 00:00:00 GMT")
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
    var wire = encode_response(writer, True, "Thu, 01 Jan 1970 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Content-Length: 5\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\n"))
    assert_false(has_body_for_status(200, True))


def test_no_body_statuses_drop_body_and_length() raises:
    for status in [204, 304]:
        var writer = ResponseWriter(1024)
        writer.set_status(status)
        writer.headers.add(String("Content-Type"), String("text/plain"))
        var wire = encode_response(
            writer, False, "Thu, 01 Jan 1970 00:00:00 GMT"
        )
        var text = _bytes_to_string(Span(wire))
        assert_true(text.find("Content-Length") < 0)
        assert_true(text.endswith("\r\n\r\n"))
        assert_false(has_body_for_status(status, False))
    var informational = ResponseWriter(1024)
    informational.set_status(100)
    var wire_info = encode_response(
        informational, False, "Thu, 01 Jan 1970 00:00:00 GMT"
    )
    var text_info = _bytes_to_string(Span(wire_info))
    assert_true(text_info.find("Content-Length") < 0)


def test_duplicate_response_headers_preserved() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("X-Multi"), String("1"))
    writer.headers.add(String("x-multi"), String("2"))
    writer.write_string("ok")
    var wire = encode_response(writer, False, "Thu, 01 Jan 1970 00:00:00 GMT")
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
    var wire = encode_response(matching, False, "Thu, 01 Jan 1970 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Content-Length: 2\r\n") >= 0)
    var mismatch = ResponseWriter(1024)
    mismatch.headers.add(String("Content-Length"), String("99"))
    mismatch.write_string("ab")
    var failed = False
    try:
        _ = encode_response(mismatch, False, "Thu, 01 Jan 1970 00:00:00 GMT")
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        failed = True
    assert_true(failed)


def test_caller_date_is_kept() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Date"), String("Thu, 01 Jan 1970 00:00:00 GMT"))
    writer.write_string("hi")
    var wire = encode_response(writer, False, "Sat, 01 Jan 2000 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n") >= 0)
    assert_true(text.find("Sat, 01 Jan 2000") < 0)


def test_connection_close_advertised() raises:
    var writer = ResponseWriter(1024)
    writer.set_should_close(True)
    writer.write_string("bye")
    var wire = encode_response(writer, False, "Thu, 01 Jan 1970 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Connection: close\r\n") >= 0)


def test_100_continue_encoding() raises:
    var wire = encode_100_continue()
    var text = _bytes_to_string(Span(wire))
    assert_equal(text, "HTTP/1.1 100 Continue\r\n\r\n")


def test_error_encoding_is_bounded() raises:
    var wire = encode_error(400, True, "Thu, 01 Jan 1970 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.startswith("HTTP/1.1 400 Bad Request\r\n"))
    assert_true(text.find("Connection: close\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\n400 Bad Request"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
