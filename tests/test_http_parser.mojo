from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.http import ServerConfig
from net.http._parser import HttpParser, parse_one


def _to_bytes(data: StringSlice) -> List[Byte]:
    var out = List[Byte]()
    var bytes = data.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _assert_complete(
    raw: String, want_method: String, want_path: String, want_body_len: Int
) raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(raw)
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_equal(result.consumed, len(buf))
    assert_equal(result.request.method, want_method)
    assert_equal(result.request.path, want_path)
    assert_equal(len(result.request.body), want_body_len)


def _assert_status(raw: String, want_status: Int) raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(raw)
    var result = parse_one(Span(buf), config)
    assert_true(result.is_error())
    assert_equal(result.error.status, want_status)


def _assert_split_identical(raw: String) raises:
    # Every single-byte split point must yield the same final request.
    var config = ServerConfig.default()
    var full = _to_bytes(raw)
    var expected = parse_one(Span(full), config)
    assert_true(expected.is_complete())
    for split in range(1, len(full)):
        var parser = HttpParser()
        var first = List[Byte]()
        for i in range(split):
            first.append(full[i])
        parser.feed(Span(first))
        var early = parser.next_result(config)
        assert_true(early.is_need_more())
        var second = List[Byte]()
        for i in range(split, len(full)):
            second.append(full[i])
        parser.feed(Span(second))
        var final = parser.next_result(config)
        assert_true(final.is_complete())
        # The parser accumulates both feeds, so consumed equals the full
        # request length regardless of the split point.
        assert_equal(final.consumed, len(full))
        assert_equal(final.request.method, expected.request.method)
        assert_equal(final.request.path, expected.request.path)
        assert_equal(len(final.request.body), len(expected.request.body))


def test_simple_get_with_content_length() raises:
    _assert_complete(
        (
            "GET /hello HTTP/1.1\r\nHost: example.com\r\nContent-Length:"
            " 5\r\n\r\nhello"
        ),
        "GET",
        "/hello",
        5,
    )


def test_get_without_body() raises:
    _assert_complete(
        "GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n", "GET", "/hello", 0
    )


def test_path_query_split_without_decoding() raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(
        "GET /a%2Fb?x=%41 HTTP/1.1\r\nHost: h\r\n\r\n",
    )
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_equal(result.request.path, "/a%2Fb")
    assert_equal(result.request.query, "x=%41")
    assert_equal(result.request.target, "/a%2Fb?x=%41")


def test_binary_body_preserved() raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(
        "POST /bin HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\n\r\n",
    )
    buf.append(Byte(0))
    buf.append(Byte(13))
    buf.append(Byte(10))
    buf.append(Byte(255))
    buf.append(Byte(0))
    buf.append(Byte(65))
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_equal(len(result.request.body), 6)
    assert_equal(result.request.body[0], Byte(0))
    assert_equal(result.request.body[1], Byte(13))
    assert_equal(result.request.body[3], Byte(255))
    assert_equal(result.request.body[5], Byte(65))


def test_non_ascii_target_is_rejected() raises:
    # Raw non-ASCII bytes must arrive percent-encoded; accepting them
    # would let the ASCII path/query split normalize bytes irreversibly.
    var config = ServerConfig.default()
    var buf = _to_bytes("GET /caf")
    buf.append(Byte(195))
    buf.append(Byte(169))
    var tail = _to_bytes(" HTTP/1.1\r\nHost: h\r\n\r\n")
    for i in range(len(tail)):
        buf.append(tail[i])
    var result = parse_one(Span(buf), config)
    assert_true(result.is_error())
    assert_equal(result.error.status, 400)


