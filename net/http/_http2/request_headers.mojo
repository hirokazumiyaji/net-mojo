"""Validation and adaptation of decoded HTTP/2 request headers."""

from net.http._authority import _host_is_valid
from net.http.headers import Headers
from net.http.request import HttpVersion, Request, split_path_query


@fieldwise_init
struct Http2RequestHeadResult(Movable):
    var kind: UInt8
    var method: String
    var target: String
    var path: String
    var query: String
    var scheme: String
    var authority: String
    var headers: Headers

    @staticmethod
    def valid(
        var method: String,
        var target: String,
        var path: String,
        var query: String,
        var scheme: String,
        var authority: String,
        var headers: Headers,
    ) -> Self:
        return Self(
            kind=1,
            method=method^,
            target=target^,
            path=path^,
            query=query^,
            scheme=scheme^,
            authority=authority^,
            headers=headers^,
        )

    @staticmethod
    def error() -> Self:
        return Self(
            kind=2,
            method=String(),
            target=String(),
            path=String(),
            query=String(),
            scheme=String(),
            authority=String(),
            headers=Headers(),
        )

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def into_request(deinit self) -> Request:
        var request = Request(
            self.method^,
            self.target^,
            self.path^,
            self.query^,
            HttpVersion.http2(),
        )
        request.scheme = self.scheme^
        request.authority = self.authority^
        request.headers = self.headers^
        return request^


