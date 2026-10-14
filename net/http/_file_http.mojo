"""HTTP validators, dates and single byte ranges for static files."""

from ._encoder import current_http_date
from .headers import Headers


def _ows(value: StringSlice) -> String:
    var raw = value.as_bytes()
    var start = 0
    var end = len(raw)
    while start < end and (raw[start] == 32 or raw[start] == 9):
        start += 1
    while end > start and (raw[end - 1] == 32 or raw[end - 1] == 9):
        end -= 1
    return String(from_utf8_lossy=raw[start:end])


def _decimal[origin: ImmOrigin](raw: Span[Byte, origin]) -> Int:
    if len(raw) == 0:
        return -1
    var number = 0
    for byte in raw:
        if byte < 48 or byte > 57:
            return -1
        number = number * 10 + Int(byte - 48)
    return number


def _month(value: StringSlice) -> Int:
    var number = 1
    for name in [
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    ]:
        if value == name:
            return number
        number += 1
    return 0


def _weekday(value: StringSlice, full: Bool = False) -> Bool:
    if full:
        for name in [
            "Sunday",
            "Monday",
            "Tuesday",
            "Wednesday",
            "Thursday",
            "Friday",
            "Saturday",
        ]:
            if value == name:
                return True
    else:
        for name in ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]:
            if value == name:
                return True
    return False


def _clock[origin: ImmOrigin](raw: Span[Byte, origin]) -> Int:
    if len(raw) != 8 or raw[2] != 58 or raw[5] != 58:
        return -1
    var hour = _decimal(raw[:2])
    var minute = _decimal(raw[3:5])
    var second = _decimal(raw[6:8])
    if (
        hour < 0
        or hour > 23
        or minute < 0
        or minute > 59
        or second < 0
        or second > 60
    ):
        return -1
    return hour * 3600 + minute * 60 + second


def _calendar_seconds(
    year: Int, month: Int, day: Int, clock: Int
) -> Optional[Int]:
    if year < 0 or month < 1 or month > 12 or clock < 0:
        return None
    var lengths: Array[Int, 12] = [
        31,
        28,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ]
    var limit = lengths[month - 1]
    if month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
        limit = 29
    if day < 1 or day > limit:
        return None
    var y = year - Int(month <= 2)
    var era = y // 400
    var yoe = y - era * 400
    var shifted_month = month + (-3 if month > 2 else 9)
    var doy = (153 * shifted_month + 2) // 5 + day - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return (era * 146097 + doe - 719468) * 86400 + clock


def _parse_http_date(
    value: StringSlice, reference_date: StringSlice = ""
) -> Optional[Int]:
    var text = _ows(value)
    var raw = text.as_bytes()
    var year: Int
    var month: Int
    var day: Int
    var clock: Int
    if (
        len(raw) == 29
        and raw[3] == 44
        and raw[4] == 32
        and raw[7] == 32
        and raw[11] == 32
        and raw[16] == 32
        and raw[25] == 32
    ):
        if (
            not _weekday(String(from_utf8_lossy=raw[:3]))
            or String(from_utf8_lossy=raw[26:]) != "GMT"
        ):
            return None
        day = _decimal(raw[5:7])
        month = _month(String(from_utf8_lossy=raw[8:11]))
        year = _decimal(raw[12:16])
        clock = _clock(raw[17:25])
    elif (
        len(raw) == 24
        and raw[3] == 32
        and raw[7] == 32
        and raw[10] == 32
        and raw[19] == 32
    ):
        if not _weekday(String(from_utf8_lossy=raw[:3])):
            return None
        month = _month(String(from_utf8_lossy=raw[4:7]))
        day = _decimal(raw[9:10] if raw[8] == 32 else raw[8:10])
        clock = _clock(raw[11:19])
        year = _decimal(raw[20:24])
    else:
        var comma = text.find(",")
        if comma < 0 or comma + 2 > len(raw) or raw[comma + 1] != 32:
            return None
        if not _weekday(String(from_utf8_lossy=raw[:comma]), True):
            return None
        var rest = raw[comma + 2 :]
        if (
            len(rest) != 22
            or rest[2] != 45
            or rest[6] != 45
            or rest[9] != 32
            or rest[18] != 32
            or String(from_utf8_lossy=rest[19:]) != "GMT"
        ):
            return None
        day = _decimal(rest[:2])
        month = _month(String(from_utf8_lossy=rest[3:6]))
        var short_year = _decimal(rest[7:9])
        if short_year < 0:
            return None
        clock = _clock(rest[10:18])
        var reference = String(reference_date)
        if reference.byte_length() == 0:
            reference = current_http_date()
        var current = reference.as_bytes()
        var current_year = _decimal(current[12:16])
        year = (current_year + 50) // 100 * 100 + short_year
        var candidate_position = (month * 32 + day) * 86400 + clock
        var current_position = (
            _month(String(from_utf8_lossy=current[8:11])) * 32
            + _decimal(current[5:7])
        ) * 86400 + _clock(current[17:25])
        if year > current_year + 50 or (
            year == current_year + 50 and candidate_position > current_position
        ):
            year -= 100
    return _calendar_seconds(year, month, day, clock)


