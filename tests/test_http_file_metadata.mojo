from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.http import Headers
from net.http._file_http import (
    _conditional_status,
    _etag_matches,
    _parse_http_date,
    _parse_range,
)
from net.http._mimetype import _mime_type


def test_mime_extensions_take_precedence_over_sniffed_bytes() raises:
    for name, want in [
        ("index.HTML", "text/html; charset=utf-8"),
        ("a.css", "text/css; charset=utf-8"),
        ("a.js", "application/javascript"),
        ("a.json", "application/json"),
        ("a.svg", "image/svg+xml"),
        ("a.png", "image/png"),
        ("a.woff2", "font/woff2"),
        ("a.pdf", "application/pdf"),
        ("a.tar", "application/x-tar"),
        ("a.wasm", "application/wasm"),
    ]:
        assert_equal(_mime_type(name, "text".as_bytes()), want)


def test_mime_sniffs_binary_signatures_and_html() raises:
    var png: Array[Byte, 8] = [137, 80, 78, 71, 13, 10, 26, 10]
    var jpeg: Array[Byte, 3] = [255, 216, 255]
    var unknown: Array[Byte, 3] = [0, 1, 2]
    assert_equal(_mime_type("no-extension", Span(png)), "image/png")
    assert_equal(_mime_type("a.unknown", Span(jpeg)), "image/jpeg")
    assert_equal(
        _mime_type("a.unknown", Span(unknown)), "application/octet-stream"
    )
    assert_equal(_mime_type("a", "GIF89a".as_bytes()), "image/gif")
    assert_equal(_mime_type("a", "%PDF-1.7".as_bytes()), "application/pdf")
    assert_equal(
        _mime_type("a", "  <!doctype html><title>x".as_bytes()),
        "text/html; charset=utf-8",
    )
    assert_equal(
        _mime_type("a", "hello\nworld".as_bytes()), "text/plain; charset=utf-8"
    )
    assert_equal(
        _mime_type("a", "<htmlx>text".as_bytes()), "text/plain; charset=utf-8"
    )


def test_mime_sniff_is_limited_to_first_512_bytes() raises:
    var data = List[Byte](length=513, fill=Byte(97))
    data[512] = 0
    assert_equal(_mime_type("unknown", Span(data)), "text/plain; charset=utf-8")
    data[511] = 0
    assert_equal(_mime_type("unknown", Span(data)), "application/octet-stream")


