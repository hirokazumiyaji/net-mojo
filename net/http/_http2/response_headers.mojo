"""HTTP/2 response field validation and shared response adaptation."""

from net.http.headers import Headers, _parse_decimal, _trailer_forbidden
from net.http.response import ResponseWriter, has_body_for_status

from .request_headers import _is_connection_specific


@fieldwise_init
struct Http2ResponseHeadersResult(Movable):
    var kind: UInt8
    var fields: List[Byte]
    var field_count: Int
    var send_body: Bool

    @staticmethod
    def valid(
        var fields: List[Byte], field_count: Int, send_body: Bool
    ) -> Self:
        return Self(
            kind=1,
            fields=fields^,
            field_count=field_count,
            send_body=send_body,
        )

    @staticmethod
    def error() -> Self:
        return Self(kind=2, fields=List[Byte](), field_count=0, send_body=False)

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def _append_field[
    origin: Origin
](mut output: List[Byte], name: StringSlice, value: Span[Byte, origin]) -> Bool:
    var name_bytes = name.as_bytes()
    if len(name_bytes) > 0xFFFFFFFF or len(value) > 0xFFFFFFFF:
        return False
    output.append(Byte((len(name_bytes) >> 24) & 0xFF))
    output.append(Byte((len(name_bytes) >> 16) & 0xFF))
    output.append(Byte((len(name_bytes) >> 8) & 0xFF))
    output.append(Byte(len(name_bytes) & 0xFF))
    output.append(Byte((len(value) >> 24) & 0xFF))
    output.append(Byte((len(value) >> 16) & 0xFF))
    output.append(Byte((len(value) >> 8) & 0xFF))
    output.append(Byte(len(value) & 0xFF))
    output.extend(name_bytes)
    output.extend(value)
    return True


def _field_size(name_length: Int, value_length: Int) -> Int:
    return name_length + value_length + 32


def _content_length_matches(value: String, expected: Int) -> Bool:
    return expected >= 0 and _parse_decimal(value, expected) == expected


def encode_http2_response_headers(
    writer: ResponseWriter,
    is_head: Bool,
    date: StringSlice,
    max_header_list_size: Int,
    max_fields: Int,
) -> Http2ResponseHeadersResult:
    if (
        writer.status < 100
        or writer.status > 599
        or writer.status == 101
        or max_header_list_size < 0
        or max_fields < 1
    ):
        return Http2ResponseHeadersResult.error()

    var status = String(writer.status)
    var status_bytes = status.as_bytes()
    var header_list_size = _field_size(7, len(status_bytes))
    var field_count = 1
    var send_body = has_body_for_status(writer.status, is_head)
    var wire_length = -1
    if has_body_for_status(writer.status, False):
        wire_length = len(writer.body)

    var declared_lengths = writer.headers.get_all("content-length")
    if wire_length >= 0:
        for i in range(len(declared_lengths)):
            if not _content_length_matches(declared_lengths[i], wire_length):
                return Http2ResponseHeadersResult.error()

    var has_date = Bool(writer.headers.get_first("date"))
    var has_content_length = wire_length >= 0
    var fields = List[Byte]()
    if not _append_field(fields, String(":status"), status_bytes):
        return Http2ResponseHeadersResult.error()

    # RFC 9110 §7.6.1 / RFC 9113 §8.2.2: fields named by any "Connection"
    # header are hop-by-hop and must also be stripped from the response.
    var connection_hops = List[String]()
    for i in range(len(writer.headers)):
        ref name = writer.headers._lower_names[i]
        if name == "connection":
            var raw = writer.headers._value_bytes_span(i)
            var start = 0
            var cursor = 0
            while cursor <= len(raw):
                var at_end = cursor == len(raw)
                var is_sep = (not at_end) and (
                    raw[cursor] == Byte(ord(","))
                    or raw[cursor] == Byte(ord(" "))
                    or raw[cursor] == Byte(ord("\t"))
                )
                if at_end or is_sep:
                    if cursor > start:
                        var token = String()
                        for j in range(start, cursor):
                            var b = raw[j]
                            if b >= Byte(ord("A")) and b <= Byte(ord("Z")):
                                b = Byte(Int(b) + 32)
                            token += chr(Int(b))
                        if token.byte_length() > 0:
                            connection_hops.append(token^)
                    start = cursor + 1
                cursor += 1

    for i in range(len(writer.headers)):
        ref name = writer.headers._lower_names[i]
        var value = writer.headers._value_bytes_span(i)
        # RFC 9113 §8.2.2: these are HTTP/1-specific hop-by-hop headers and
        # must not appear in HTTP/2 responses; drop silently so a shared H1
        # handler cannot kill an H2 connection by writing them.
        if _is_connection_specific(name) or name == "te":
            continue
        if name == "content-length":
            continue
        var is_connection_nominated = False
        for h in connection_hops:
            if h == name:
                is_connection_nominated = True
                break
        if is_connection_nominated:
            continue
        header_list_size += _field_size(name.byte_length(), len(value))
        field_count += 1
        if (
            field_count > max_fields
            or header_list_size > max_header_list_size
            or not _append_field(fields, name, value)
        ):
            return Http2ResponseHeadersResult.error()

    if not has_date:
        var date_bytes = String(date).as_bytes()
        header_list_size += _field_size(4, len(date_bytes))
        field_count += 1
        if (
            field_count > max_fields
            or header_list_size > max_header_list_size
            or not _append_field(fields, String("date"), date_bytes)
        ):
            return Http2ResponseHeadersResult.error()

    if has_content_length:
        var length = String(wire_length)
        var length_bytes = length.as_bytes()
        header_list_size += _field_size(14, len(length_bytes))
        field_count += 1
        if (
            field_count > max_fields
            or header_list_size > max_header_list_size
            or not _append_field(fields, String("content-length"), length_bytes)
        ):
            return Http2ResponseHeadersResult.error()

    return Http2ResponseHeadersResult.valid(fields^, field_count, send_body)


