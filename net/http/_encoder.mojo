"""Wire encoder for HTTP/1.1 responses (Phase 1, socket-independent).

`ResponseWriter` stays buffered and socket-free; this module renders it
to bytes. Framing rules live here so HEAD / 204 / 304 handling cannot
drift between call sites.
"""

from std.ffi import c_long, external_call

from net.error import NetError, NetErrorKind

from ._buffer import _CapacityBudget
from .error import _status_reason
from .response import ResponseWriter, has_body_for_status


def _civil_from_days(z: Int) -> Tuple[Int, Int, Int]:
    var zz = z + 719468
    var era = zz // 146097
    if zz < 0 and zz % 146097 != 0:
        era -= 1
    var doe = zz - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return y, m, d


def _weekday_name(wday: Int) -> String:
    if wday == 0:
        return "Sun"
    if wday == 1:
        return "Mon"
    if wday == 2:
        return "Tue"
    if wday == 3:
        return "Wed"
    if wday == 4:
        return "Thu"
    if wday == 5:
        return "Fri"
    return "Sat"


def _month_name(m: Int) -> String:
    if m == 1:
        return "Jan"
    if m == 2:
        return "Feb"
    if m == 3:
        return "Mar"
    if m == 4:
        return "Apr"
    if m == 5:
        return "May"
    if m == 6:
        return "Jun"
    if m == 7:
        return "Jul"
    if m == 8:
        return "Aug"
    if m == 9:
        return "Sep"
    if m == 10:
        return "Oct"
    if m == 11:
        return "Nov"
    return "Dec"


def http_date(timestamp: Int) -> String:
    """Formats a Unix timestamp as an IMF-fixdate (`Sun, 06 Nov 1994
    08:49:37 GMT`). Pure arithmetic, no libc calendar call, and no
    heap tables on the hot path."""
    var days = timestamp // 86400
    var secs = timestamp % 86400
    var hh = secs // 3600
    var mm = (secs % 3600) // 60
    var ss = secs % 60
    var y, m, d = _civil_from_days(days)
    var wday = (days + 4) % 7
    if wday < 0:
        wday += 7
    var out = _weekday_name(wday) + ", "
    if d < 10:
        out += "0"
    out += String(d) + " " + _month_name(m) + " " + String(y) + " "
    if hh < 10:
        out += "0"
    out += String(hh) + ":"
    if mm < 10:
        out += "0"
    out += String(mm) + ":"
    if ss < 10:
        out += "0"
    out += String(ss) + " GMT"
    return out^


def current_http_date() -> String:
    var timestamp = Int(
        external_call["time", c_long](
            Optional[Pointer[c_long, MutUntrackedOrigin]](None)
        )
    )
    return http_date(timestamp)


def _append_string(mut out: List[Byte], data: StringSlice):
    var bytes = data.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])


def _reject_response_injection(
    name: StringSlice, value: StringSlice
) raises NetError:
    var name_bytes = name.as_bytes()
    for i in range(len(name_bytes)):
        if name_bytes[i] == Byte(ord("\r")) or name_bytes[i] == Byte(ord("\n")):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "encode response",
                None,
                "response header contains CR or LF",
            )
    var value_bytes = value.as_bytes()
    for i in range(len(value_bytes)):
        if value_bytes[i] == Byte(ord("\r")) or value_bytes[i] == Byte(
            ord("\n")
        ):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "encode response",
                None,
                "response header contains CR or LF",
            )


def _has_close_token(value: StringSlice) -> Bool:
    # `Connection` is a comma-separated token list: only a whole,
    # case-insensitive `close` token counts, so `x-close` or
    # `close-ended` must not suppress the real header.
    var bytes = value.as_bytes()
    var start = 0
    for i in range(len(bytes) + 1):
        if i == len(bytes) or bytes[i] == Byte(ord(",")):
            var lo = start
            var hi = i
            while lo < hi and (
                bytes[lo] == Byte(ord(" ")) or bytes[lo] == Byte(ord("\t"))
            ):
                lo += 1
            while hi > lo and (
                bytes[hi - 1] == Byte(ord(" "))
                or bytes[hi - 1] == Byte(ord("\t"))
            ):
                hi -= 1
            if String(from_utf8_lossy=bytes[lo:hi]).lower() == "close":
                return True
            start = i + 1
    return False


