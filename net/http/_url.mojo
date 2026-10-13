"""Absolute HTTP URL parsing without decoding the request target."""

from net.ip import IPAddress
from ._authority import _host_is_valid, _is_hex_digit
from .client_error import ClientError


@fieldwise_init
struct ParsedUrl(Copyable, Movable):
    var scheme: String
    var host: String
    var port: UInt16
    var authority: String
    var target: String

    def same_origin(self, other: Self) -> Bool:
        return (
            self.scheme == other.scheme
            and self.host == other.host
            and self.port == other.port
        )


def parse_url(raw: StringSlice) raises ClientError -> ParsedUrl:
    var bytes = raw.as_bytes()
    var end = len(bytes)
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("#")):
            end = i
            break
    var separator = -1
    for i in range(end - 2):
        if (
            bytes[i] == Byte(ord(":"))
            and bytes[i + 1] == Byte(ord("/"))
            and bytes[i + 2] == Byte(ord("/"))
        ):
            separator = i
            break
    if separator < 0:
        raise ClientError.parse("expected an absolute HTTP URL")
    var scheme = String(from_utf8_lossy=bytes[:separator]).lower()
    if scheme != "http" and scheme != "https":
        raise ClientError.parse("unsupported URL scheme")
    var authority_end = end
    for i in range(separator + 3, end):
        if bytes[i] == Byte(ord("/")) or bytes[i] == Byte(ord("?")):
            authority_end = i
            break
    var authority = String(
        from_utf8_lossy=bytes[separator + 3 : authority_end]
    ).lower()
    if authority.find("%") >= 0:
        raise ClientError.parse(
            "percent escapes are not supported in URL hosts"
        )
    if not _host_is_valid(authority):
        raise ClientError.parse("invalid URL authority")
    var authority_bytes = authority.as_bytes()
    var host_end = len(authority_bytes)
    var host_start = 0
    var port_start = -1
    if authority_bytes[0] == Byte(ord("[")):
        host_start = 1
        for i in range(1, len(authority_bytes)):
            if authority_bytes[i] == Byte(ord("]")):
                host_end = i
                if i + 1 < len(authority_bytes):
                    port_start = i + 2
                break
    else:
        for i in range(len(authority_bytes)):
            if authority_bytes[i] == Byte(ord(":")):
                host_end = i
                port_start = i + 1
                break
    var host = String(from_utf8_lossy=authority_bytes[host_start:host_end])
    if host_start == 1:
        var is_ipv6: Bool
        var canonical_host: String
        try:
            var address = IPAddress.parse(host)
            is_ipv6 = address.is_ipv6()
            canonical_host = String(address)
        except:
            raise ClientError.parse("invalid IPv6 URL host")
        if not is_ipv6:
            raise ClientError.parse("invalid IPv6 URL host")
        host = canonical_host^
    var port = 80
    if scheme == "https":
        port = 443
    if port_start >= 0:
        port = 0
        for i in range(port_start, len(authority_bytes)):
            port = port * 10 + Int(authority_bytes[i] - Byte(ord("0")))
        if port == 0:
            raise ClientError.parse("URL port must be nonzero")
    var target = String(from_utf8_lossy=bytes[authority_end:end])
    if target.byte_length() == 0 or bytes[authority_end] == Byte(ord("?")):
        target = String("/") + target
    var target_bytes = target.as_bytes()
    var i = 0
    while i < len(target_bytes):
        var byte = target_bytes[i]
        if byte <= 32 or byte >= 127 or byte == Byte(ord("\\")):
            raise ClientError.parse("invalid URL request target")
        if byte == Byte(ord("%")):
            if i + 2 >= len(target_bytes):
                raise ClientError.parse("invalid URL percent escape")
            if not _is_hex_digit(target_bytes[i + 1]) or not _is_hex_digit(
                target_bytes[i + 2]
            ):
                raise ClientError.parse("invalid URL percent escape")
            i += 2
        i += 1
    return ParsedUrl(scheme^, host^, UInt16(port), authority^, target^)


def _normalize_redirect_path(path: StringSlice) -> String:
    var bytes = path.as_bytes()
    var segments = List[String]()
    var start = 1
    for end in range(1, len(bytes) + 1):
        if end < len(bytes) and bytes[end] != Byte(ord("/")):
            continue
        var segment = String(from_utf8_lossy=bytes[start:end])
        if segment == "..":
            if len(segments):
                var _ = segments.pop()
            if end == len(bytes):
                segments.append("")
        elif segment == ".":
            if end == len(bytes):
                segments.append("")
        else:
            segments.append(segment^)
        start = end + 1
    var result = String("/")
    for i in range(len(segments)):
        if i:
            result += "/"
        result += segments[i]
    return result^


def resolve_redirect(
    base: ParsedUrl, location: StringSlice
) raises ClientError -> String:
    var bytes = location.as_bytes()
    var end = len(bytes)
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("#")):
            end = i
            break
    var reference = String(from_utf8_lossy=bytes[:end])
    var origin = base.scheme + "://" + base.authority
    var candidate: String
    if reference.startswith("//"):
        candidate = base.scheme + ":" + reference
    else:
        var absolute = False
        for i in range(end):
            if bytes[i] == Byte(ord(":")):
                absolute = True
                break
            if bytes[i] == Byte(ord("/")) or bytes[i] == Byte(ord("?")):
                break
        if absolute:
            candidate = reference^
        elif end == 0:
            return origin + base.target
        else:
            var base_bytes = base.target.as_bytes()
            var path_end = len(base_bytes)
            for i in range(len(base_bytes)):
                if base_bytes[i] == Byte(ord("?")):
                    path_end = i
                    break
            if bytes[0] == Byte(ord("?")):
                candidate = (
                    origin
                    + String(from_utf8_lossy=base_bytes[:path_end])
                    + reference
                )
                var _ = parse_url(candidate)
                return candidate^
            elif bytes[0] == Byte(ord("/")):
                candidate = origin + reference
            else:
                var directory_end = 1
                for i in range(path_end):
                    if base_bytes[i] == Byte(ord("/")):
                        directory_end = i + 1
                candidate = (
                    origin
                    + String(from_utf8_lossy=base_bytes[:directory_end])
                    + reference
                )
    var parsed = parse_url(candidate)
    var target_bytes = parsed.target.as_bytes()
    var query_start = len(target_bytes)
    for i in range(len(target_bytes)):
        if target_bytes[i] == Byte(ord("?")):
            query_start = i
            break
    return (
        parsed.scheme
        + "://"
        + parsed.authority
        + _normalize_redirect_path(
            String(from_utf8_lossy=target_bytes[:query_start])
        )
        + String(from_utf8_lossy=target_bytes[query_start:])
    )