def test_many_tiny_chunks_decode_correctly() raises:
    # 100 one-byte chunks exercise the incremental path without losing
    # bytes; per-tick reparse cost stays bounded by the body cap.
    var config = ServerConfig.default()
    var buf = _to_bytes(
        "POST /many HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    for i in range(100):
        var head = _to_bytes("1\r\n")
        for k in range(len(head)):
            buf.append(head[k])
        buf.append(Byte(ord("a") + (i % 26)))
        var crlf = _to_bytes("\r\n")
        for k in range(len(crlf)):
            buf.append(crlf[k])
    var tail = _to_bytes("0\r\n\r\n")
    for i in range(len(tail)):
        buf.append(tail[i])
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_equal(len(result.request.body), 100)
    assert_equal(result.request.body[0], Byte(ord("a")))
    assert_equal(result.request.body[99], Byte(ord("a") + (99 % 26)))


def test_chunked_with_extension_and_trailer() raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(
        (
            "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
            "5;ext=1\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n"
        ),
    )
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_equal(len(result.request.body), 5)
    assert_equal(len(result.request.trailers), 1)
    assert_equal(len(result.request.headers), 2)
    var trailer = result.request.trailers.get_first("x-trailer")
    assert_true(Bool(trailer))
    assert_equal(trailer.value(), "1")


def test_pipelined_requests_leave_remainder() raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(
        (
            "GET /one HTTP/1.1\r\nHost: h\r\n\r\n"
            "GET /two HTTP/1.1\r\nHost: h\r\n\r\n"
        ),
    )
    var first = parse_one(Span(buf), config)
    assert_true(first.is_complete())
    assert_equal(first.request.path, "/one")
    var rest = List[Byte]()
    for i in range(first.consumed, len(buf)):
        rest.append(buf[i])
    var second = parse_one(Span(rest), config)
    assert_true(second.is_complete())
    assert_equal(second.request.path, "/two")
    # The pipelined bytes were not mistaken for a body.
    assert_equal(len(first.request.body), 0)


def test_fragmentation_at_every_boundary() raises:
    _assert_split_identical(
        (
            "POST /frag HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
        ),
    )
    _assert_split_identical(
        (
            "GET /hello HTTP/1.1\r\nHost: example.com\r\nContent-Length:"
            " 5\r\n\r\nhello"
        ),
    )


def test_seed_recorded_fragmentation() raises:
    # Deterministic pseudo-random splits (LCG, seed 42) over a chunked
    # request with trailers. The seed is recorded so failures reproduce.
    var config = ServerConfig.default()
    var full = _to_bytes(
        (
            "POST /seed HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\n4;e=x\r\nabcd\r\n2\r\nef\r\n0\r\nX-S: v\r\n\r\n"
        ),
    )
    var expected = parse_one(Span(full), config)
    assert_true(expected.is_complete())
    var state = UInt64(42)
    var points = List[Int]()
    for _ in range(5):
        state = state * UInt64(6364136223846793005) + UInt64(
            1442695040888963407
        )
        points.append(Int(state % UInt64(len(full))))
    var parser = HttpParser()
    var cursor = 0
    # Feed in increasing split order plus the tail.
    var ordered = List[Int]()
    for i in range(len(points)):
        ordered.append(points[i])
    # Simple insertion sort for determinism.
    for i in range(len(ordered)):
        for j in range(i + 1, len(ordered)):
            if ordered[j] < ordered[i]:
                var tmp = ordered[i]
                ordered[i] = ordered[j]
                ordered[j] = tmp
    for k in range(len(ordered)):
        var point = ordered[k]
        if point <= cursor or point >= len(full):
            continue
        var chunk = List[Byte]()
        for i in range(cursor, point):
            chunk.append(full[i])
        parser.feed(Span(chunk))
        var interim = parser.next_result(config)
        assert_true(interim.is_need_more())
        cursor = point
    var tail = List[Byte]()
    for i in range(cursor, len(full)):
        tail.append(full[i])
    parser.feed(Span(tail))
    var final = parser.next_result(config)
    assert_true(final.is_complete())
    assert_equal(final.request.path, expected.request.path)
    assert_equal(len(final.request.body), len(expected.request.body))


def test_host_missing_duplicate_invalid() raises:
    _assert_status("GET /a HTTP/1.1\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost:\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost: a b\r\n\r\n", 400)


def test_content_length_and_transfer_encoding() raises:
    _assert_status(
        (
            "GET /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length:"
            " 3\r\n\r\nabc"
        ),
        400,
    )
    _assert_status(
        (
            "GET /a HTTP/1.1\r\nHost: h\r\nContent-Length:"
            " 3\r\nTransfer-Encoding: chunked\r\n\r\n"
        ),
        400,
    )
    _assert_status(
        "GET /a HTTP/1.1\r\nHost: h\r\nContent-Length: 12x\r\n\r\n", 400
    )
    _assert_status(
        "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\n",
        400,
    )
    # Chunked is case-insensitive and must be the only coding.
    var config = ServerConfig.default()
    var chunked_buf = _to_bytes(
        "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
        " Chunked\r\n\r\n0\r\n\r\n"
    )
    var ok = parse_one(Span(chunked_buf), config)
    assert_true(ok.is_complete())


def test_overflow_and_limits() raises:
    _assert_status(
        (
            "GET /a HTTP/1.1\r\nHost: h\r\nContent-Length:"
            " 99999999999999999999\r\n\r\n"
        ),
        400,
    )
    _assert_status(
        "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 2097152\r\n\r\n",
        413,
    )
    _assert_status(
        (
            "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\nZZ\r\nx\r\n0\r\n\r\n"
        ),
        400,
    )
    _assert_status(
        (
            "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\n200000\r\n"
        ),
        413,
    )
    var long_target = String("a") * 9000
    _assert_status(
        String("GET /") + long_target + String(" HTTP/1.1\r\nHost: h\r\n\r\n"),
        414,
    )
    var many = String("GET /a HTTP/1.1\r\nHost: h\r\n")
    for _ in range(101):
        many += String("X-A: 1\r\n")
    many += String("\r\n")
    _assert_status(many, 431)


def test_chunk_metadata_and_trailer_limits() raises:
    var trailer_many = String(
        "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
    )
    for _ in range(33):
        trailer_many += String("X-T: 1\r\n")
    trailer_many += String("\r\n")
    _assert_status(trailer_many, 431)
    _assert_status(
        (
            "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\n0\r\nContent-Length: 3\r\n\r\n"
        ),
        400,
    )
    # RFC 9112 6.5.1: trailers must not carry framing, routing,
    # authentication, or payload-processing fields.
    for name in [
        "Authorization",
        "Proxy-Authorization",
        "Connection",
        "Trailer",
        "Content-Type",
        "Content-Encoding",
        "TE",
    ]:
        _assert_status(
            (
                "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
                " chunked\r\n\r\n0\r\n"
                + name
                + ": 1\r\n\r\n"
            ),
            400,
        )


def test_strict_crlf_token_obs_fold() raises:
    _assert_status("GET /a HTTP/1.1\nHost: h\n\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost: h\r\nBad Header: 1\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost: h\r\nX-A : 1\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost: h\r\nX-A: 1\r\n 2\r\n\r\n", 400)
    _assert_status("CONNECT h:443 HTTP/1.1\r\nHost: h\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1\r\nHost: h\r\nUpgrade: h2c\r\n\r\n", 400)
    _assert_status("GET /a HTTP/2.0\r\nHost: h\r\n\r\n", 505)


def test_absolute_form_and_options_star() raises:
    var config = ServerConfig.default()
    var absolute_buf = _to_bytes(
        "GET http://example.com/abs?q=2 HTTP/1.1\r\nHost: other.com\r\n\r\n"
    )
    var absolute = parse_one(Span(absolute_buf), config)
    assert_true(absolute.is_complete())
    # Absolute-form authority wins over Host.
    assert_equal(absolute.request.authority, "example.com")
    assert_equal(absolute.request.path, "/abs")
    assert_equal(absolute.request.query, "q=2")
    assert_equal(absolute.request.scheme, "http")
    var secure_buf = _to_bytes(
        "GET https://example.com/s HTTP/1.1\r\nHost: example.com\r\n\r\n"
    )
    var secure = parse_one(Span(secure_buf), config)
    assert_true(secure.is_complete())
    # Plaintext hop: never report https from the target alone.
    assert_equal(secure.request.scheme, "http")
    var star_buf = _to_bytes("OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n")
    var star = parse_one(Span(star_buf), config)
    assert_true(star.is_complete())
    assert_equal(star.request.path, "*")


def test_absolute_query_only_normalizes_to_root() raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(
        "GET http://example.com?q=1 HTTP/1.1\r\nHost: example.com\r\n\r\n"
    )
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_equal(result.request.authority, "example.com")
    assert_equal(result.request.path, "/")
    assert_equal(result.request.query, "q=1")


def test_fragment_in_target_is_rejected() raises:
    _assert_status("GET /account#admin HTTP/1.1\r\nHost: h\r\n\r\n", 400)
    _assert_status(
        "GET http://example.com/a#frag HTTP/1.1\r\nHost: example.com\r\n\r\n",
        400,
    )


def test_quoted_pair_rejects_bad_escapes() raises:
    # A backslash must quote HTAB / SP / VCHAR / obs-text only: CR,
    # NUL, and DEL after it are rejected like a strict intermediary.
    var bad_cr = _to_bytes(
        "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
        ' chunked\r\n\r\n5;e="a\\\r"\r\nhello\r\n0\r\n\r\n'
    )
    var config = ServerConfig.default()
    var bad_result = parse_one(Span(bad_cr), config)
    assert_true(bad_result.is_error())
    assert_equal(bad_result.error.status, 400)
    var good = _to_bytes(
        "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
        ' chunked\r\n\r\n5;e="a\\"b"\r\nhello\r\n0\r\n\r\n'
    )
    var good_result = parse_one(Span(good), config)
    assert_true(good_result.is_complete())
    assert_equal(len(good_result.request.body), 5)


def test_version_grammar_splits_400_and_505() raises:
    _assert_status("GET /a HTTP/2.0\r\nHost: h\r\n\r\n", 505)
    _assert_status("GET /a HTTP/10.20\r\nHost: h\r\n\r\n", 505)
    _assert_status("GET /a HTTP/foo\r\nHost: h\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1\r\nHost: h\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1x\r\nHost: h\r\n\r\n", 400)
    _assert_status("GET /a HTTP/1.1.1\r\nHost: h\r\n\r\n", 400)


def test_expect_comma_list_all_supported() raises:
    var config = ServerConfig.default()
    var buf = _to_bytes(
        "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length:"
        " 3\r\nExpect: 100-continue, 100-continue\r\n\r\nabc"
    )
    var result = parse_one(Span(buf), config)
    assert_true(result.is_complete())
    assert_true(result.needs_100_continue)
    _assert_status(
        "GET /a HTTP/1.1\r\nHost: h\r\nExpect: 100-continue, close\r\n\r\n",
        417,
    )


def test_dripped_tail_decodes_without_loss() raises:
    # One completed chunk followed by byte-wise drips: slow feeds must
    # neither lose bytes nor change the outcome.
    var config = ServerConfig.default()
    var full = _to_bytes(
        "POST /drip HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
        " chunked\r\n\r\n400\r\n"
    )
    for _ in range(1024):
        full.append(Byte(ord("x")))
    var tail = _to_bytes("\r\n3\r\nabc\r\n0\r\nX-T: 1\r\n\r\n")
    for i in range(len(tail)):
        full.append(tail[i])
    var expected = parse_one(Span(full), config)
    assert_true(expected.is_complete())
    var parser = HttpParser()
    var head_end = len(full) - len(tail)
    var first = List[Byte]()
    for i in range(head_end):
        first.append(full[i])
    parser.feed(Span(first))
    var early = parser.next_result(config)
    assert_true(early.is_need_more())
    var done = False
    for i in range(head_end, len(full)):
        var one = List[Byte]()
        one.append(full[i])
        parser.feed(Span(one))
        var interim = parser.next_result(config)
        if i + 1 < len(full):
            assert_true(interim.is_need_more())
        else:
            assert_true(interim.is_complete())
            assert_equal(len(interim.request.body), len(expected.request.body))
            assert_equal(interim.consumed, expected.consumed)
            done = True
    assert_true(done)


def test_resume_advances_past_completed_chunks() raises:
    # Feed five chunks one at a time through one HttpParser: every
    # intermediate call must report need_more (never a spurious
    # complete or error), and the final call must match the one-shot
    # parse exactly. This exercises prime/resume transitions across
    # feeds rather than one-shot decoding.
    var config = ServerConfig.default()
    var chunks = List[String]()
    chunks.append("1\r\na\r\n")
    chunks.append("2\r\nbc\r\n")
    chunks.append("3\r\ndef\r\n")
    chunks.append("1\r\ng\r\n")
    chunks.append("0\r\n\r\n")
    var full = _to_bytes(
        "POST /r HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    for i in range(len(chunks)):
        var part = _to_bytes(chunks[i])
        for k in range(len(part)):
            full.append(part[k])
    var expected = parse_one(Span(full), config)
    assert_true(expected.is_complete())
    assert_equal(len(expected.request.body), 7)
    var parser = HttpParser()
    var head_raw = _to_bytes(
        "POST /r HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    parser.feed(Span(head_raw))
    var head_only = parser.next_result(config)
    assert_true(head_only.is_need_more())
    for i in range(len(chunks)):
        var part = _to_bytes(chunks[i])
        parser.feed(Span(part))
        var interim = parser.next_result(config)
        if i + 1 < len(chunks):
            assert_true(interim.is_need_more())
        else:
            assert_true(interim.is_complete())
            assert_equal(len(interim.request.body), 7)
            assert_equal(interim.consumed, expected.consumed)


def test_chunk_extension_grammar() raises:
    var config = ServerConfig.default()
    var ext_ok = _to_bytes(
        "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
        " chunked\r\n\r\n5;ext=1\r\nhello\r\n5 ; a = b"
        ' ;c="d;e"\r\nhello\r\n0\r\n\r\n'
    )
    var ok_result = parse_one(Span(ext_ok), config)
    assert_true(ok_result.is_complete())
    assert_equal(len(ok_result.request.body), 10)
    for bad in ["1;", "1;=", "1;=v", "1;a b", '1;a="oops']:
        var raw = _to_bytes(
            String(
                "POST /a HTTP/1.1\r\nHost:"
                " h\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            + bad
            + String("\r\nx\r\n0\r\n\r\n")
        )
        var result = parse_one(Span(raw), config)
        assert_true(result.is_error())
        assert_equal(result.error.status, 400)


def test_bare_chunk_size_rejects_whitespace() raises:
    # Without an extension, the size line is bare hex: surrounding
    # whitespace is malformed framing, not extension padding.
    _assert_status(
        (
            "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\n 5\r\nhello\r\n0\r\n\r\n"
        ),
        400,
    )
    _assert_status(
        (
            "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:"
            " chunked\r\n\r\n5 \r\nhello\r\n0\r\n\r\n"
        ),
        400,
    )


def test_multiple_expect_fields_all_must_agree() raises:
    # A later 100-continue must not whitewash an earlier unsupported
    # expectation, in either order.
    _assert_status(
        (
            "GET /a HTTP/1.1\r\nHost: h\r\nExpect: unsupported\r\nExpect:"
            " 100-continue\r\n\r\n"
        ),
        417,
    )
    _assert_status(
        (
            "GET /a HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\nExpect:"
            " unsupported\r\n\r\n"
        ),
        417,
    )


def test_host_authority_structure() raises:
    for good in [
        "example.com",
        "example.com:8080",
        "127.0.0.1:80",
        "[::1]",
        "[::1]:8080",
        "[fe80::1%25en0]",
    ]:
        var config = ServerConfig.default()
        var raw = _to_bytes(
            String("GET /a HTTP/1.1\r\nHost: ") + good + String("\r\n\r\n")
        )
        var result = parse_one(Span(raw), config)
        assert_true(result.is_complete())
    for bad in [
        "[::1",
        "[::1]extra",
        "user@example.com",
        "example.com:abc",
        "example.com:",
        "2001:db8::1",
        "%zz",
        "%2G",
    ]:
        _assert_status(
            String("GET /a HTTP/1.1\r\nHost: ") + bad + String("\r\n\r\n"),
            400,
        )
    # Backslash and DQUOTE need byte-level construction.
    var backslash_host = _to_bytes("GET /a HTTP/1.1\r\nHost: a")
    backslash_host.append(Byte(92))
    var backslash_tail = _to_bytes("b\r\n\r\n")
    for i in range(len(backslash_tail)):
        backslash_host.append(backslash_tail[i])
    var backslash_result = parse_one(
        Span(backslash_host), ServerConfig.default()
    )
    assert_true(backslash_result.is_error())
    assert_equal(backslash_result.error.status, 400)
    var quote_host = _to_bytes("GET /a HTTP/1.1\r\nHost: ")
    quote_host.append(Byte(34))
    var quote_tail = _to_bytes('x"\r\n\r\n')
    for i in range(len(quote_tail)):
        quote_host.append(quote_tail[i])
    var quote_result = parse_one(Span(quote_host), ServerConfig.default())
    assert_true(quote_result.is_error())
    assert_equal(quote_result.error.status, 400)


def test_expect_and_connection_flags() raises:
    var config = ServerConfig.default()
    var cont_buf = _to_bytes(
        "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nExpect:"
        " 100-continue\r\n\r\nabc"
    )
    var cont = parse_one(Span(cont_buf), config)
    assert_true(cont.is_complete())
    assert_true(cont.needs_100_continue)
    _assert_status(
        "GET /a HTTP/1.1\r\nHost: h\r\nExpect: 100-continue-foo\r\n\r\n",
        417,
    )
    var close_buf = _to_bytes(
        "GET /a HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"
    )
    var close = parse_one(Span(close_buf), config)
    assert_true(close.is_complete())
    assert_true(close.should_close)


def test_incomplete_needs_more_not_success() raises:
    var config = ServerConfig.default()
    var partial_buf = _to_bytes(
        "GET /a HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nabc"
    )
    var partial = parse_one(Span(partial_buf), config)
    assert_true(partial.is_need_more())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