def _append_response_bytes[
    measure: Bool, origin: ImmOrigin
](mut out: List[Byte], data: Span[Byte, origin], mut byte_count: Int):
    comptime if measure:
        byte_count += len(data)
    else:
        for i in range(len(data)):
            out.append(data[i])


def _append_response_string[
    measure: Bool
](mut out: List[Byte], data: StringSlice, mut byte_count: Int):
    _append_response_bytes[measure](out, data.as_bytes(), byte_count)


def _render_response[
    measure: Bool
](
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
    mut out: List[Byte],
    mut byte_count: Int,
) raises NetError:
    if writer.status < 100 or writer.status > 999:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode response",
            None,
            "response status is not a three-digit code",
        )
    if len(writer.headers) > max_headers:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode response",
            None,
            "too many response headers",
        )
    var header_bytes = 0
    for i in range(len(writer.headers)):
        header_bytes += writer.headers.name_at(i).byte_length()
        header_bytes += writer.headers.value_byte_length(i)
        header_bytes += 4
    if header_bytes > max_bytes:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode response",
            None,
            "response headers too large",
        )
    var send_body = has_body_for_status(writer.status, is_head)
    # HEAD omits body bytes but keeps the GET-equivalent length.
    # 1xx / 204 / 205 / 304 omit both length and bytes.
    var wire_length = -1
    if writer.status < 100 or writer.status > 199:
        if (
            writer.status != 204
            and writer.status != 205
            and writer.status != 304
        ):
            wire_length = len(writer.body)
    # Validate a caller-supplied Content-Length against the framed length.
    # For HEAD the framed length is the GET-equivalent body length.
    # For 1xx/204/205/304 there is no framed length; a caller value is
    # dropped.
    # A caller-supplied Transfer-Encoding is always rejected: this server
    # sends buffered responses with a known length, so emitting both
    # would create a request/response smuggling vector (RFC 9112 6.1).
    if writer.headers.get_first("Transfer-Encoding"):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode response",
            None,
            "Transfer-Encoding is not supported on responses",
        )
    var declared = writer.headers.get_first("Content-Length")
    if declared and wire_length >= 0:
        var text = declared.value()
        var parsed = 0
        var digits = text.as_bytes()
        if len(digits) == 0:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "encode response",
                None,
                "Content-Length is invalid",
            )
        for i in range(len(digits)):
            var byte = digits[i]
            if byte < Byte(ord("0")) or byte > Byte(ord("9")):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "encode response",
                    None,
                    "Content-Length is invalid",
                )
            parsed = parsed * 10 + Int(byte - Byte(ord("0")))
            if parsed > wire_length:
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "encode response",
                    None,
                    "Content-Length does not match body",
                )
        if parsed != wire_length:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "encode response",
                None,
                "Content-Length does not match body",
            )
    _append_response_string[measure](
        out,
        String("HTTP/1.1 ")
        + String(writer.status)
        + String(" ")
        + _status_reason(writer.status)
        + String("\r\n"),
        byte_count,
    )
    for i in range(len(writer.headers)):
        var name = writer.headers.name_at(i)
        var value_bytes = writer.headers._value_bytes_span(i)
        # Skip a caller Content-Length on no-body responses; it is
        # re-derived below for framed bodies only.
        if name.lower() == "content-length":
            continue
        # Values were validated at ingress, but the encoder is the last
        # line before the wire: reject CR/LF here on the exact bytes
        # being emitted (names are ASCII tokens by construction).
        var name_bytes = name.as_bytes()
        for k in range(len(name_bytes)):
            if name_bytes[k] == Byte(ord("\r")) or name_bytes[k] == Byte(
                ord("\n")
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "encode response",
                    None,
                    "response header contains CR or LF",
                )
        for k in range(len(value_bytes)):
            if value_bytes[k] == Byte(ord("\r")) or value_bytes[k] == Byte(
                ord("\n")
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "encode response",
                    None,
                    "response header contains CR or LF",
                )
        _append_response_string[measure](out, name + String(": "), byte_count)
        _append_response_bytes[measure](out, value_bytes, byte_count)
        _append_response_string[measure](out, String("\r\n"), byte_count)
    if not writer.headers.get_first("Date"):
        _reject_response_injection("Date", date)
        _append_response_string[measure](
            out, String("Date: ") + String(date) + String("\r\n"), byte_count
        )
    if wire_length >= 0:
        _append_response_string[measure](
            out,
            String("Content-Length: ") + String(wire_length) + String("\r\n"),
            byte_count,
        )
    if writer.should_close:
        var connection = writer.headers.get_first("Connection")
        var has_close = False
        if connection:
            has_close = _has_close_token(connection.value())
        if not has_close:
            _append_response_string[measure](
                out, String("Connection: close\r\n"), byte_count
            )
    _append_response_string[measure](out, String("\r\n"), byte_count)
    if send_body:
        _append_response_bytes[measure](out, Span(writer.body), byte_count)


