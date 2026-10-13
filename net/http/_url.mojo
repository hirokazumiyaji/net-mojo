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
