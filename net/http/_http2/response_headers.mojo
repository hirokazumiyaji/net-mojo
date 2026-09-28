"""HTTP/2 response field validation and shared response adaptation."""

from net.http.headers import Headers
from net.http.response import ResponseWriter, has_body_for_status


@fieldwise_init
struct Http2ResponseHeadersResult(Movable):
    var kind: UInt8
    var fields: List[Byte]
    var field_count: Int
    var send_body: Bool

    @staticmethod
    def valid(var fields: List[Byte], field_count: Int, send_body: Bool) -> Self:
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
](
    mut output: List[Byte], name: StringSlice, value: Span[Byte, origin]
) -> Bool:
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
    for i in range(len(name_bytes)):
        output.append(name_bytes[i])
    for i in range(len(value)):
        output.append(value[i])
    return True


def _field_size(name_length: Int, value_length: Int) -> Int:
    return name_length + value_length + 32


def _content_length_matches(value: String, expected: Int) -> Bool:
    if expected < 0:
        return False
    var bytes = value.as_bytes()
    if len(bytes) == 0:
        return False
    var parsed = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return False
        var digit = Int(byte - Byte(ord("0")))
        if parsed > (expected - digit) // 10:
            return False
        parsed = parsed * 10 + digit
    return parsed == expected


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
    if (
        writer.status >= 200
        and writer.status != 204
        and writer.status != 205
        and writer.status != 304
    ):
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

    for i in range(len(writer.headers)):
        var name = writer.headers.name_at(i).lower()
        var value = writer.headers.value_bytes_at(i)
        if (
            name == "connection"
            or name == "proxy-connection"
            or name == "keep-alive"
            or name == "transfer-encoding"
            or name == "upgrade"
            or name == "te"
        ):
            return Http2ResponseHeadersResult.error()
        if name == "content-length":
            continue
        header_list_size += _field_size(name.byte_length(), len(value))
        field_count += 1
        if (
            field_count > max_fields
            or header_list_size > max_header_list_size
            or not _append_field(fields, name, Span(value))
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
            or not _append_field(
                fields, String("content-length"), length_bytes
            )
        ):
            return Http2ResponseHeadersResult.error()

    return Http2ResponseHeadersResult.valid(fields^, field_count, send_body)