def test_http_dates_accept_all_three_wire_formats() raises:
    for value in [
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
    ]:
        var parsed = _parse_http_date(value)
        assert_true(parsed)
        assert_equal(parsed.value(), 784111777)
    assert_equal(_parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT").value(), 0)
    assert_equal(_parse_http_date("Wed, 31 Dec 1969 23:59:59 GMT").value(), -1)
    assert_equal(
        _parse_http_date("Sat, 29 Feb 2020 00:00:00 GMT").value(), 1582934400
    )
    assert_equal(
        _parse_http_date("Sat, 31 Dec 2016 23:59:60 GMT").value(), 1483228800
    )


def test_http_dates_reject_invalid_calendar_clock_and_grammar() raises:
    for value in [
        "Mon, 29 Feb 2021 00:00:00 GMT",
        "Sun, 31 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 24:49:37 GMT",
        "Sun, 06 Nov 1994 08:60:37 GMT",
        "Sun, 06 Nov 1994 08:49:61 GMT",
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "sun, 06 Nov 1994 08:49:37 GMT",
        "garbage",
        "Sun, 6 Nov 1994 08:49:37 GMT",
    ]:
        assert_false(_parse_http_date(value))


def test_etag_weak_and_strong_comparison_and_wildcard() raises:
    var tag = String('W/"100-20"')
    assert_true(_etag_matches('"other", "100-20"', tag, True))
    assert_true(_etag_matches('W/"100-20"', tag, True))
    assert_true(_etag_matches(" * \t", tag, False))
    assert_false(_etag_matches('"100-20"', tag, False))
    assert_false(_etag_matches('"other"', tag, True))
    assert_true(_etag_matches('"a,b", "100-20"', tag, True))


def test_conditionals_prioritize_etags_and_compare_whole_seconds() raises:
    var headers = Headers()
    var mtime = Int64(784111777_999999999)
    headers.add("If-Modified-Since", "Sun, 06 Nov 1994 08:49:37 GMT")
    assert_equal(_conditional_status(headers, 'W/"x"', mtime), 304)
    headers.add("If-None-Match", '"different"')
    assert_equal(_conditional_status(headers, 'W/"x"', mtime), 200)
    headers = Headers()
    headers.add("If-Modified-Since", "Sun, 06 Nov 1994 08:49:37 GMT")
    headers.add("If-None-Match", '"x"')
    assert_equal(_conditional_status(headers, 'W/"x"', mtime), 304)
    headers = Headers()
    headers.add("If-Unmodified-Since", "Sun, 06 Nov 1994 08:49:36 GMT")
    assert_equal(_conditional_status(headers, 'W/"x"', mtime), 412)
    headers.add("If-Match", "*")
    assert_equal(_conditional_status(headers, 'W/"x"', mtime), 200)
    headers = Headers()
    headers.add("If-Match", '"x"')
    assert_equal(_conditional_status(headers, 'W/"x"', mtime), 412)


def test_single_ranges_clamp_end_and_support_suffix_and_open_end() raises:
    for value, start, length in [
        ("bytes=0-99", 0, 100),
        ("bytes=-100", 900, 100),
        ("bytes=100-", 100, 900),
        ("BYTES=0-99999999999999999999999999999", 0, 1000),
        ("bytes=-99999999999999999999999999999", 0, 1000),
        ("bytes=999-1000", 999, 1),
    ]:
        var part = _parse_range(value, 1000)
        assert_equal(part.status, 206)
        assert_equal(part.start, start)
        assert_equal(part.length, length)


def test_ranges_ignore_multiple_and_unknown_units_and_reject_no_overlap() raises:
    for value in ["bytes=0-9,20-29", "items=0-99", ""]:
        var part = _parse_range(value, 1000)
        assert_equal(part.status, 200)
        assert_equal(part.start, 0)
        assert_equal(part.length, 1000)
    for value in [
        "bytes=1000-",
        "bytes=1001-2000",
        "bytes=20-10",
        "bytes=-0",
        "bytes=abc-def",
        "bytes=99999999999999999999999999999-",
        "bytes=0-10x",
    ]:
        assert_equal(_parse_range(value, 1000).status, 416)
    assert_equal(_parse_range("bytes=0-0", 0).status, 416)


def test_duplicate_etag_fields_are_combined_for_preconditions() raises:
    var headers = Headers()
    headers.add("If-None-Match", '"different"')
    headers.add("If-None-Match", '"x"')
    assert_equal(_conditional_status(headers, 'W/"x"', 1), 304)
    headers = Headers()
    headers.add("If-Match", '"different"')
    headers.add("If-Match", "*")
    assert_equal(_conditional_status(headers, 'W/"x"', 1), 200)


def test_obsolete_date_year_uses_rolling_fifty_year_window() raises:
    var reference = String("Thu, 01 Jan 2026 00:00:00 GMT")
    assert_equal(
        _parse_http_date("Friday, 01-Jan-76 00:00:00 GMT", reference).value(),
        3345062400,
    )
    assert_equal(
        _parse_http_date("Friday, 02-Jan-76 00:00:00 GMT", reference).value(),
        189388800,
    )


def test_pre_epoch_subsecond_mtime_is_compared_with_floor_seconds() raises:
    var headers = Headers()
    headers.add("If-Modified-Since", "Wed, 31 Dec 1969 23:59:59 GMT")
    assert_equal(_conditional_status(headers, 'W/"x"', -1), 304)


def test_matching_entity_tag_with_comma_keeps_quoted_list_boundary() raises:
    assert_true(_etag_matches('"other", W/"a,b"', 'W/"a,b"', True))
    assert_true(_etag_matches('"a,b"', '"a,b"', False))
    var headers = Headers()
    headers.add("If-None-Match", '"a,b"')
    assert_equal(_conditional_status(headers, 'W/"a,b"', 0), 304)
    headers = Headers()
    headers.add("If-Match", '"a,b"')
    assert_equal(_conditional_status(headers, '"a,b"', 0), 200)


def test_obsolete_date_year_crosses_the_reference_century() raises:
    assert_equal(
        _parse_http_date(
            "Saturday, 01-Jan-00 00:00:00 GMT", "Fri, 01 Jan 1999 00:00:00 GMT"
        ).value(),
        946684800,
    )


def test_pre_epoch_subsecond_mtime_does_not_match_an_older_second() raises:
    var headers = Headers()
    headers.add("If-Modified-Since", "Wed, 31 Dec 1969 23:59:58 GMT")
    assert_equal(_conditional_status(headers, 'W/"x"', -1), 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
