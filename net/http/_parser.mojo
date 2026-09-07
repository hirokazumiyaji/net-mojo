"""Incremental HTTP/1.1 request parser (Phase 1, socket-independent).

`parse_one` parses a single request from the start of a byte buffer and
reports `need_more`, `complete`, or `error` with the consumed count, so
callers get identical results for any byte-wise split and never mistake
pipelined next-request bytes for a body. `HttpParser` owns the buffer
for connection use.
"""

from net.http import Headers, HttpError, HttpVersion, Request, ServerConfig
from net.http import split_path_query


@fieldwise_init
struct ParseResult(Movable):
    var kind: UInt8
    var consumed: Int
    var request: Request
    var error: HttpError
    var needs_100_continue: Bool
    var should_close: Bool

    @staticmethod
    def need_more() -> Self:
        return Self(
            kind=0,
            consumed=0,
            request=Request(
                String(""),
                String(""),
                String(""),
                String(""),
                HttpVersion.http11(),
            ),
            error=HttpError(status=0, message=String(""), should_close=False),
            needs_100_continue=False,
            should_close=False,
        )

    @staticmethod
    def complete(
        var request: Request,
        consumed: Int,
        needs_100_continue: Bool,
        should_close: Bool,
    ) -> Self:
        return Self(
            kind=1,
            consumed=consumed,
            request=request^,
            error=HttpError(status=0, message=String(""), should_close=False),
            needs_100_continue=needs_100_continue,
            should_close=should_close,
        )

    @staticmethod
    def failure(
        var error: HttpError, consumed: Int, should_close: Bool
    ) -> Self:
        return Self(
            kind=2,
            consumed=consumed,
            request=Request(
                String(""),
                String(""),
                String(""),
                String(""),
                HttpVersion.http11(),
            ),
            error=error^,
            needs_100_continue=False,
            should_close=should_close,
        )

    def is_need_more(self) -> Bool:
        return self.kind == 0

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def take_request(mut self) -> Request:
        var dummy = Request(
            String(""),
            String(""),
            String("*"),
            String(""),
            HttpVersion.http11(),
        )
        var out = self.request^
        self.request = dummy^
        return out^

    def take_error(mut self) -> HttpError:
        return self.error.copy()


def _is_tchar(byte: Byte) -> Bool:
    if (
        (byte >= Byte(ord("A")) and byte <= Byte(ord("Z")))
        or (byte >= Byte(ord("a")) and byte <= Byte(ord("z")))
        or (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
    ):
        return True
    if (
        byte == Byte(ord("!"))
        or byte == Byte(ord("#"))
        or byte == Byte(ord("$"))
        or byte == Byte(ord("%"))
        or byte == Byte(ord("&"))
        or byte == Byte(ord("'"))
        or byte == Byte(ord("*"))
        or byte == Byte(ord("+"))
        or byte == Byte(ord("-"))
        or byte == Byte(ord("."))
        or byte == Byte(ord("^"))
        or byte == Byte(ord("_"))
        or byte == Byte(ord("`"))
        or byte == Byte(ord("|"))
        or byte == Byte(ord("~"))
    ):
        return True
    return False


def _is_token(data: StringSlice) -> Bool:
    var bytes = data.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        if not _is_tchar(bytes[i]):
            return False
    return True


def _is_version_number(version: StringSlice) -> Bool:
    # `HTTP/` followed by `DIGIT+ "." DIGIT+` and nothing else.
    var prefix = String("HTTP/")
    var text = String(version)
    if text.byte_length() <= len(prefix.as_bytes()):
        return False
    if not text.startswith(prefix):
        return False
    var digits = text.as_bytes()[len(prefix.as_bytes()) :]
    var dot = -1
    for i in range(len(digits)):
        if digits[i] == Byte(ord(".")):
            if dot >= 0:
                return False
            dot = i
        elif digits[i] < Byte(ord("0")) or digits[i] > Byte(ord("9")):
            return False
    if dot <= 0 or dot + 1 >= len(digits):
        return False
    return True


def _is_valid_method(data: StringSlice) -> Bool:
    return _is_token(data)


def _find_crlf[origin: Origin](buf: Span[Byte, origin], start: Int) -> Int:
    var i = start
    while i + 1 < len(buf):
        if buf[i] == Byte(ord("\r")) and buf[i + 1] == Byte(ord("\n")):
            return i
        i += 1
    return -1


def _has_lone_lf_before[
    origin: Origin
](buf: Span[Byte, origin], start: Int, end: Int) -> Bool:
    # True when a bare LF appears before `end` without a preceding CR.
    # A trailing CR at `end - 1` may be a split CRLF; the caller treats
    # end-of-buffer CR as need_more, not an error.
    for i in range(start, end):
        if buf[i] == Byte(ord("\n")):
            if i == start or buf[i - 1] != Byte(ord("\r")):
                return True
    return False


def _trim_ows(data: StringSlice) -> String:
    var bytes = data.as_bytes()
    var start = 0
    var end = len(bytes)
    while start < end and (
        bytes[start] == Byte(ord(" ")) or bytes[start] == Byte(ord("\t"))
    ):
        start += 1
    while end > start and (
        bytes[end - 1] == Byte(ord(" ")) or bytes[end - 1] == Byte(ord("\t"))
    ):
        end -= 1
    return String(from_utf8_lossy=bytes[start:end])


def _split_comma_tokens(data: StringSlice) -> List[String]:
    var out = List[String]()
    var bytes = data.as_bytes()
    var start = 0
    for i in range(len(bytes) + 1):
        if i == len(bytes) or bytes[i] == Byte(ord(",")):
            var part = String(from_utf8_lossy=bytes[start:i])
            var trimmed = _trim_ows(part)
            if trimmed.byte_length() > 0:
                out.append(trimmed^)
            start = i + 1
    return out^


def _parse_decimal_length(data: StringSlice) -> Int:
    var bytes = data.as_bytes()
    if len(bytes) == 0:
        return -1
    var value = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return -1
        value = value * 10 + Int(byte - Byte(ord("0")))
        if value > 16 * 1024 * 1024 * 1024:
            return -1
    return value


def _skip_bws[origin: Origin](bytes: Span[Byte, origin], mut i: Int):
    while i < len(bytes) and (
        bytes[i] == Byte(ord(" ")) or bytes[i] == Byte(ord("\t"))
    ):
        i += 1


def _chunk_ext_valid(ext: StringSlice) -> Bool:
    # Validates `chunk-ext` after the leading size (RFC 9112 7.1.1):
    # `*( BWS ";" BWS name [ BWS "=" BWS value ] )` with token names
    # and token or quoted-string values.
    var bytes = ext.as_bytes()
    if len(bytes) == 0:
        return False
    var i = 0
    var expect_item = True
    while i < len(bytes):
        if expect_item:
            _skip_bws(bytes, i)
            var name_start = i
            while i < len(bytes) and _is_tchar(bytes[i]):
                i += 1
            if i == name_start:
                return False
            _skip_bws(bytes, i)
            if i < len(bytes) and bytes[i] == Byte(ord("=")):
                i += 1
                _skip_bws(bytes, i)
                if i < len(bytes) and bytes[i] == Byte(ord('"')):
                    i += 1
                    var closed = False
                    while i < len(bytes):
                        if bytes[i] == Byte(ord("\\")):
                            # quoted-pair carries exactly one quoted
                            # byte: it must itself be quotable (HTAB /
                            # SP / VCHAR / obs-text), never a bare CR,
                            # NUL, or DEL a strict peer would reject.
                            if i + 1 >= len(bytes):
                                return False
                            var quoted = bytes[i + 1]
                            if quoted == Byte(0) or (
                                Int(quoted) < 32
                                and quoted != Byte(ord("\t"))
                                and quoted != Byte(ord(" "))
                            ):
                                return False
                            if Int(quoted) == 127:
                                return False
                            i += 2
                            continue
                        if bytes[i] == Byte(ord('"')):
                            closed = True
                            i += 1
                            break
                        if bytes[i] == Byte(0) or (
                            Int(bytes[i]) < 32 and bytes[i] != Byte(ord("\t"))
                        ):
                            return False
                        if Int(bytes[i]) == 127:
                            return False
                        i += 1
                    if not closed:
                        return False
                else:
                    var value_start = i
                    while i < len(bytes) and _is_tchar(bytes[i]):
                        i += 1
                    if i == value_start:
                        return False
            expect_item = False
        else:
            _skip_bws(bytes, i)
            if i >= len(bytes) or bytes[i] != Byte(ord(";")):
                return False
            i += 1
            expect_item = True
    return not expect_item


def _split_chunk_size(line: StringSlice) -> Tuple[String, String, Bool]:
    # Splits a chunk-size line at the first `;`, trimming BWS only when
    # an extension is actually present: a bare size line is hexadecimal
    # digits only, so leading/trailing whitespace there is malformed
    # framing rather than extension padding.
    var bytes = line.as_bytes()
    var semi = -1
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord(";")):
            semi = i
            break
    if semi < 0:
        return String(line), String(""), False
    var size = _trim_ows(String(from_utf8_lossy=bytes[0:semi]))
    var ext = String(from_utf8_lossy=bytes[semi + 1 :])
    return size^, ext^, True


