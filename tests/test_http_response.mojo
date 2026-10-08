from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.error import NetErrorKind
from net.http._buffer import BufferBudget
from net.http import ResponseWriter, has_body_for_status
from net.http._encoder import (
    current_http_date,
    encode_100_continue,
    encode_chunked_start,
    encode_error,
    encode_response,
    http_date,
    _encode_response_budgeted,
    _measure_response,
    _measure_error,
    _encode_error_exact,
    _render_error,
    encode_chunk,
    encode_chunk_end,
    _measure_chunked_start,
    _encode_chunked_start_budgeted,
    _encode_chunk_budgeted,
    _encode_chunk_end_budgeted,
)


def test_stream_wire_exact_capacity_preserves_framing_and_foreign_reservations() raises:
    for status in [100, 200, 204, 205, 304]:
        for is_head in [False, True]:
            var writer = ResponseWriter(32)
            writer.status = status
            writer.should_close = True
            var raw: Array[Byte, 2] = [128, 255]
            writer.headers.add_bytes(String("X-Bin"), Span(raw))
            writer.headers.add_bytes(String("X-Bin"), Span(raw))
            var expected = encode_chunked_start(
                writer, is_head, "date", 100, 32768
            )
            var capacity = _measure_chunked_start(
                writer, is_head, "date", 100, 32768
            )
            assert_equal(capacity, len(expected))
            var budget = BufferBudget(5 + capacity)
            assert_true(budget.try_reserve(5))
            var wire = _encode_chunked_start_budgeted(
                writer, is_head, "date", 100, 32768, budget
            )
            assert_equal(wire.capacity(), capacity)
            assert_equal(budget.used, 5 + capacity)
            for i in range(len(expected)):
                assert_equal(wire[i], expected[i])
            _ = wire^
            budget.release(capacity)
            assert_equal(budget.used, 5)


def test_stream_wire_denial_and_validation_leave_foreign_reservation() raises:
    for invalid in range(4):
        var writer = ResponseWriter(32)
        if invalid == 0:
            writer.headers.add(String("Content-Length"), String("0"))
        elif invalid == 1:
            writer.headers.add(String("Transfer-Encoding"), String("chunked"))
        elif invalid == 2:
            writer.status = 99
        var date = String("date\r\n") if invalid == 3 else String("date")
        var budget = BufferBudget(512)
        assert_true(budget.try_reserve(5))
        var rejected = False
        try:
            _ = _encode_chunked_start_budgeted(
                writer, False, date, 100, 32768, budget
            )
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_true(rejected)
        assert_equal(budget.used, 5)
    var writer = ResponseWriter(32)
    var capacity = _measure_chunked_start(writer, False, "date", 100, 32768)
    var budget = BufferBudget(5 + capacity - 1)
    assert_true(budget.try_reserve(5))
    var rejected = False
    try:
        _ = _encode_chunked_start_budgeted(
            writer, False, "date", 100, 32768, budget
        )
    except:
        rejected = True
    assert_true(rejected)
    assert_equal(budget.used, 5)


def test_chunk_and_end_reserve_exact_wire_before_construction() raises:
    var data = List[Byte](length=256, fill=42)
    for length in [0, 1, 15, 16, 255, 256]:
        var expected = encode_chunk(Span(data)[0:length])
        for admitted in [True, False]:
            var capacity = len(expected)
            var budget = BufferBudget(
                5 + capacity - Int(not admitted and capacity > 0)
            )
            assert_true(budget.try_reserve(5))
            var rejected = False
            var wire = List[Byte]()
            try:
                wire = _encode_chunk_budgeted(Span(data)[0:length], budget)
            except e:
                assert_equal(e.kind, NetErrorKind.invalid_argument())
                rejected = True
            if not rejected:
                assert_equal(wire.capacity(), capacity)
                assert_equal(budget.used, 5 + capacity)
                for i in range(capacity):
                    assert_equal(wire[i], expected[i])
                _ = wire^
                budget.release(capacity)
            assert_equal(rejected, not admitted and capacity > 0)
            assert_equal(budget.used, 5)
    for admitted in [True, False]:
        var budget = BufferBudget(10 - Int(not admitted))
        assert_true(budget.try_reserve(5))
        var rejected = False
        var wire = List[Byte]()
        try:
            wire = _encode_chunk_end_budgeted(budget)
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        if not rejected:
            assert_equal(wire.capacity(), 5)
            assert_equal(String(from_utf8_lossy=Span(wire)), "0\r\n\r\n")
            assert_equal(budget.used, 10)
            _ = wire^
            budget.release(5)
        assert_equal(rejected, not admitted)
        assert_equal(budget.used, 5)


