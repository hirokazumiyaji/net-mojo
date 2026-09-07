"""Wire encoder for HTTP/1.1 responses (Phase 1, socket-independent).

`ResponseWriter` stays buffered and socket-free; this module renders it
to bytes. Framing rules live here so HEAD / 204 / 304 handling cannot
drift between call sites.
"""

from std.ffi import c_long, external_call

from net.error import NetError, NetErrorKind

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


def http_date(timestamp: Int) -> String:
    """Formats a Unix timestamp as an IMF-fixdate (`Sun, 06 Nov 1994
    08:49:37 GMT`). Pure arithmetic, no libc calendar call."""
    var days = timestamp // 86400
    var secs = timestamp % 86400
    var hh = secs // 3600
    var mm = (secs % 3600) // 60
    var ss = secs % 60
    var y, m, d = _civil_from_days(days)
    var wday = (days + 4) % 7
    if wday < 0:
        wday += 7
    var wdays = List[String]()
    wdays.append("Sun")
    wdays.append("Mon")
    wdays.append("Tue")
    wdays.append("Wed")
    wdays.append("Thu")
    wdays.append("Fri")
    wdays.append("Sat")
    var months = List[String]()
    months.append("Jan")
    months.append("Feb")
    months.append("Mar")
    months.append("Apr")
    months.append("May")
    months.append("Jun")
    months.append("Jul")
    months.append("Aug")
    months.append("Sep")
    months.append("Oct")
    months.append("Nov")
    months.append("Dec")
    var out = String(wdays[wday]) + ", "
    if d < 10:
        out += "0"
    out += String(d) + " " + String(months[m - 1]) + " " + String(y) + " "
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


def encode_response(
    writer: ResponseWriter, is_head: Bool, date: StringSlice
) raises NetError -> List[Byte]:
    """Renders a buffered response with explicit `Date` (tests pin it;
    servers pass `current_http_date()`)."""
    var send_body = has_body_for_status(writer.status, is_head)
    # HEAD omits body bytes but keeps the GET-equivalent length.
    # 1xx / 204 / 304 omit both length and bytes.
    var wire_length = -1
    if writer.status < 100 or writer.status > 199:
        if writer.status != 204 and writer.status != 304:
            wire_length = len(writer.body)
    # Validate a caller-supplied Content-Length against the framed length.
    # For HEAD the framed length is the GET-equivalent body length.
    # For 1xx/204/304 there is no framed length; a caller value is dropped.
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
    var out = List[Byte]()
    _append_string(
        out,
        String("HTTP/1.1 ")
        + String(writer.status)
        + String(" ")
        + _status_reason(writer.status)
        + String("\r\n"),
    )
    for i in range(len(writer.headers)):
        var name = writer.headers.name_at(i)
        var value = writer.headers.value_at(i)
        # Skip a caller Content-Length on no-body responses; it is
        # re-derived below for framed bodies only.
        if name.lower() == "content-length":
            continue
        _reject_response_injection(name, value)
        _append_string(out, name + String(": ") + value + String("\r\n"))
    if not writer.headers.get_first("Date"):
        _reject_response_injection("Date", date)
        _append_string(out, String("Date: ") + String(date) + String("\r\n"))
    if wire_length >= 0:
        _append_string(
            out,
            String("Content-Length: ") + String(wire_length) + String("\r\n"),
        )
    if writer.should_close:
        var connection = writer.headers.get_first("Connection")
        var has_close = False
        if connection:
            has_close = String(connection.value()).lower().find("close") >= 0
        if not has_close:
            _append_string(out, String("Connection: close\r\n"))
    _append_string(out, String("\r\n"))
    if send_body:
        for i in range(len(writer.body)):
            out.append(writer.body[i])
    return out^


def encode_100_continue() -> List[Byte]:
    var out = List[Byte]()
    _append_string(out, String("HTTP/1.1 100 Continue\r\n\r\n"))
    return out^


def encode_error(
    status: Int, should_close: Bool, date: StringSlice
) -> List[Byte]:
    """Minimal error response with a fixed small body. Never fails:
    used on paths where only a static buffer is available."""
    var reason = _status_reason(status)
    var body = String(status) + String(" ") + reason
    var out = List[Byte]()
    _append_string(
        out,
        String("HTTP/1.1 ")
        + String(status)
        + String(" ")
        + reason
        + String("\r\n"),
    )
    _append_string(out, String("Content-Type: text/plain\r\n"))
    _append_string(out, String("Date: ") + String(date) + String("\r\n"))
    _append_string(
        out,
        String("Content-Length: ")
        + String(body.byte_length())
        + String("\r\n"),
    )
    if should_close:
        _append_string(out, String("Connection: close\r\n"))
    _append_string(out, String("\r\n"))
    _append_string(out, body)
    return out^