def _parse_hex_size(data: StringSlice) -> Int:
    var bytes = data.as_bytes()
    if len(bytes) == 0:
        return -1
    var value = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte >= Byte(ord("0")) and byte <= Byte(ord("9")):
            value = value * 16 + Int(byte - Byte(ord("0")))
        elif byte >= Byte(ord("a")) and byte <= Byte(ord("f")):
            value = value * 16 + Int(byte - Byte(ord("a"))) + 10
        elif byte >= Byte(ord("A")) and byte <= Byte(ord("F")):
            value = value * 16 + Int(byte - Byte(ord("A"))) + 10
        else:
            return -1
        if value > 16 * 1024 * 1024 * 1024:
            return -1
    return value


def _is_hex_digit(byte: Byte) -> Bool:
    return (
        (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
        or (byte >= Byte(ord("a")) and byte <= Byte(ord("f")))
        or (byte >= Byte(ord("A")) and byte <= Byte(ord("F")))
    )


def _is_reg_name(hostname: StringSlice) -> Bool:
    # Unbracketed reg-name (RFC 3986): unreserved / pct-encoded /
    # sub-delims. In particular `%` must open two hex digits and
    # characters outside the set (backslash, DQUOTE, ...) are rejected
    # instead of passed to routing.
    var bytes = hostname.as_bytes()
    if len(bytes) == 0:
        return False
    var i = 0
    while i < len(bytes):
        var byte = bytes[i]
        if byte == Byte(ord("%")):
            if i + 2 >= len(bytes):
                return False
            if not _is_hex_digit(bytes[i + 1]):
                return False
            if not _is_hex_digit(bytes[i + 2]):
                return False
            i += 3
            continue
        var ok = (
            (byte >= Byte(ord("A")) and byte <= Byte(ord("Z")))
            or (byte >= Byte(ord("a")) and byte <= Byte(ord("z")))
            or (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
            or byte == Byte(ord("-"))
            or byte == Byte(ord("."))
            or byte == Byte(ord("_"))
            or byte == Byte(ord("~"))
            or byte == Byte(ord("!"))
            or byte == Byte(ord("$"))
            or byte == Byte(ord("&"))
            or byte == Byte(ord("'"))
            or byte == Byte(ord("("))
            or byte == Byte(ord(")"))
            or byte == Byte(ord("*"))
            or byte == Byte(ord("+"))
            or byte == Byte(ord(","))
            or byte == Byte(ord(";"))
            or byte == Byte(ord("="))
        )
        if not ok:
            return False
        i += 1
    return True


def _is_valid_port(port: StringSlice) -> Bool:
    var bytes = port.as_bytes()
    if len(bytes) == 0 or len(bytes) > 5:
        return False
    var value = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return False
        value = value * 10 + Int(byte - Byte(ord("0")))
    return value <= 65535


def _is_bracket_inner_valid(inner: StringSlice) -> Bool:
    var bytes = inner.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        var byte = bytes[i]
        var ok = (
            (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
            or (byte >= Byte(ord("a")) and byte <= Byte(ord("f")))
            or (byte >= Byte(ord("A")) and byte <= Byte(ord("F")))
            or (byte >= Byte(ord("G")) and byte <= Byte(ord("Z")))
            or (byte >= Byte(ord("g")) and byte <= Byte(ord("z")))
            or byte == Byte(ord(":"))
            or byte == Byte(ord("."))
            or byte == Byte(ord("%"))
            or byte == Byte(ord("-"))
            or byte == Byte(ord("_"))
            or byte == Byte(ord("~"))
        )
        if not ok:
            return False
    return True


def _host_is_valid(data: StringSlice) -> Bool:
    """Validates a Host/authority value structurally, not just by
    blacklist: bracketed literals need a closing bracket and optional
    numeric port, unbracketed names allow a single host:port split and
    never userinfo or bare IPv6 colons."""
    var text = String(data)
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte == Byte(ord(" ")) or byte == Byte(ord("\t")):
            return False
        if Int(byte) < 33 or Int(byte) == 127:
            return False
        if (
            byte == Byte(ord("/"))
            or byte == Byte(ord("?"))
            or byte == Byte(ord("#"))
        ):
            return False
        if byte == Byte(ord("\r")) or byte == Byte(ord("\n")):
            return False
    if bytes[0] == Byte(ord("[")):
        var close = -1
        for i in range(1, len(bytes)):
            if bytes[i] == Byte(ord("]")):
                close = i
                break
        if close < 0:
            return False
        if not _is_bracket_inner_valid(String(from_utf8_lossy=bytes[1:close])):
            return False
        if close + 1 == len(bytes):
            return True
        if bytes[close + 1] != Byte(ord(":")):
            return False
        return _is_valid_port(String(from_utf8_lossy=bytes[close + 2 :]))
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("[")) or bytes[i] == Byte(ord("]")):
            return False
        if bytes[i] == Byte(ord("@")):
            # No userinfo in a Host field.
            return False
    var colons = 0
    var last_colon = -1
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord(":")):
            colons += 1
            last_colon = i
    if colons > 1:
        # Bare IPv6 must arrive bracketed.
        return False
    var hostname = String(from_utf8_lossy=bytes)
    if colons == 1:
        if last_colon == 0 or last_colon + 1 >= len(bytes):
            return False
        for i in range(last_colon):
            if bytes[i] == Byte(ord("%")):
                return False
        if not _is_valid_port(String(from_utf8_lossy=bytes[last_colon + 1 :])):
            return False
        hostname = String(from_utf8_lossy=bytes[0:last_colon])
    return _is_reg_name(hostname)


def _parse_absolute_authority(
    target: StringSlice,
) -> Tuple[Bool, String, String, String]:
    # Returns (matched, authority, path, query). Only http/https.
    var text = String(target)
    var rest: String
    if (
        text.byte_length() >= 7
        and String(from_utf8_lossy=text.as_bytes()[0:7]).lower() == "http://"
    ):
        rest = String(from_utf8_lossy=text.as_bytes()[7:])
    elif (
        text.byte_length() >= 8
        and String(from_utf8_lossy=text.as_bytes()[0:8]).lower() == "https://"
    ):
        rest = String(from_utf8_lossy=text.as_bytes()[8:])
    else:
        return False, String(""), String(""), String("")
    var authority_end = len(rest.as_bytes())
    for i in range(len(rest.as_bytes())):
        var byte = rest.as_bytes()[i]
        if byte == Byte(ord("/")) or byte == Byte(ord("?")):
            authority_end = i
            break
    var authority = String(from_utf8_lossy=rest.as_bytes()[0:authority_end])
    var remainder = String(from_utf8_lossy=rest.as_bytes()[authority_end:])
    if remainder.byte_length() == 0:
        remainder = String("/")
    var path, query = split_path_query(remainder)
    if path.byte_length() == 0:
        # `http://host?query` carries an empty authority path: normalize
        # to `/` so root handlers see one path for both spellings.
        path = String("/")
    return True, authority^, path^, query^


def _trailer_forbidden(name: StringSlice) -> Bool:
    # RFC 9112 6.5.1 forbids trailers that change framing, routing,
    # authentication, or payload processing.
    var lowered = String(name).lower()
    return (
        lowered == "content-length"
        or lowered == "transfer-encoding"
        or lowered == "te"
        or lowered == "trailer"
        or lowered == "host"
        or lowered == "expect"
        or lowered == "connection"
        or lowered == "keep-alive"
        or lowered == "upgrade"
        or lowered == "authorization"
        or lowered == "proxy-authenticate"
        or lowered == "proxy-authorization"
        or lowered == "content-encoding"
        or lowered == "content-type"
        or lowered == "content-range"
    )


@fieldwise_init
struct _ChunkScan(Copyable, Movable):
    """Structural pre-scan of a chunked body: validates framing and
    counts bytes without materializing anything."""

    var kind: UInt8
    var consumed: Int
    var decoded: Int
    var error: HttpError

    @staticmethod
    def need_more() -> Self:
        return Self(
            kind=0,
            consumed=0,
            decoded=0,
            error=HttpError(status=0, message=String(""), should_close=False),
        )

    @staticmethod
    def complete(consumed: Int, decoded: Int) -> Self:
        return Self(
            kind=1,
            consumed=consumed,
            decoded=decoded,
            error=HttpError(status=0, message=String(""), should_close=False),
        )

    @staticmethod
    def failure(var error: HttpError) -> Self:
        return Self(kind=2, consumed=0, decoded=0, error=error^)

    def is_need_more(self) -> Bool:
        return self.kind == 0

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def take_error(self) -> HttpError:
        return self.error.copy()


def _scan_chunked[
    origin: ImmOrigin
](
    buf: Span[Byte, origin],
    config: ServerConfig,
    mut wire: Int,
    mut meta: Int,
    mut decoded: Int,
) -> _ChunkScan:
    """Walks chunk framing forward without storing body bytes, so a
    peer dripping one byte per feed cannot force per-feed reallocation
    and recopying of everything decoded so far. The `(wire, meta,
    decoded)` triple is both the resume point on entry and the updated
    frontier on a `need_more` exit, letting callers continue where the
    previous feed stopped. Every check mirrors the materializing loop
    below; the two must agree on all inputs."""
    var length = len(buf)
    var consumed = wire
    var done = False
    while not done:
        var size_end = _find_crlf(buf, wire)
        if size_end < 0:
            if _has_lone_lf_before(buf, wire, length):
                return _ChunkScan.failure(
                    HttpError.bad_request(String("bad chunk"))
                )
            if meta + (length - wire) > config.max_chunk_metadata:
                return _ChunkScan.failure(
                    HttpError.payload_too_large(
                        String("chunk metadata too large")
                    )
                )
            return _ChunkScan.need_more()
        if _has_lone_lf_before(buf, wire, size_end):
            return _ChunkScan.failure(
                HttpError.bad_request(String("bad chunk"))
            )
        var size_line_len = size_end - wire + 2
        # Commit line metadata only together with its data below: on a
        # need_more exit (wire, meta, decoded) must describe exactly
        # what was validated, or resuming re-counts the same line.
        if meta + size_line_len > config.max_chunk_metadata:
            return _ChunkScan.failure(
                HttpError.payload_too_large(String("chunk metadata too large"))
            )
        var size_line = String(from_utf8_lossy=buf[wire:size_end])
        var size_text, ext_text, has_ext = _split_chunk_size(size_line)
        if has_ext and not _chunk_ext_valid(ext_text):
            return _ChunkScan.failure(
                HttpError.bad_request(String("bad chunk extension"))
            )
        var chunk_size = _parse_hex_size(size_text)
        if chunk_size < 0:
            return _ChunkScan.failure(
                HttpError.bad_request(String("bad chunk size"))
            )
        var data_start = size_end + 2
        if chunk_size == 0:
            var trailer_pos = data_start
            var trailer_bytes_total = 0
            var trailer_count = 0
            while True:
                if trailer_pos >= length:
                    return _ChunkScan.need_more()
                if trailer_pos == length - 1 and buf[trailer_pos] == Byte(
                    ord("\r")
                ):
                    return _ChunkScan.need_more()
                var trailer_end = _find_crlf(buf, trailer_pos)
                if trailer_end < 0:
                    if _has_lone_lf_before(buf, trailer_pos, length):
                        return _ChunkScan.failure(
                            HttpError.bad_request(String("bad trailer"))
                        )
                    if (
                        trailer_bytes_total + (length - trailer_pos)
                        > config.max_trailer_bytes
                    ):
                        return _ChunkScan.failure(
                            HttpError.header_too_large(
                                String("trailers too large")
                            )
                        )
                    return _ChunkScan.need_more()
                if _has_lone_lf_before(buf, trailer_pos, trailer_end):
                    return _ChunkScan.failure(
                        HttpError.bad_request(String("bad trailer"))
                    )
                if trailer_end == trailer_pos:
                    consumed = trailer_end + 2
                    done = True
                    break
                var trailer_line_len = trailer_end - trailer_pos + 2
                trailer_bytes_total += trailer_line_len
                if (
                    trailer_bytes_total > config.max_trailer_bytes
                    or trailer_count + 1 > config.max_trailer_count
                ):
                    return _ChunkScan.failure(
                        HttpError.header_too_large(String("trailers too large"))
                    )
                var trailer_line = String(
                    from_utf8_lossy=buf[trailer_pos:trailer_end]
                )
                var trailer_bytes = trailer_line.as_bytes()
                if len(trailer_bytes) > 0 and (
                    trailer_bytes[0] == Byte(ord(" "))
                    or trailer_bytes[0] == Byte(ord("\t"))
                ):
                    return _ChunkScan.failure(
                        HttpError.bad_request(String("bad trailer"))
                    )
                var trailer_colon = -1
                for i in range(len(trailer_bytes)):
                    if trailer_bytes[i] == Byte(ord(":")):
                        trailer_colon = i
                        break
                if trailer_colon <= 0:
                    return _ChunkScan.failure(
                        HttpError.bad_request(String("bad trailer"))
                    )
                var trailer_name = String(
                    from_utf8_lossy=trailer_bytes[0:trailer_colon]
                )
                if not _is_token(trailer_name):
                    return _ChunkScan.failure(
                        HttpError.bad_request(String("bad trailer"))
                    )
                if _trailer_forbidden(trailer_name):
                    return _ChunkScan.failure(
                        HttpError.bad_request(
                            String("trailer modifies framing")
                        )
                    )
                trailer_count += 1
                trailer_pos = trailer_end + 2
                if trailer_pos < length and (
                    buf[trailer_pos] == Byte(ord(" "))
                    or buf[trailer_pos] == Byte(ord("\t"))
                ):
                    return _ChunkScan.failure(
                        HttpError.bad_request(String("bad trailer"))
                    )
            continue
        if decoded + chunk_size > config.max_body_bytes:
            return _ChunkScan.failure(
                HttpError.payload_too_large(String("body too large"))
            )
        if data_start + chunk_size + 2 > length:
            return _ChunkScan.need_more()
        if buf[data_start + chunk_size] != Byte(ord("\r")) or buf[
            data_start + chunk_size + 1
        ] != Byte(ord("\n")):
            return _ChunkScan.failure(
                HttpError.bad_request(String("bad chunk data"))
            )
        meta += size_line_len
        decoded += chunk_size
        wire = data_start + chunk_size + 2
    return _ChunkScan.complete(consumed, decoded)


struct HeadInfo(Movable):
    """Validated request head without the body.

    `header_end` is the offset just past the blank line terminating the
    headers. The server answers `100-continue` from this alone when the
    body has not arrived yet, then parses the body with `parse_one`.
    """

    var method: String
    var target: String
    var path: String
    var query: String
    var scheme: String
    var authority: String
    var version: HttpVersion
    var headers: Headers
    var content_length: Int
    var chunked: Bool
    var expect_100: Bool
    var should_close: Bool
    var header_end: Int

    def __init__(
        out self,
        var method: String,
        var target: String,
        var path: String,
        var query: String,
        var scheme: String,
        var authority: String,
        version: HttpVersion,
        var headers: Headers,
        content_length: Int,
        chunked: Bool,
        expect_100: Bool,
        should_close: Bool,
        header_end: Int,
    ):
        self.method = method^
        self.target = target^
        self.path = path^
        self.query = query^
        self.scheme = scheme^
        self.authority = authority^
        self.version = version.copy()
        self.headers = headers^
        self.content_length = content_length
        self.chunked = chunked
        self.expect_100 = expect_100
        self.should_close = should_close
        self.header_end = header_end


@fieldwise_init
struct HeadOutcome(Movable):
    var kind: UInt8
    var head: HeadInfo
    var error: HttpError

    @staticmethod
    def need_more() -> Self:
        return Self(
            kind=0,
            head=HeadInfo(
                String(""),
                String(""),
                String("*"),
                String(""),
                String("http"),
                String(""),
                HttpVersion.http11(),
                Headers(),
                -1,
                False,
                False,
                False,
                0,
            ),
            error=HttpError(status=0, message=String(""), should_close=False),
        )

    @staticmethod
    def complete(var head: HeadInfo) -> Self:
        return Self(
            kind=1,
            head=head^,
            error=HttpError(status=0, message=String(""), should_close=False),
        )

    @staticmethod
    def failure(
        var error: HttpError, consumed: Int, should_close: Bool
    ) -> Self:
        # `consumed` and `should_close` mirror `ParseResult.failure` so the
        # head section below needs no restructuring; head errors always
        # close with nothing consumed.
        _ = consumed
        _ = should_close
        return Self(
            kind=2,
            head=HeadInfo(
                String(""),
                String(""),
                String("*"),
                String(""),
                String("http"),
                String(""),
                HttpVersion.http11(),
                Headers(),
                -1,
                False,
                False,
                False,
                0,
            ),
            error=error^,
        )

    def is_need_more(self) -> Bool:
        return self.kind == 0

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def take_error(self) -> HttpError:
        return self.error.copy()

    def take_headers(mut self) -> Headers:
        var out = self.head.headers^
        self.head.headers = Headers()
        return out^


def parse_head[
    origin: ImmOrigin
](buf: Span[Byte, origin], config: ServerConfig) -> HeadOutcome:
    var length = len(buf)
    # --- Request line. ---
    var line_end = _find_crlf(buf, 0)
    if line_end < 0:
        if _has_lone_lf_before(buf, 0, length):
            return HeadOutcome.failure(
                HttpError.bad_request(String("bare LF in request line")),
                0,
                True,
            )
        # A trailing CR may be a split CRLF.
        if length > config.max_request_line:
            return HeadOutcome.failure(
                HttpError.header_too_large(String("request line too long")),
                0,
                True,
            )
        return HeadOutcome.need_more()
    if _has_lone_lf_before(buf, 0, line_end):
        return HeadOutcome.failure(
            HttpError.bad_request(String("bare LF in request line")), 0, True
        )
    if line_end > config.max_request_line:
        # Target-only excess maps to 414, other line excess to 431.
        # Scan for the target span even though the line is overlong.
        var first = -1
        var second = -1
        for i in range(line_end):
            if buf[i] == Byte(ord(" ")):
                if first < 0:
                    first = i
                else:
                    second = i
                    break
        if first >= 0 and second > first:
            var target_len = second - first - 1
            if target_len > config.max_request_line:
                return HeadOutcome.failure(
                    HttpError.uri_too_long(String("request target too long")),
                    0,
                    True,
                )
        return HeadOutcome.failure(
            HttpError.header_too_large(String("request line too long")),
            0,
            True,
        )
    # Split METHOD SP TARGET SP VERSION directly on the wire bytes:
    # no intermediate line String is allocated on this hot path.
    var first_sp = -1
    var second_sp = -1
    for i in range(line_end):
        if buf[i] == Byte(ord(" ")):
            if first_sp < 0:
                first_sp = i
            else:
                second_sp = i
                break
        if buf[i] == Byte(ord("\r")) or buf[i] == Byte(ord("\n")):
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad request line")), 0, True
            )
    if first_sp < 0 or second_sp < 0:
        return HeadOutcome.failure(
            HttpError.bad_request(String("bad request line")), 0, True
        )
    # Reject extra spaces inside the version part.
    for i in range(second_sp + 1, line_end):
        if buf[i] == Byte(ord(" ")):
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad request line")), 0, True
            )
    var method = String(from_utf8_lossy=buf[0:first_sp])
    var target = String(from_utf8_lossy=buf[first_sp + 1 : second_sp])
    var version_text = String(from_utf8_lossy=buf[second_sp + 1 : line_end])
    if not _is_valid_method(method):
        return HeadOutcome.failure(
            HttpError.bad_request(String("bad method")), 0, True
        )
    if target.byte_length() == 0:
        return HeadOutcome.failure(
            HttpError.bad_request(String("empty request target")), 0, True
        )
    for i in range(len(target.as_bytes())):
        var byte = target.as_bytes()[i]
        if Int(byte) < 33 or Int(byte) == 127:
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad request target")), 0, True
            )
        # Fragments are never sent on the wire (RFC 9112 3.1): a literal
        # `#` would route differently across clients and intermediaries
        # that strip it, so reject instead of exposing it to handlers.
        if byte == Byte(ord("#")):
            return HeadOutcome.failure(
                HttpError.bad_request(
                    String("fragment not allowed in request target")
                ),
                0,
                True,
            )
        # Raw non-ASCII bytes are invalid in a request-target (RFC 9112
        # 3.1: senders must percent-encode them). Rejecting here keeps
        # the downstream path/query split lossless, which operates on
        # ASCII and would otherwise normalize bytes irreversibly.
        if Int(byte) > 126:
            return HeadOutcome.failure(
                HttpError.bad_request(
                    String("non-ASCII request target must be percent-encoded")
                ),
                0,
                True,
            )
    if target.byte_length() > config.max_request_line:
        return HeadOutcome.failure(
            HttpError.uri_too_long(String("request target too long")),
            0,
            True,
        )
    var version = HttpVersion.http11()
    if version_text == "HTTP/1.1":
        pass
    elif version_text == "HTTP/1.0":
        return HeadOutcome.failure(
            HttpError.version_not_supported(String("HTTP/1.0 not supported")),
            0,
            True,
        )
    else:
        # Syntactically valid `HTTP/DIGIT.DIGIT` versions that we do not
        # speak are 505; anything else shaped is a malformed request
        # line and falls under the 400 contract.
        if _is_version_number(version_text):
            return HeadOutcome.failure(
                HttpError.version_not_supported(String("unsupported version")),
                0,
                True,
            )
        return HeadOutcome.failure(
            HttpError.bad_request(String("bad version")), 0, True
        )
    if method == "CONNECT":
        return HeadOutcome.failure(
            HttpError.bad_request(String("CONNECT not supported")), 0, True
        )
    # --- Headers. ---
    var headers = Headers()
    var pos = line_end + 2
    var header_bytes_total = 0
    var content_length_count = 0
    var content_length_value = -1
    var transfer_encoding_seen = False
    var transfer_encoding_chunked_only = False
    var transfer_encoding_raw = String("")
    var expect_invalid = False
    var expect_seen = False
    var connection_close = False
    var has_upgrade = False
    var host_count = 0
    var host_value = String("")
    while True:
        if pos >= length:
            return HeadOutcome.need_more()
        # Trailing CR without LF yet.
        if pos == length - 1 and buf[pos] == Byte(ord("\r")):
            return HeadOutcome.need_more()
        var header_end = _find_crlf(buf, pos)
        if header_end < 0:
            if _has_lone_lf_before(buf, pos, length):
                return HeadOutcome.failure(
                    HttpError.bad_request(String("bare LF in headers")),
                    0,
                    True,
                )
            # Count completed lines plus the unfinished tail: without
            # the completed part, nearly twice the header budget could
            # be retained behind one unterminated line.
            if header_bytes_total + (length - pos) > config.max_headers_bytes:
                return HeadOutcome.failure(
                    HttpError.header_too_large(String("headers too large")),
                    0,
                    True,
                )
            return HeadOutcome.need_more()
        if _has_lone_lf_before(buf, pos, header_end):
            return HeadOutcome.failure(
                HttpError.bad_request(String("bare LF in headers")), 0, True
            )
        if header_end == pos:
            pos += 2
            break
        var header_line_len = header_end - pos + 2
        header_bytes_total += header_line_len
        if header_bytes_total > config.max_headers_bytes:
            return HeadOutcome.failure(
                HttpError.header_too_large(String("headers too large")),
                0,
                True,
            )
        if len(headers) + 1 > config.max_headers_count:
            return HeadOutcome.failure(
                HttpError.header_too_large(String("too many headers")),
                0,
                True,
            )
        # obs-fold: CRLF followed by SP/HT is rejected, never folded.
        # (Checked after the empty-line test: a header line itself never
        # starts with OWS because the colon scan below rejects it, and a
        # continuation line would appear as a line starting with SP/HT.)
        var header_line = String(from_utf8_lossy=buf[pos:header_end])
        var header_line_bytes = header_line.as_bytes()
        if len(header_line_bytes) > 0 and (
            header_line_bytes[0] == Byte(ord(" "))
            or header_line_bytes[0] == Byte(ord("\t"))
        ):
            return HeadOutcome.failure(
                HttpError.bad_request(String("obs-fold not supported")),
                0,
                True,
            )
        var colon = -1
        for i in range(len(header_line_bytes)):
            if header_line_bytes[i] == Byte(ord(":")):
                colon = i
                break
        if colon <= 0:
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad header line")), 0, True
            )
        var raw_name = String(from_utf8_lossy=header_line_bytes[0:colon])
        # No whitespace between field-name and colon.
        if raw_name.as_bytes()[len(raw_name.as_bytes()) - 1] == Byte(
            ord(" ")
        ) or raw_name.as_bytes()[len(raw_name.as_bytes()) - 1] == Byte(
            ord("\t")
        ):
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad header name")), 0, True
            )
        if not _is_token(raw_name):
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad header name")), 0, True
            )
        var raw_value = String(from_utf8_lossy=header_line_bytes[colon + 1 :])
        var value = _trim_ows(raw_value)
        var lowered = raw_name.lower()
        if lowered == "host":
            host_count += 1
            host_value = String(value)
        elif lowered == "content-length":
            content_length_count += 1
            var parsed = _parse_decimal_length(value)
            if parsed < 0:
                return HeadOutcome.failure(
                    HttpError.bad_request(String("bad Content-Length")),
                    0,
                    True,
                )
            content_length_value = parsed
        elif lowered == "transfer-encoding":
            transfer_encoding_seen = True
            if transfer_encoding_raw.byte_length() > 0:
                transfer_encoding_raw += ","
            transfer_encoding_raw += value
        elif lowered == "expect":
            # Every occurrence must ask for 100-continue: later fields
            # must not silently override an unsupported expectation.
            # Each field may also carry a comma-separated expectation
            # list, so every complete token is checked, not the raw
            # field text.
            expect_seen = True
            var wants = _split_comma_tokens(value)
            if len(wants) == 0:
                expect_invalid = True
            for i in range(len(wants)):
                if wants[i].lower() != "100-continue":
                    expect_invalid = True
        elif lowered == "connection":
            var tokens = _split_comma_tokens(value)
            for i in range(len(tokens)):
                if tokens[i].lower() == "close":
                    connection_close = True
        elif lowered == "upgrade":
            has_upgrade = True
        try:
            headers.add(String(raw_name), String(value))
        except e:
            return HeadOutcome.failure(
                HttpError.bad_request(String("bad header")), 0, True
            )
        pos = header_end + 2
        # Peek for obs-fold on the next line without consuming: if the
        # next bytes start with SP/HT right after this CRLF, the sender
        # attempted folding.
        if pos < length and (
            buf[pos] == Byte(ord(" ")) or buf[pos] == Byte(ord("\t"))
        ):
            return HeadOutcome.failure(
                HttpError.bad_request(String("obs-fold not supported")),
                0,
                True,
            )
    if has_upgrade:
        return HeadOutcome.failure(
            HttpError.bad_request(String("Upgrade not supported")), 0, True
        )
    if host_count != 1 or not _host_is_valid(host_value):
        return HeadOutcome.failure(
            HttpError.bad_request(String("bad Host")), 0, True
        )
    if content_length_count > 1:
        return HeadOutcome.failure(
            HttpError.bad_request(String("duplicate Content-Length")),
            0,
            True,
        )
    if transfer_encoding_seen:
        var tokens = _split_comma_tokens(transfer_encoding_raw)
        if len(tokens) != 1 or tokens[0].lower() != "chunked":
            return HeadOutcome.failure(
                HttpError.bad_request(String("unsupported Transfer-Encoding")),
                0,
                True,
            )
        transfer_encoding_chunked_only = True
    if transfer_encoding_seen and content_length_count > 0:
        return HeadOutcome.failure(
            HttpError.bad_request(
                String("Content-Length with Transfer-Encoding")
            ),
            0,
            True,
        )
    var needs_100 = False
    if expect_seen:
        if expect_invalid:
            return HeadOutcome.failure(
                HttpError.expectation_failed(String("unknown Expect")),
                0,
                True,
            )
        needs_100 = True
    # --- Request target forms. ---
    var path = String("*")
    var query = String("")
    var scheme = String("http")
    var authority = String(host_value)
    var is_options_star = method == "OPTIONS" and target == "*"
    if not is_options_star:
        var matched, abs_authority, abs_path, abs_query = (
            _parse_absolute_authority(target)
        )
        if matched:
            if not _host_is_valid(abs_authority):
                return HeadOutcome.failure(
                    HttpError.bad_request(String("bad authority")), 0, True
                )
            authority = String(abs_authority)
            # This server speaks plaintext HTTP/1.1: the scheme stays
            # "http" even for https:// absolute-form targets (a TLS
            # terminator in front owns the real scheme). Reporting
            # "https" here would mislead origin checks, secure-cookie
            # policy, and redirects into trusting an unprotected hop,
            # and contradicts the Request contract.
            path = String(abs_path)
            query = String(abs_query)
        else:
            if not target.startswith("/"):
                return HeadOutcome.failure(
                    HttpError.bad_request(String("bad request target")),
                    0,
                    True,
                )
            var split_path, split_query = split_path_query(target)
            path = String(split_path)
            query = String(split_query)
    if content_length_value > config.max_body_bytes:
        return HeadOutcome.failure(
            HttpError.payload_too_large(String("body too large")), 0, True
        )
    return HeadOutcome.complete(
        HeadInfo(
            method^,
            target^,
            path^,
            query^,
            scheme^,
            authority^,
            version.copy(),
            headers^,
            content_length_value,
            transfer_encoding_chunked_only,
            needs_100,
            connection_close,
            pos,
        )
    )