def test_encoder_borrowed_duplicate_obs_text_headers_match_exact_wire() raises:
    var writer = ResponseWriter(32)
    var first: Array[Byte, 3] = [97, 128, 255]
    var second: Array[Byte, 2] = [255, 98]
    writer.headers.add_bytes(String("X-Bin"), Span(first))
    writer.headers.add_bytes(String("X-Bin"), Span(second))
    var value_address = Int(writer.headers._value_bytes_span(0).unsafe_ptr())
    for chunked in [False, True]:
        var expected = List[Byte]()
        expected.extend("HTTP/1.1 200 OK\r\nX-Bin: ".as_bytes())
        expected.extend(Span(first))
        expected.extend("\r\nX-Bin: ".as_bytes())
        expected.extend(Span(second))
        if chunked:
            expected.extend(
                "\r\nDate: date\r\nTransfer-Encoding: chunked\r\n\r\n".as_bytes()
            )
        else:
            expected.extend(
                "\r\nDate: date\r\nContent-Length: 0\r\n\r\n".as_bytes()
            )
        var wire: List[Byte]
        if chunked:
            wire = encode_chunked_start(writer, False, "date", 100, 32768)
        else:
            var capacity = _measure_response(writer, False, "date", 100, 32768)
            assert_equal(capacity, len(expected))
            var budget = BufferBudget(capacity)
            wire = _encode_response_budgeted(
                writer, False, "date", 100, 32768, budget
            )
            assert_equal(wire.capacity(), capacity)
            assert_equal(budget.used, capacity)
        assert_equal(len(wire), len(expected))
        for i in range(len(expected)):
            assert_equal(wire[i], expected[i])
        assert_equal(
            Int(writer.headers._value_bytes_span(0).unsafe_ptr()), value_address
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


def test_error_exact_measure_and_render_preserve_head_close_and_alt_svc() raises:
    for is_head in [False, True]:
        for close in [False, True]:
            for advertised in [False, True]:
                var alt_svc = String(
                    'h3=":8443"; ma=86400'
                ) if advertised else String("")
                var expected = String(
                    "HTTP/1.1 503 Service Unavailable\r\n"
                    "Content-Type: text/plain\r\n"
                    "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"
                    "Content-Length: 23\r\n"
                )
                if close:
                    expected += "Connection: close\r\n"
                if advertised:
                    expected += 'Alt-Svc: h3=":8443"; ma=86400\r\n'
                expected += "\r\n"
                if not is_head:
                    expected += "503 Service Unavailable"
                var capacity = _measure_error(
                    503,
                    close,
                    "Sun, 06 Nov 1994 08:49:37 GMT",
                    is_head,
                    alt_svc,
                )
                assert_equal(capacity, expected.byte_length())
                var exact = _encode_error_exact(
                    503,
                    close,
                    "Sun, 06 Nov 1994 08:49:37 GMT",
                    capacity,
                    is_head,
                    alt_svc,
                )
                var public = encode_error(
                    503,
                    close,
                    "Sun, 06 Nov 1994 08:49:37 GMT",
                    is_head,
                    alt_svc,
                )
                var prepaid_capacity = 256 + (
                    11 + alt_svc.byte_length() if advertised else 0
                )
                var prepaid = List[Byte](capacity=prepaid_capacity)
                var address = Int(prepaid.unsafe_ptr())
                var byte_count = 0
                _render_error[False](
                    503,
                    close,
                    "Sun, 06 Nov 1994 08:49:37 GMT",
                    is_head,
                    alt_svc,
                    prepaid,
                    byte_count,
                )
                assert_equal(prepaid.capacity(), prepaid_capacity)
                assert_equal(Int(prepaid.unsafe_ptr()), address)
                assert_equal(_bytes_to_string(Span(prepaid)), expected)
                assert_equal(exact.capacity(), capacity)
                assert_equal(public.capacity(), capacity)
                assert_equal(_bytes_to_string(Span(exact)), expected)
                assert_equal(_bytes_to_string(Span(public)), expected)


def test_error_encoding_is_bounded() raises:
    var wire = encode_error(400, True, "Thu, 01 Jan 1970 00:00:00 GMT")
    var text = _bytes_to_string(Span(wire))
    assert_true(text.startswith("HTTP/1.1 400 Bad Request\r\n"))
    assert_true(text.find("Connection: close\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\n400 Bad Request"))


def _assert_scratch_wire(
    writer: ResponseWriter,
    chunked: Bool,
    is_head: Bool,
    date: StringSlice,
    expected: StringSlice,
) raises:
    var capacity = _measure_chunked_start(
        writer, is_head, date, 100, 32768
    ) if chunked else _measure_response(writer, is_head, date, 100, 32768)
    assert_equal(capacity, expected.byte_length())
    for admitted in [False, True]:
        var budget = BufferBudget(5 + capacity - Int(not admitted))
        assert_true(budget.try_reserve(5))
        var rejected = False
        var wire = List[Byte]()
        try:
            if chunked:
                wire = _encode_chunked_start_budgeted(
                    writer, is_head, date, 100, 32768, budget
                )
            else:
                wire = _encode_response_budgeted(
                    writer, is_head, date, 100, 32768, budget
                )
        except error:
            assert_equal(error.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_equal(rejected, not admitted)
        if admitted:
            assert_equal(wire.capacity(), capacity)
            assert_equal(budget.used, 5 + capacity)
            assert_equal(_bytes_to_string(Span(wire)), expected)
            _ = wire^
            budget.release(capacity)
        assert_equal(budget.used, 5)


def test_long_mixed_case_name_and_date_preserve_exact_framing() raises:
    var name = String("X-")
    var date = String("date-")
    for _ in range(256):
        name += "Ab"
        date += "d"
    for chunked in [False, True]:
        for is_head in [False, True]:
            var writer = ResponseWriter(32)
            writer.headers.add(name.copy(), String("value"))
            writer.write_string("ok")
            var expected = String("HTTP/1.1 200 OK\r\n")
            expected += name + ": value\r\nDate: " + date + "\r\n"
            expected += "Transfer-Encoding: chunked\r\n\r\n" if chunked else (
                "Content-Length: 2\r\n\r\n"
            )
            if not chunked and not is_head:
                expected += "ok"
            _assert_scratch_wire(writer, chunked, is_head, date, expected)


def test_empty_existing_date_preserves_presence_and_skips_unused_date() raises:
    for chunked in [False, True]:
        var writer = ResponseWriter(32)
        writer.headers.add(String("dAtE"), String(""))
        var expected = String("HTTP/1.1 200 OK\r\ndAtE: \r\n")
        expected += "Transfer-Encoding: chunked\r\n\r\n" if chunked else (
            "Content-Length: 0\r\n\r\n"
        )
        _assert_scratch_wire(writer, chunked, False, "unused\r\n", expected)


def test_connection_first_raw_token_boundaries_preserve_close_decision() raises:
    for variant in range(6):
        var raw = List[Byte]()
        var token: String
        if variant == 0:
            token = String("keep-alive, \tClOsE \t,,")
        elif variant == 1:
            token = String("x-close, close-ended")
            for _ in range(256):
                token += "x"
        elif variant == 2:
            raw.append(128)
            token = String("close")
        elif variant == 3:
            token = String("keep-alive")
        elif variant == 4:
            token = String("close")
        else:
            token = String("CLOſE")
        for byte in token.as_bytes():
            raw.append(byte)
        for chunked in [False, True]:
            var writer = ResponseWriter(32)
            writer.should_close = True
            writer.headers.add_bytes(String("cOnNeCtIoN"), Span(raw))
            if variant == 3:
                writer.headers.add(String("Connection"), String("close"))
            elif variant == 4:
                writer.headers.add(String("Connection"), String("x-close"))
            var expected = List[Byte]()
            for byte in String("HTTP/1.1 200 OK\r\ncOnNeCtIoN: ").as_bytes():
                expected.append(byte)
            for byte in raw:
                expected.append(byte)
            var suffix = String("\r\n")
            if variant == 3:
                suffix += "Connection: close\r\n"
            elif variant == 4:
                suffix += "Connection: x-close\r\n"
            suffix += "Date: date\r\n"
            suffix += "Transfer-Encoding: chunked\r\n" if chunked else (
                "Content-Length: 0\r\n"
            )
            if variant != 0 and variant != 4:
                suffix += "Connection: close\r\n"
            suffix += "\r\n"
            for byte in suffix.as_bytes():
                expected.append(byte)
            var measured = _measure_chunked_start(
                writer, False, "date", 100, 32768
            ) if chunked else _measure_response(
                writer, False, "date", 100, 32768
            )
            assert_equal(measured, len(expected))
            var wire = encode_chunked_start(
                writer, False, "date", 100, 32768
            ) if chunked else encode_response(writer, False, "date", 100, 32768)
            assert_equal(len(wire), len(expected))
            for i in range(len(expected)):
                assert_equal(wire[i], expected[i])


def test_content_length_first_value_leading_zero_and_no_body_rules() raises:
    var zeros = String("")
    for _ in range(1024):
        zeros += "0"
    for is_head in [False, True]:
        var writer = ResponseWriter(32)
        writer.headers.add(String("cOnTeNt-LeNgTh"), zeros + "2")
        writer.headers.add(String("Content-Length"), String("invalid later"))
        writer.write_string("ok")
        var expected = String(
            "HTTP/1.1 200 OK\r\nDate: date\r\nContent-Length: 2\r\n\r\n"
        )
        if not is_head:
            expected += "ok"
        _assert_scratch_wire(writer, False, is_head, "date", expected)
    var no_body = ResponseWriter(32)
    no_body.status = 204
    no_body.headers.add(String("Content-Length"), String("invalid first"))
    _assert_scratch_wire(
        no_body,
        False,
        False,
        "date",
        "HTTP/1.1 204 Unknown\r\nDate: date\r\n\r\n",
    )


def test_empty_presence_and_content_length_errors_preserve_validation_order() raises:
    for variant in range(9):
        var writer = ResponseWriter(32)
        writer.write_string("ok")
        var raw: Array[Byte, 1] = [255]
        if variant == 0:
            writer.headers.add(String("Content-Length"), String(""))
        elif variant == 1:
            writer.headers.add_bytes(String("Content-Length"), Span(raw))
        elif variant == 2:
            writer.headers.add(
                String("Content-Length"), String("999999999999999999999999999")
            )
        elif variant == 8:
            writer.headers.add(String("Content-Length"), String("bad"))
            writer.headers.add(String("Content-Length"), String("2"))
        else:
            writer.headers.add(String("Content-Length"), String("bad"))
            writer.headers.add(String("Transfer-Encoding"), String(""))
        var expected = String("Content-Length is invalid")
        var max_headers = 100
        var max_bytes = 32768
        var chunked = variant == 6 or variant == 7
        if variant == 2:
            expected = String("Content-Length does not match body")
        elif variant == 3:
            max_headers = 1
            expected = String("too many response headers")
        elif variant == 4:
            max_bytes = 0
            expected = String("response headers too large")
        elif variant == 5:
            expected = String("Transfer-Encoding is not supported on responses")
        elif chunked:
            if variant == 7:
                writer.headers.clear()
                writer.headers.add(String("Transfer-Encoding"), String(""))
                expected = String(
                    "Transfer-Encoding header is managed by chunked encoder"
                )
            else:
                writer.headers.clear()
                writer.headers.add(String("Content-Length"), String(""))
                writer.headers.add(String("Transfer-Encoding"), String(""))
                expected = String(
                    "Content-Length is not permitted with chunked"
                    " Transfer-Encoding"
                )
        var budget = BufferBudget(4096)
        assert_true(budget.try_reserve(5))
        var rejected = False
        try:
            if chunked:
                _ = _encode_chunked_start_budgeted(
                    writer, False, "date", max_headers, max_bytes, budget
                )
            else:
                _ = _encode_response_budgeted(
                    writer, False, "date", max_headers, max_bytes, budget
                )
        except error:
            assert_equal(error.kind, NetErrorKind.invalid_argument())
            assert_equal(error.message, expected)
            rejected = True
        assert_true(rejected)
        assert_equal(budget.used, 5)


def test_error_long_date_and_alt_svc_measure_exact_prepaid_head_wire() raises:
    var date = String("date-")
    var alt = String('h3=":8443"; note="')
    for _ in range(512):
        date += "d"
        alt += "a"
    alt += '"'
    for is_head in [False, True]:
        var expected = (
            String(
                "HTTP/1.1 503 Service Unavailable\r\nContent-Type:"
                " text/plain\r\nDate: "
            )
            + date
            + "\r\nContent-Length: 23\r\nConnection: close\r\nAlt-Svc: "
            + alt
            + "\r\n\r\n"
        )
        if not is_head:
            expected += "503 Service Unavailable"
        var capacity = _measure_error(503, True, date, is_head, alt)
        assert_equal(capacity, expected.byte_length())
        var prepaid = List[Byte](capacity=capacity)
        var address = Int(prepaid.unsafe_ptr())
        var byte_count = 0
        _render_error[False](503, True, date, is_head, alt, prepaid, byte_count)
        assert_equal(prepaid.capacity(), capacity)
        assert_equal(Int(prepaid.unsafe_ptr()), address)
        assert_equal(_bytes_to_string(Span(prepaid)), expected)


def test_trailers_switch_response_to_chunked_with_trailer_header() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Content-Type"), String("text/plain"))
    writer.write_string("hello")
    writer.add_trailer(String("X-Checksum"), String("abc"))
    writer.add_trailer(String("X-Count"), String("1"))
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Transfer-Encoding: chunked\r\n") >= 0)
    assert_true(text.find("Trailer: X-Checksum, X-Count\r\n") >= 0)
    assert_true(text.find("Content-Length") < 0)
    assert_true(
        text.endswith(
            "\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: abc\r\nX-Count: 1\r\n\r\n"
        )
    )


def test_trailers_empty_body_still_emits_zero_chunk_and_trailers() raises:
    var writer = ResponseWriter(1024)
    writer.add_trailer(String("X-Checksum"), String("abc"))
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = _bytes_to_string(Span(wire))
    assert_true(text.find("Transfer-Encoding: chunked\r\n") >= 0)
    assert_true(text.find("Trailer: X-Checksum\r\n") >= 0)
    assert_true(text.endswith("\r\n\r\n0\r\nX-Checksum: abc\r\n\r\n"))


def test_trailers_dropped_on_head_and_no_body_statuses() raises:
    for scenario in range(4):
        var writer = ResponseWriter(1024)
        var is_head = False
        if scenario == 0:
            is_head = True
            writer.write_string("hello")
        else:
            var statuses = [204, 205, 304]
            writer.set_status(statuses[scenario - 1])
        writer.add_trailer(String("X-Checksum"), String("abc"))
        var wire = encode_response(
            writer, is_head, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
        )
        var text = _bytes_to_string(Span(wire))
        assert_true(text.find("Transfer-Encoding: chunked") < 0)
        assert_true(text.find("Trailer:") < 0)
        assert_true(text.find("X-Checksum") < 0)
        assert_true(text.endswith("\r\n\r\n"))


def test_add_trailer_rejects_forbidden_names() raises:
    var forbidden: List[String] = [
        String("Content-Length"),
        String("Transfer-Encoding"),
        String("Trailer"),
        String("Content-Type"),
        String("Host"),
        String("Connection"),
        String("Authorization"),
        String("WWW-Authenticate"),
        String("Proxy-Authenticate"),
        String("Cache-Control"),
        String("Vary"),
        String("Set-Cookie"),
        String("Age"),
        String("Expires"),
        String("Pragma"),
    ]
    for name in forbidden:
        var writer = ResponseWriter(32)
        var rejected = False
        try:
            writer.add_trailer(name.copy(), String("value"))
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_true(rejected)
        assert_equal(len(writer.trailers), 0)


def test_add_trailer_rejects_crlf_and_control_bytes() raises:
    var writer = ResponseWriter(32)
    var rejected = False
    try:
        writer.add_trailer(String("X-Name"), String("value\r\n"))
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)
    assert_equal(len(writer.trailers), 0)
    var rejected2 = False
    try:
        writer.add_trailer(String("Bad\r\nName"), String("value"))
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_argument())
        rejected2 = True
    assert_true(rejected2)