def encode_response(
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
) raises NetError -> List[Byte]:
    """Renders a buffered response with explicit `Date` (tests pin it;
    servers pass `current_http_date()`).

    Response header count and bytes are enforced here so every encoder
    user, not just the server loop, honors the advertised bounds.
    """
    var out = List[Byte]()
    var byte_count = 0
    _render_response[False](
        writer, is_head, date, max_headers, max_bytes, out, byte_count
    )
    return out^


def _measure_response(
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
) raises NetError -> Int:
    var out = List[Byte]()
    var byte_count = 0
    _render_response[True](
        writer, is_head, date, max_headers, max_bytes, out, byte_count
    )
    return byte_count


def _encode_response_budgeted[
    B: _CapacityBudget
](
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
    mut budget: B,
) raises NetError -> List[Byte]:
    var capacity = _measure_response(
        writer, is_head, date, max_headers, max_bytes
    )
    if not budget.try_reserve(capacity):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode response",
            None,
            "response wire capacity exceeds budget",
        )
    var out = List[Byte](capacity=capacity)
    var byte_count = 0
    try:
        _render_response[False](
            writer, is_head, date, max_headers, max_bytes, out, byte_count
        )
    except e:
        _ = out^
        budget.release(capacity)
        raise e^
    return out^


def encode_100_continue() -> List[Byte]:
    var out = List[Byte]()
    _append_string(out, String("HTTP/1.1 100 Continue\r\n\r\n"))
    return out^


def _render_error[
    measure: Bool
](
    status: Int,
    should_close: Bool,
    date: StringSlice,
    is_head: Bool,
    alt_svc: StringSlice,
    mut out: List[Byte],
    mut byte_count: Int,
):
    var reason = _status_reason(status)
    var body = String(status) + String(" ") + reason
    _append_response_string[measure](
        out,
        String("HTTP/1.1 ")
        + String(status)
        + String(" ")
        + reason
        + String("\r\n"),
        byte_count,
    )
    _append_response_string[measure](
        out, "Content-Type: text/plain\r\n", byte_count
    )
    _append_response_string[measure](
        out, String("Date: ") + String(date) + String("\r\n"), byte_count
    )
    _append_response_string[measure](
        out,
        String("Content-Length: ")
        + String(body.byte_length())
        + String("\r\n"),
        byte_count,
    )
    if should_close:
        _append_response_string[measure](
            out, "Connection: close\r\n", byte_count
        )
    if alt_svc.byte_length() > 0:
        _append_response_string[measure](
            out,
            String("Alt-Svc: ") + String(alt_svc) + String("\r\n"),
            byte_count,
        )
    _append_response_string[measure](out, "\r\n", byte_count)
    if not is_head:
        _append_response_string[measure](out, body, byte_count)


def _measure_error(
    status: Int,
    should_close: Bool,
    date: StringSlice,
    is_head: Bool = False,
    alt_svc: StringSlice = "",
) -> Int:
    var out = List[Byte]()
    var byte_count = 0
    _render_error[True](
        status, should_close, date, is_head, alt_svc, out, byte_count
    )
    return byte_count