def _etag_matches(value: StringSlice, etag: StringSlice, weak: Bool) -> Bool:
    var text = _ows(value)
    if text == "*":
        return True
    if etag.byte_length() == 0:
        return False
    var expected = String(etag)
    if weak:
        var stripped = String(expected.removeprefix("W/"))
        expected = stripped^
    elif expected.startswith("W/"):
        return False
    var raw = text.as_bytes()
    var start = 0
    var quoted = False
    for i in range(len(raw) + 1):
        if i == len(raw) or (raw[i] == 44 and not quoted):
            var candidate = _ows(String(from_utf8_lossy=raw[start:i]))
            if weak:
                var stripped = String(candidate.removeprefix("W/"))
                candidate = stripped^
            if candidate == expected:
                return True
            start = i + 1
        elif raw[i] == 34:
            quoted = not quoted
    return False


def _mtime_seconds(nanoseconds: Int64) -> Int:
    return Int(nanoseconds // 1_000_000_000)


def _conditional_status(
    headers: Headers, etag: StringSlice, mtime_ns: Int64
) -> Int:
    var modified = _mtime_seconds(mtime_ns)
    var if_match = headers.get_all("If-Match")
    if len(if_match) > 0:
        var matched = False
        for value in if_match:
            if _etag_matches(value, etag, False):
                matched = True
                break
        if not matched:
            return 412
    else:
        var since = headers.get_first("If-Unmodified-Since")
        if since:
            var parsed = _parse_http_date(since.value())
            if parsed and modified > parsed.value():
                return 412
    var none_match = headers.get_all("If-None-Match")
    if len(none_match) > 0:
        for value in none_match:
            if _etag_matches(value, etag, True):
                return 304
        return 200
    var since = headers.get_first("If-Modified-Since")
    if since:
        var parsed = _parse_http_date(since.value())
        if parsed and modified <= parsed.value():
            return 304
    return 200


@fieldwise_init
struct _FileRange(Copyable):
    var status: Int
    var start: Int
    var length: Int


def _range_number(value: StringSlice, ceiling: Int) -> Int:
    var raw = value.as_bytes()
    if len(raw) == 0:
        return -1
    var number = 0
    for byte in raw:
        if byte < 48 or byte > 57:
            return -1
        var digit = Int(byte - 48)
        if number > ceiling // 10 or (
            number == ceiling // 10 and digit > ceiling % 10
        ):
            number = ceiling
        else:
            number = number * 10 + digit
    return number


def _parse_range(value: StringSlice, total: Int) -> _FileRange:
    var text = _ows(value)
    var pieces = text.split("=")
    if len(pieces) != 2 or String(pieces[0]).lower() != "bytes":
        return _FileRange(200, 0, total)
    var spec = String(pieces[1])
    if spec.find(",") >= 0:
        return _FileRange(200, 0, total)
    var ends = spec.split("-")
    if len(ends) != 2 or total == 0:
        return _FileRange(416, 0, 0)
    if ends[0].byte_length() == 0:
        var suffix = _range_number(ends[1], total)
        if suffix <= 0:
            return _FileRange(416, 0, 0)
        return _FileRange(206, total - suffix, suffix)
    var start = _range_number(ends[0], total)
    if start < 0 or start >= total:
        return _FileRange(416, 0, 0)
    var last = total - 1
    if ends[1].byte_length() > 0:
        last = _range_number(ends[1], total)
        if last < start:
            return _FileRange(416, 0, 0)
        last = min(last, total - 1)
    return _FileRange(206, start, last - start + 1)