@fieldwise_init
struct Http2TrailersResult(Movable):
    var kind: UInt8
    var trailers: Headers

    @staticmethod
    def valid(var trailers: Headers) -> Self:
        return Self(kind=1, trailers=trailers^)

    @staticmethod
    def error() -> Self:
        return Self(kind=2, trailers=Headers())

    def is_valid(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2

    def take_trailers(deinit self) -> Headers:
        return self.trailers^


def _bytes_equal[
    origin: Origin
](name: Span[Byte, origin], expected: StringSlice) -> Bool:
    var expected_bytes = expected.as_bytes()
    if len(name) != len(expected_bytes):
        return False
    for i in range(len(name)):
        if name[i] != expected_bytes[i]:
            return False
    return True


def _is_token_byte(byte: Byte) -> Bool:
    if (
        (byte >= Byte(ord("a")) and byte <= Byte(ord("z")))
        or (byte >= Byte(ord("A")) and byte <= Byte(ord("Z")))
        or (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
    ):
        return True
    return (
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
    )


def _valid_value[origin: Origin](value: Span[Byte, origin]) -> Bool:
    for i in range(len(value)):
        var byte = value[i]
        if (
            byte == Byte(0)
            or byte == Byte(10)
            or byte == Byte(13)
            or (Int(byte) < 32 and byte != Byte(9))
            or byte == Byte(127)
        ):
            return False
    return True


def _is_te_trailers[origin: Origin](value: Span[Byte, origin]) -> Bool:
    var start = 0
    var end = len(value)
    while start < end and (value[start] == Byte(32) or value[start] == Byte(9)):
        start += 1
    while end > start and (
        value[end - 1] == Byte(32) or value[end - 1] == Byte(9)
    ):
        end -= 1
    if end - start != 8:
        return False
    var expected = String("trailers").as_bytes()
    for i in range(8):
        var lower_byte = value[start + i]
        if lower_byte >= Byte(ord("A")) and lower_byte <= Byte(ord("Z")):
            lower_byte = Byte(Int(lower_byte) + 32)
        if lower_byte != expected[i]:
            return False
    return True


def _valid_scheme[origin: Origin](scheme: Span[Byte, origin]) -> Bool:
    if len(scheme) == 0:
        return False
    for i in range(len(scheme)):
        var byte = scheme[i]
        if i == 0:
            if not (
                (byte >= Byte(ord("a")) and byte <= Byte(ord("z")))
                or (byte >= Byte(ord("A")) and byte <= Byte(ord("Z")))
            ):
                return False
        elif not (
            (byte >= Byte(ord("a")) and byte <= Byte(ord("z")))
            or (byte >= Byte(ord("A")) and byte <= Byte(ord("Z")))
            or (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
            or byte == Byte(ord("+"))
            or byte == Byte(ord("-"))
            or byte == Byte(ord("."))
        ):
            return False
    return True


def _valid_authority[origin: Origin](authority: Span[Byte, origin]) -> Bool:
    return _host_is_valid(String(from_utf8_lossy=authority))


def _valid_path[origin: Origin](path: Span[Byte, origin]) -> Bool:
    if len(path) == 0:
        return False
    if path[0] != Byte(ord("/")) and not _bytes_equal(path, "*"):
        return False
    for i in range(len(path)):
        if (
            path[i] <= Byte(32)
            or path[i] >= Byte(127)
            or path[i] == Byte(ord("#"))
        ):
            return False
    return True


def decode_http2_request_headers[
    origin: Origin
](
    encoded: Span[Byte, origin], expected_fields: Int
) raises -> Http2RequestHeadResult:
    if expected_fields < 0:
        return Http2RequestHeadResult.error()

    var method = String()
    var scheme = String()
    var authority = String()
    var host = String()
    var raw_path = String()
    var method_seen = False
    var scheme_seen = False
    var authority_seen = False
    var path_seen = False
    var host_seen = False
    var regular_seen = False
    var field_count = 0
    var headers = Headers()
    var offset = 0

    while offset < len(encoded):
        if len(encoded) - offset < 8:
            return Http2RequestHeadResult.error()
        var name_length = (
            (Int(encoded[offset]) << 24)
            | (Int(encoded[offset + 1]) << 16)
            | (Int(encoded[offset + 2]) << 8)
            | Int(encoded[offset + 3])
        )
        var value_length = (
            (Int(encoded[offset + 4]) << 24)
            | (Int(encoded[offset + 5]) << 16)
            | (Int(encoded[offset + 6]) << 8)
            | Int(encoded[offset + 7])
        )
        offset += 8
        if (
            name_length == 0
            or name_length > len(encoded) - offset
            or value_length > len(encoded) - offset - name_length
        ):
            return Http2RequestHeadResult.error()

        var name = encoded[offset : offset + name_length]
        offset += name_length
        var value = encoded[offset : offset + value_length]
        offset += value_length
        field_count += 1
        if field_count > expected_fields or not _valid_value(value):
            return Http2RequestHeadResult.error()

        var is_pseudo = name[0] == Byte(ord(":"))
        if is_pseudo:
            if regular_seen:
                return Http2RequestHeadResult.error()
            if _bytes_equal(name, ":method"):
                if method_seen or len(value) == 0:
                    return Http2RequestHeadResult.error()
                for i in range(len(value)):
                    if not _is_token_byte(value[i]):
                        return Http2RequestHeadResult.error()
                method = String(from_utf8_lossy=value)
                method_seen = True
            elif _bytes_equal(name, ":scheme"):
                if scheme_seen or not _valid_scheme(value):
                    return Http2RequestHeadResult.error()
                scheme = String(from_utf8_lossy=value)
                scheme_seen = True
            elif _bytes_equal(name, ":authority"):
                if authority_seen or not _valid_authority(value):
                    return Http2RequestHeadResult.error()
                authority = String(from_utf8_lossy=value)
                authority_seen = True
            elif _bytes_equal(name, ":path"):
                if path_seen or not _valid_path(value):
                    return Http2RequestHeadResult.error()
                raw_path = String(from_utf8_lossy=value)
                path_seen = True
            else:
                return Http2RequestHeadResult.error()
        else:
            regular_seen = True
            for i in range(len(name)):
                if name[i] >= Byte(127) or (
                    name[i] >= Byte(ord("A")) and name[i] <= Byte(ord("Z"))
                ):
                    return Http2RequestHeadResult.error()
                if not _is_token_byte(name[i]):
                    return Http2RequestHeadResult.error()
            var name_string = String(from_utf8_lossy=name)
            if (
                name_string == "connection"
                or name_string == "proxy-connection"
                or name_string == "keep-alive"
                or name_string == "transfer-encoding"
                or name_string == "upgrade"
            ):
                return Http2RequestHeadResult.error()
            if name_string == "te" and not _is_te_trailers(value):
                return Http2RequestHeadResult.error()
            if name_string == "host":
                if host_seen:
                    return Http2RequestHeadResult.error()
                host = String(from_utf8_lossy=value)
                host_seen = True
            headers.add_bytes(name_string, value)

    if field_count != expected_fields or not method_seen:
        return Http2RequestHeadResult.error()
    if method == "CONNECT" or not scheme_seen or not path_seen:
        return Http2RequestHeadResult.error()
    if raw_path == "*" and method != "OPTIONS":
        return Http2RequestHeadResult.error()
    if not authority_seen:
        if not host_seen or not _valid_authority(host.as_bytes()):
            return Http2RequestHeadResult.error()
        authority = host^
    elif host_seen and authority.lower() != host.lower():
        return Http2RequestHeadResult.error()

    var path, query = split_path_query(raw_path)
    return Http2RequestHeadResult.valid(
        method^,
        raw_path^,
        path^,
        query^,
        scheme^,
        authority^,
        headers^,
    )


def decode_http2_trailers[
    origin: Origin
](
    encoded: Span[Byte, origin], expected_fields: Int
) raises -> Http2TrailersResult:
    if expected_fields < 0:
        return Http2TrailersResult.error()

    var trailers = Headers()
    var field_count = 0
    var offset = 0
    while offset < len(encoded):
        if len(encoded) - offset < 8:
            return Http2TrailersResult.error()
        var name_length = (
            (Int(encoded[offset]) << 24)
            | (Int(encoded[offset + 1]) << 16)
            | (Int(encoded[offset + 2]) << 8)
            | Int(encoded[offset + 3])
        )
        var value_length = (
            (Int(encoded[offset + 4]) << 24)
            | (Int(encoded[offset + 5]) << 16)
            | (Int(encoded[offset + 6]) << 8)
            | Int(encoded[offset + 7])
        )
        offset += 8
        if (
            name_length == 0
            or name_length > len(encoded) - offset
            or value_length > len(encoded) - offset - name_length
        ):
            return Http2TrailersResult.error()

        var name = encoded[offset : offset + name_length]
        offset += name_length
        var value = encoded[offset : offset + value_length]
        offset += value_length
        field_count += 1
        if field_count > expected_fields or name[0] == Byte(ord(":")):
            return Http2TrailersResult.error()
        if not _valid_value(value):
            return Http2TrailersResult.error()
        for i in range(len(name)):
            if (
                name[i] >= Byte(127)
                or (name[i] >= Byte(ord("A")) and name[i] <= Byte(ord("Z")))
                or not _is_token_byte(name[i])
            ):
                return Http2TrailersResult.error()
        var name_string = String(from_utf8_lossy=name)
        if (
            name_string == "connection"
            or name_string == "proxy-connection"
            or name_string == "keep-alive"
            or name_string == "transfer-encoding"
            or name_string == "upgrade"
            or name_string == "content-length"
            or name_string == "host"
            or name_string == "te"
        ):
            return Http2TrailersResult.error()
        trailers.add_bytes(name_string, value)

    if field_count != expected_fields:
        return Http2TrailersResult.error()
    return Http2TrailersResult.valid(trailers^)