def _encode_error_exact(
    status: Int,
    should_close: Bool,
    date: StringSlice,
    capacity: Int,
    is_head: Bool = False,
    alt_svc: StringSlice = "",
) -> List[Byte]:
    var out = List[Byte](capacity=capacity)
    var byte_count = 0
    _render_error[False](
        status, should_close, date, is_head, alt_svc, out, byte_count
    )
    return out^


def encode_error(
    status: Int,
    should_close: Bool,
    date: StringSlice,
    is_head: Bool = False,
    alt_svc: StringSlice = "",
) -> List[Byte]:
    """Encodes an error response with a fixed small body."""
    var capacity = _measure_error(status, should_close, date, is_head, alt_svc)
    return _encode_error_exact(
        status, should_close, date, capacity, is_head, alt_svc
    )


def _append_hex(mut out: List[Byte], val: Int):
    if val <= 0:
        out.append(Byte(ord("0")))
        return
    # Emitted most-significant nibble first so no scratch buffer is needed.
    # (`InlineArray` was removed after Mojo 1.0.)
    var digits = 0
    var probe = val
    while probe > 0:
        digits += 1
        probe = probe >> 4
    for i in range(digits):
        var shift = (digits - 1 - i) * 4
        var rem = (val >> shift) & 0xF
        if rem < 10:
            out.append(Byte(ord("0") + rem))
        else:
            out.append(Byte(ord("a") + rem - 10))


def _render_chunked_start[
    measure: Bool
](
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
    mut out: List[Byte],
    mut byte_count: Int,
) raises NetError:
    if writer.status < 100 or writer.status > 999:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunked start",
            None,
            "response status is not a three-digit code",
        )
    if len(writer.headers) > max_headers:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunked start",
            None,
            "too many response headers",
        )
    var header_bytes = 0
    for i in range(len(writer.headers)):
        header_bytes += writer.headers.name_at(i).byte_length()
        header_bytes += writer.headers.value_byte_length(i)
        header_bytes += 4
    if header_bytes > max_bytes:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunked start",
            None,
            "response headers too large",
        )
    if writer.headers.get_first("Content-Length"):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunked start",
            None,
            "Content-Length is not permitted with chunked Transfer-Encoding",
        )
    if writer.headers.get_first("Transfer-Encoding"):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunked start",
            None,
            "Transfer-Encoding header is managed by chunked encoder",
        )

    var emit_transfer_encoding = True
    if (
        (writer.status >= 100 and writer.status <= 199)
        or writer.status == 204
        or writer.status == 205
        or writer.status == 304
    ):
        emit_transfer_encoding = False

    _append_response_string[measure](
        out,
        String("HTTP/1.1 ")
        + String(writer.status)
        + String(" ")
        + _status_reason(writer.status)
        + String("\r\n"),
        byte_count,
    )
    for i in range(len(writer.headers)):
        var name = writer.headers.name_at(i)
        var value_bytes = writer.headers._value_bytes_span(i)
        var name_bytes = name.as_bytes()
        for k in range(len(name_bytes)):
            if name_bytes[k] == Byte(ord("\r")) or name_bytes[k] == Byte(
                ord("\n")
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "encode chunked start",
                    None,
                    "response header contains CR or LF",
                )
        for k in range(len(value_bytes)):
            if value_bytes[k] == Byte(ord("\r")) or value_bytes[k] == Byte(
                ord("\n")
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "encode chunked start",
                    None,
                    "response header contains CR or LF",
                )
        _append_response_string[measure](out, name + String(": "), byte_count)
        _append_response_bytes[measure](out, value_bytes, byte_count)
        _append_response_string[measure](out, "\r\n", byte_count)

    if not writer.headers.get_first("Date"):
        _reject_response_injection("Date", date)
        _append_response_string[measure](
            out, String("Date: ") + String(date) + String("\r\n"), byte_count
        )

    if emit_transfer_encoding:
        _append_response_string[measure](
            out, "Transfer-Encoding: chunked\r\n", byte_count
        )

    if writer.should_close:
        var connection = writer.headers.get_first("Connection")
        var has_close = False
        if connection:
            has_close = _has_close_token(connection.value())
        if not has_close:
            _append_response_string[measure](
                out, "Connection: close\r\n", byte_count
            )

    _append_response_string[measure](out, "\r\n", byte_count)