def parse_one[
    origin: ImmOrigin
](buf: Span[Byte, origin], config: ServerConfig) -> ParseResult:
    var outcome = parse_head(buf, config)
    if outcome.is_need_more():
        return ParseResult.need_more()
    if outcome.is_error():
        return ParseResult.failure(outcome.take_error(), 0, True)
    var length = len(buf)

    var body = List[Byte]()
    var trailers = Headers()
    var consumed: Int
    if outcome.head.chunked:
        # Structural pre-scan first: it validates framing and counts
        # bytes without allocating, so dripped feeds cannot force
        # per-feed reallocation and recopying of decoded chunks. The
        # materializing walk below then runs exactly once, on complete
        # input, with an exactly sized buffer.
        var scan_wire = outcome.head.header_end
        var scan_meta = 0
        var scan_decoded = 0
        var scan = _scan_chunked(
            buf, config, scan_wire, scan_meta, scan_decoded
        )
        if scan.is_need_more():
            return ParseResult.need_more()
        if scan.is_error():
            return ParseResult.failure(scan.take_error(), 0, True)
        body.reserve(scan.decoded)
        var chunk_metadata_total = 0
        var decoded_total = 0
        var chunk_pos = outcome.head.header_end
        while True:
            var size_end = _find_crlf(buf, chunk_pos)
            if size_end < 0:
                if _has_lone_lf_before(buf, chunk_pos, length):
                    return ParseResult.failure(
                        HttpError.bad_request(String("bad chunk")),
                        0,
                        True,
                    )
                # An unterminated size line still counts against the
                # metadata cap: without this, a peer could stream an
                # endless line and grow the buffer without bound.
                if (
                    chunk_metadata_total + (length - chunk_pos)
                    > config.max_chunk_metadata
                ):
                    return ParseResult.failure(
                        HttpError.payload_too_large(
                            String("chunk metadata too large")
                        ),
                        0,
                        True,
                    )
                return ParseResult.need_more()
            if _has_lone_lf_before(buf, chunk_pos, size_end):
                return ParseResult.failure(
                    HttpError.bad_request(String("bad chunk")), 0, True
                )
            var size_line_len = size_end - chunk_pos + 2
            chunk_metadata_total += size_line_len
            if chunk_metadata_total > config.max_chunk_metadata:
                return ParseResult.failure(
                    HttpError.payload_too_large(
                        String("chunk metadata too large")
                    ),
                    0,
                    True,
                )
            var size_line = String(from_utf8_lossy=buf[chunk_pos:size_end])
            var size_text, ext_text, has_ext = _split_chunk_size(size_line)
            # Extensions follow strict grammar (RFC 9112 7.1.1):
            # `;name[=value]` chains with token names and token or
            # quoted values. Lax parsing here would let strict
            # intermediaries disagree about validity.
            if has_ext and not _chunk_ext_valid(ext_text):
                return ParseResult.failure(
                    HttpError.bad_request(String("bad chunk extension")),
                    0,
                    True,
                )
            var chunk_size = _parse_hex_size(size_text)
            if chunk_size < 0:
                return ParseResult.failure(
                    HttpError.bad_request(String("bad chunk size")), 0, True
                )
            var data_start = size_end + 2
            if chunk_size == 0:
                # Trailers until empty line.
                var trailer_pos = data_start
                var trailer_bytes_total = 0
                var trailer_count = 0
                while True:
                    if trailer_pos >= length:
                        return ParseResult.need_more()
                    if trailer_pos == length - 1 and buf[trailer_pos] == Byte(
                        ord("\r")
                    ):
                        return ParseResult.need_more()
                    var trailer_end = _find_crlf(buf, trailer_pos)
                    if trailer_end < 0:
                        if _has_lone_lf_before(buf, trailer_pos, length):
                            return ParseResult.failure(
                                HttpError.bad_request(String("bad trailer")),
                                0,
                                True,
                            )
                        # Like chunk-size lines, an unterminated trailer
                        # line counts while incomplete so it cannot grow
                        # past the trailer cap without CRLF.
                        if (
                            trailer_bytes_total + (length - trailer_pos)
                            > config.max_trailer_bytes
                        ):
                            return ParseResult.failure(
                                HttpError.header_too_large(
                                    String("trailers too large")
                                ),
                                0,
                                True,
                            )
                        return ParseResult.need_more()
                    if _has_lone_lf_before(buf, trailer_pos, trailer_end):
                        return ParseResult.failure(
                            HttpError.bad_request(String("bad trailer")),
                            0,
                            True,
                        )
                    if trailer_end == trailer_pos:
                        consumed = trailer_end + 2
                        break
                    var trailer_line_len = trailer_end - trailer_pos + 2
                    trailer_bytes_total += trailer_line_len
                    if (
                        trailer_bytes_total > config.max_trailer_bytes
                        or trailer_count + 1 > config.max_trailer_count
                    ):
                        return ParseResult.failure(
                            HttpError.header_too_large(
                                String("trailers too large")
                            ),
                            0,
                            True,
                        )
                    var trailer_line = String(
                        from_utf8_lossy=buf[trailer_pos:trailer_end]
                    )
                    var trailer_bytes = trailer_line.as_bytes()
                    if len(trailer_bytes) > 0 and (
                        trailer_bytes[0] == Byte(ord(" "))
                        or trailer_bytes[0] == Byte(ord("\t"))
                    ):
                        return ParseResult.failure(
                            HttpError.bad_request(String("bad trailer")),
                            0,
                            True,
                        )
                    var trailer_colon = -1
                    for i in range(len(trailer_bytes)):
                        if trailer_bytes[i] == Byte(ord(":")):
                            trailer_colon = i
                            break
                    if trailer_colon <= 0:
                        return ParseResult.failure(
                            HttpError.bad_request(String("bad trailer")),
                            0,
                            True,
                        )
                    var trailer_name = String(
                        from_utf8_lossy=trailer_bytes[0:trailer_colon]
                    )
                    if not _is_token(trailer_name):
                        return ParseResult.failure(
                            HttpError.bad_request(String("bad trailer")),
                            0,
                            True,
                        )
                    if _trailer_forbidden(trailer_name):
                        return ParseResult.failure(
                            HttpError.bad_request(
                                String("trailer modifies framing")
                            ),
                            0,
                            True,
                        )
                    var trailer_value = _trim_ows(
                        String(
                            from_utf8_lossy=trailer_bytes[trailer_colon + 1 :]
                        )
                    )
                    try:
                        trailers.add(
                            String(trailer_name), String(trailer_value)
                        )
                    except e:
                        return ParseResult.failure(
                            HttpError.bad_request(String("bad trailer")),
                            0,
                            True,
                        )
                    trailer_count += 1
                    trailer_pos = trailer_end + 2
                    if trailer_pos < length and (
                        buf[trailer_pos] == Byte(ord(" "))
                        or buf[trailer_pos] == Byte(ord("\t"))
                    ):
                        return ParseResult.failure(
                            HttpError.bad_request(String("bad trailer")),
                            0,
                            True,
                        )
                break
            if data_start + chunk_size + 2 > length:
                # Incomplete data or split CRLF: wait for more unless the
                # available bytes already prove overflow.
                if decoded_total + chunk_size > config.max_body_bytes:
                    return ParseResult.failure(
                        HttpError.payload_too_large(String("body too large")),
                        0,
                        True,
                    )
                return ParseResult.need_more()
            if decoded_total + chunk_size > config.max_body_bytes:
                return ParseResult.failure(
                    HttpError.payload_too_large(String("body too large")),
                    0,
                    True,
                )
            for i in range(chunk_size):
                body.append(buf[data_start + i])
            decoded_total += chunk_size
            if buf[data_start + chunk_size] != Byte(ord("\r")) or buf[
                data_start + chunk_size + 1
            ] != Byte(ord("\n")):
                return ParseResult.failure(
                    HttpError.bad_request(String("bad chunk data")), 0, True
                )
            chunk_pos = data_start + chunk_size + 2
        # `consumed` was set to the trailer terminator in the zero-size
        # branch above.
    else:
        var want = (
            outcome.head.content_length if outcome.head.content_length
            >= 0 else 0
        )
        if outcome.head.header_end + want > length:
            return ParseResult.need_more()
        for i in range(want):
            body.append(buf[outcome.head.header_end + i])
        consumed = outcome.head.header_end + want
    var expect_100 = outcome.head.expect_100
    var should_close = outcome.head.should_close
    var request = Request(
        String(outcome.head.method),
        String(outcome.head.target),
        String(outcome.head.path),
        String(outcome.head.query),
        outcome.head.version.copy(),
    )
    request.scheme = String(outcome.head.scheme)
    request.authority = String(outcome.head.authority)
    request.headers = outcome.take_headers()
    request.trailers = trailers^
    request.body = body^
    return ParseResult.complete(request^, consumed, expect_100, should_close)