def test_trailers_reject_caller_content_length_and_trailer_header() raises:
    for scenario in range(2):
        var writer = ResponseWriter(32)
        writer.write_string("hello")
        if scenario == 0:
            writer.headers.add(String("Content-Length"), String("5"))
        else:
            writer.headers.add(String("Trailer"), String("X-Checksum"))
        writer.add_trailer(String("X-Checksum"), String("abc"))
        var rejected = False
        try:
            _ = encode_response(writer, False, "date", 100, 32768)
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_true(rejected)


def test_trailers_count_against_header_byte_budget() raises:
    var writer = ResponseWriter(32)
    writer.write_string("hello")
    writer.add_trailer(String("X-Long"), String("x" * 2000))
    var rejected = False
    try:
        _ = encode_response(writer, False, "date", 100, 100)
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)


def test_trailers_combined_count_matches_header_budget() raises:
    var writer = ResponseWriter(1024)
    writer.write_string("hello")
    writer.headers.add(String("X-A"), String("1"))
    writer.headers.add(String("X-B"), String("2"))
    writer.add_trailer(String("X-C"), String("3"))
    writer.add_trailer(String("X-D"), String("4"))
    var rejected = False
    try:
        _ = encode_response(writer, False, "date", 3, 32768)
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)


def test_trailers_wire_capacity_exact_matches_measure() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Content-Type"), String("text/plain"))
    writer.write_string("hello")
    writer.add_trailer(String("X-Checksum"), String("abc"))
    var expected = encode_response(writer, False, "date", 100, 32768)
    var capacity = _measure_response(writer, False, "date", 100, 32768)
    assert_equal(capacity, len(expected))
    var budget = BufferBudget(1024)
    assert_true(budget.try_reserve(writer.body.capacity()))
    var wire = _encode_response_budgeted(
        writer, False, "date", 100, 32768, budget
    )
    assert_equal(len(wire), capacity)
    for i in range(len(expected)):
        assert_equal(wire[i], expected[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