def _measure_chunked_start(
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
) raises NetError -> Int:
    var scratch = List[Byte]()
    var byte_count = 0
    _render_chunked_start[True](
        writer, is_head, date, max_headers, max_bytes, scratch, byte_count
    )
    return byte_count


def encode_chunked_start(
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
) raises NetError -> List[Byte]:
    """Renders the status line and headers for a chunked response.

    Framing rules:
    - Status must be a 3-digit code (100-999).
    - Content-Length is prohibited with chunked transfer coding (RFC 9112 §6.1).
    - Transfer-Encoding header is managed by this encoder; caller-supplied is rejected.
    - Status 1xx, 204, 205, 304 omit Transfer-Encoding: chunked.
    - HEAD advertises Transfer-Encoding: chunked (if status allows body) but omits chunk bodies.
    """
    var capacity = _measure_chunked_start(
        writer, is_head, date, max_headers, max_bytes
    )
    var out = List[Byte](capacity=capacity)
    var byte_count = 0
    _render_chunked_start[False](
        writer, is_head, date, max_headers, max_bytes, out, byte_count
    )
    return out^


def _encode_chunked_start_budgeted[
    B: _CapacityBudget
](
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_headers: Int,
    max_bytes: Int,
    mut budget: B,
) raises NetError -> List[Byte]:
    var capacity = _measure_chunked_start(
        writer, is_head, date, max_headers, max_bytes
    )
    if not budget.try_reserve(capacity):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunked start",
            None,
            "stream wire capacity exceeds budget",
        )
    var out = List[Byte](capacity=capacity)
    var byte_count = 0
    try:
        _render_chunked_start[False](
            writer, is_head, date, max_headers, max_bytes, out, byte_count
        )
    except e:
        _ = out^
        budget.release(capacity)
        raise e^
    return out^


def _chunk_wire_size(length: Int) -> Int:
    if length == 0:
        return 0
    var digits = 1
    var remaining = length >> 4
    while remaining > 0:
        digits += 1
        remaining >>= 4
    return digits + 2 + length + 2


def encode_chunk[origin: ImmOrigin](data: Span[Byte, origin]) -> List[Byte]:
    """Encodes a single chunk with hex length prefix and CRLF delimiters."""
    var out = List[Byte](capacity=_chunk_wire_size(len(data)))
    if len(data) == 0:
        return out^
    _append_hex(out, len(data))
    out.append(Byte(ord("\r")))
    out.append(Byte(ord("\n")))
    for i in range(len(data)):
        out.append(data[i])
    out.append(Byte(ord("\r")))
    out.append(Byte(ord("\n")))
    return out^


def encode_chunk_end() -> List[Byte]:
    """Encodes the terminal 0-length chunk marking the end of chunked body."""
    var out = List[Byte]()
    out.reserve(5)
    out.append(Byte(ord("0")))
    out.append(Byte(ord("\r")))
    out.append(Byte(ord("\n")))
    out.append(Byte(ord("\r")))
    out.append(Byte(ord("\n")))
    return out^


def _encode_chunk_budgeted[
    B: _CapacityBudget, origin: ImmOrigin
](data: Span[Byte, origin], mut budget: B) raises NetError -> List[Byte]:
    var capacity = _chunk_wire_size(len(data))
    if not budget.try_reserve(capacity):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunk",
            None,
            "stream wire capacity exceeds budget",
        )
    return encode_chunk(data)


def _encode_chunk_end_budgeted[
    B: _CapacityBudget
](mut budget: B) raises NetError -> List[Byte]:
    if not budget.try_reserve(5):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "encode chunk end",
            None,
            "stream wire capacity exceeds budget",
        )
    return encode_chunk_end()