def encode_http2_response_trailers(
    writer: ResponseWriter,
    is_head: Bool,
    max_header_list_size: Int,
    max_fields: Int,
) -> Http2ResponseHeadersResult:
    if max_header_list_size < 0 or max_fields < 1:
        return Http2ResponseHeadersResult.error()
    if is_head or not has_body_for_status(writer.status, is_head):
        return Http2ResponseHeadersResult.valid(
            List[Byte](), 0, send_body=False
        )
    if len(writer.trailers) == 0:
        return Http2ResponseHeadersResult.valid(
            List[Byte](), 0, send_body=False
        )

    var header_list_size = 0
    var field_count = 0
    var fields = List[Byte]()
    for i in range(len(writer.trailers)):
        ref name = writer.trailers._lower_names[i]
        var value = writer.trailers._value_bytes_span(i)
        if (
            _trailer_forbidden(name)
            or _is_connection_specific(name)
            or name == "te"
        ):
            return Http2ResponseHeadersResult.error()
        header_list_size += _field_size(name.byte_length(), len(value))
        field_count += 1
        if (
            field_count > max_fields
            or header_list_size > max_header_list_size
            or not _append_field(fields, name, value)
        ):
            return Http2ResponseHeadersResult.error()
    return Http2ResponseHeadersResult.valid(
        fields^, field_count, send_body=False
    )


def encode_http2_minimal_500_fields(
    date: StringSlice, max_header_list_size: Int, max_fields: Int
) -> Http2ResponseHeadersResult:
    """Builds a fallback 500 field list for the scheduler to retry when
    HPACK encoding of the normal headers does not fit the compressed
    buffer. The 500 response carries no body, so the HEADERS frame can
    close the stream and the dynamic table only sees the minimal fields.
    """
    if max_header_list_size < 0 or max_fields < 2:
        return Http2ResponseHeadersResult.error()
    var writer = ResponseWriter(0)
    writer.status = 500
    return encode_http2_response_headers(
        writer, False, date, max_header_list_size, max_fields
    )