struct HttpParser(Movable):
    """Owns unprocessed bytes for one connection. Feed arbitrary splits;
    call `next_result` repeatedly to drain pipelined requests.

    Incremental state is retained across feeds so dripping senders
    cannot force quadratic work: the validated head end (with its
    chunked flag and declared length) plus the chunk-scan frontier
    (`wire`, `meta`, `decoded`) persist while a request is incomplete.
    Each feed therefore revalidates only new bytes (plus a bounded
    partial tail). Completion and errors delegate to `parse_one` for a
    single authoritative assembly walk. All retained state is plain
    scalars; buffers are append-only until a terminal outcome drains
    them, which also resets the cache.
    """

    var _buf: List[Byte]
    var _head_end: Int
    var _head_chunked: Bool
    var _head_clen: Int
    var _scan_wire: Int
    var _scan_meta: Int
    var _scan_decoded: Int
    var _scan_active: Bool

    def __init__(out self):
        self._buf = List[Byte]()
        self._head_end = -1
        self._head_chunked = False
        self._head_clen = -1
        self._scan_wire = 0
        self._scan_meta = 0
        self._scan_decoded = 0
        self._scan_active = False

    def _reset_progress(mut self):
        self._head_end = -1
        self._head_chunked = False
        self._head_clen = -1
        self._scan_wire = 0
        self._scan_meta = 0
        self._scan_decoded = 0
        self._scan_active = False

    def buffered_len(self) -> Int:
        return len(self._buf)

    def feed[origin: ImmOrigin](mut self, data: Span[Byte, origin]):
        for i in range(len(data)):
            self._buf.append(data[i])

    def feed_string(mut self, data: StringSlice):
        var bytes = data.as_bytes()
        for i in range(len(bytes)):
            self._buf.append(bytes[i])

    def next_result(mut self, config: ServerConfig) -> ParseResult:
        if self._head_end < 0:
            var head = parse_head(Span(self._buf), config)
            if head.is_need_more():
                return ParseResult.need_more()
            if head.is_error():
                self._reset_progress()
                return ParseResult.failure(head.take_error(), 0, True)
            self._head_end = head.head.header_end
            self._head_chunked = head.head.chunked
            self._head_clen = head.head.content_length
        if not self._head_chunked:
            var want = self._head_clen if self._head_clen >= 0 else 0
            if len(self._buf) < self._head_end + want:
                return ParseResult.need_more()
        else:
            if not self._scan_active:
                self._scan_wire = self._head_end
                self._scan_meta = 0
                self._scan_decoded = 0
                self._scan_active = True
            var wire = self._scan_wire
            var meta = self._scan_meta
            var decoded = self._scan_decoded
            var scan = _scan_chunked(
                Span(self._buf), config, wire, meta, decoded
            )
            self._scan_wire = wire
            self._scan_meta = meta
            self._scan_decoded = decoded
            if scan.is_need_more():
                return ParseResult.need_more()
            # Terminal scan verdicts still assemble through parse_one
            # once, keeping a single authoritative construction path.
            self._reset_progress()
        var result = parse_one(Span(self._buf), config)
        if result.is_complete() or result.is_error():
            self._reset_progress()
            var remaining = List[Byte]()
            for i in range(result.consumed, len(self._buf)):
                remaining.append(self._buf[i])
            self._buf = remaining^
        return result^

    def clear(mut self):
        self._buf.clear()
        self._reset_progress()
