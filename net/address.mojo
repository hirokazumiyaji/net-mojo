from std.ffi import c_int, c_uint, external_call
from std.sys import CompilationTarget

from net._sys.common import (
    AF_INET,
    AF_INET6,
    IF_NAMESIZE,
    _RawSocketAddress,
    _ResolverHints,
    _addrinfo_address,
    _addrinfo_address_length,
    _addrinfo_family,
    _addrinfo_next,
)
from .error import NetError, NetErrorKind
from .ip import IPAddress, _from_ipv4_bytes, _from_ipv6_bytes


@fieldwise_init
struct SocketAddress(Copyable, Equatable, Hashable, Writable):
    var ip: IPAddress
    var port: UInt16
    var scope_id: UInt32

    @staticmethod
    def parse(value: StringSlice) raises NetError -> Self:
        return _parse_numeric_socket_address(value)

    def write_to[W: Writer](self, mut writer: W):
        if self.ip.is_ipv6():
            writer.write("[")
            writer.write(self.ip)
            if self.scope_id != 0:
                writer.write("%")
                writer.write(_format_zone(self.scope_id))
            writer.write("]:")
            writer.write(self.port)
            return
        writer.write(self.ip)
        writer.write(":")
        writer.write(self.port)


def _invalid_socket_address() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "parse socket address",
        None,
        "invalid socket address",
    )


def _invalid_raw_socket_address() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "convert socket address",
        None,
        "invalid raw socket address",
    )


def _write_raw_family(
    mut raw: _RawSocketAddress, family: Int32, length: UInt32
):
    var pointer = raw.unsafe_ptr()
    comptime if CompilationTarget.is_macos():
        pointer[unsafe_offset=0] = Byte(length)
        pointer[unsafe_offset=1] = Byte(family)
    else:
        pointer[unsafe_offset=0] = Byte(UInt32(family) & 0xFF)
        pointer[unsafe_offset=1] = Byte((UInt32(family) >> 8) & 0xFF)


def _read_raw_family[origin: MutOrigin](raw: Pointer[Byte, origin]) -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(raw[unsafe_offset=1])
    else:
        return Int32(
            UInt16(raw[unsafe_offset=0]) | (UInt16(raw[unsafe_offset=1]) << 8)
        )


def _socket_address_to_raw(address: SocketAddress) -> _RawSocketAddress:
    var raw = _RawSocketAddress()
    var address_bytes = address.ip.as_bytes()
    if address.ip.is_ipv4():
        raw.length = 16
        _write_raw_family(raw, AF_INET, 16)
        var pointer = raw.unsafe_ptr()
        pointer[unsafe_offset=2] = Byte(address.port >> 8)
        pointer[unsafe_offset=3] = Byte(address.port & 0xFF)
        for i in range(4):
            pointer[unsafe_offset=4 + i] = address_bytes[i]
        return raw^

    raw.length = 28
    _write_raw_family(raw, AF_INET6, 28)
    var pointer = raw.unsafe_ptr()
    pointer[unsafe_offset=2] = Byte(address.port >> 8)
    pointer[unsafe_offset=3] = Byte(address.port & 0xFF)
    for i in range(16):
        pointer[unsafe_offset=8 + i] = address_bytes[i]
    pointer[unsafe_offset=24] = Byte(address.scope_id & 0xFF)
    pointer[unsafe_offset=25] = Byte((address.scope_id >> 8) & 0xFF)
    pointer[unsafe_offset=26] = Byte((address.scope_id >> 16) & 0xFF)
    pointer[unsafe_offset=27] = Byte((address.scope_id >> 24) & 0xFF)
    return raw^


def _socket_address_from_raw[
    origin: MutOrigin
](raw: Pointer[Byte, origin], length: UInt32) raises NetError -> SocketAddress:
    if length != 16 and length != 28:
        raise _invalid_raw_socket_address()
    var family = _read_raw_family(raw)
    var expected_length: UInt32
    if family == AF_INET:
        expected_length = 16
    elif family == AF_INET6:
        expected_length = 28
    else:
        raise _invalid_raw_socket_address()
    if length != expected_length:
        raise _invalid_raw_socket_address()
    comptime if CompilationTarget.is_macos():
        if UInt32(raw[unsafe_offset=0]) != length:
            raise _invalid_raw_socket_address()

    var port = UInt16(
        (UInt16(raw[unsafe_offset=2]) << 8) | UInt16(raw[unsafe_offset=3])
    )
    if family == AF_INET:
        var ip = _from_ipv4_bytes(
            raw[unsafe_offset=4],
            raw[unsafe_offset=5],
            raw[unsafe_offset=6],
            raw[unsafe_offset=7],
        )
        return SocketAddress(ip=ip^, port=port, scope_id=0)

    var bytes = Array[Byte, 16](fill=0)
    for i in range(16):
        bytes[i] = raw[unsafe_offset=8 + i]
    var scope_id = (
        UInt32(raw[unsafe_offset=24])
        | (UInt32(raw[unsafe_offset=25]) << 8)
        | (UInt32(raw[unsafe_offset=26]) << 16)
        | (UInt32(raw[unsafe_offset=27]) << 24)
    )
    var ip = _from_ipv6_bytes(bytes^)
    return SocketAddress(ip=ip^, port=port, scope_id=scope_id)


def _parse_port_digit(
    byte: Byte, mut value: UInt32, mut digits: Int
) raises NetError:
    if byte < Byte(ord("0")) or byte > Byte(ord("9")):
        raise _invalid_socket_address()
    digits += 1
    if digits > 5:
        raise _invalid_socket_address()
    value = value * 10 + UInt32(byte - Byte(ord("0")))
    if value > UInt32(UInt16.MAX):
        raise _invalid_socket_address()


def _split_host_port(
    value: StringSlice, allow_empty_host: Bool
) raises NetError -> Tuple[String, UInt16]:
    var input = value.as_bytes()
    if len(input) == 0:
        raise _invalid_socket_address()

    var bracketed = input[0] == Byte(ord("["))
    var host_bytes = List[Byte]()
    var bracket_closed = False
    var separator_found = False
    var port_value = UInt32(0)
    var port_digits = 0

    for i in range(len(input)):
        var byte = input[i]
        if byte == 0:
            raise _invalid_socket_address()

        if bracketed:
            if i == 0:
                continue
            if not bracket_closed:
                if byte == Byte(ord("]")):
                    bracket_closed = True
                else:
                    host_bytes.append(byte)
                continue
            if not separator_found:
                if byte != Byte(ord(":")):
                    raise _invalid_socket_address()
                separator_found = True
                continue
            _parse_port_digit(byte, port_value, port_digits)
            continue

        if not separator_found:
            if byte == Byte(ord(":")):
                separator_found = True
            elif byte == Byte(ord("[")) or byte == Byte(ord("]")):
                raise _invalid_socket_address()
            else:
                host_bytes.append(byte)
            continue
        _parse_port_digit(byte, port_value, port_digits)

    var host = String(from_utf8_lossy=Span(host_bytes))
    if bracketed:
        if not bracket_closed or not separator_found or len(host_bytes) == 0:
            raise _invalid_socket_address()
    elif not separator_found:
        raise _invalid_socket_address()
    if len(host_bytes) == 0 and not allow_empty_host:
        raise _invalid_socket_address()
    if port_digits == 0:
        raise _invalid_socket_address()
    return host^, UInt16(port_value)


def split_host_port(
    value: StringSlice,
) raises NetError -> Tuple[String, UInt16]:
    return _split_host_port(value, False)


def join_host_port(host: StringSlice, port: UInt16) -> String:
    var contains_colon = False
    var input = host.as_bytes()
    for byte in input:
        if byte == Byte(ord(":")):
            contains_colon = True
            break
    if contains_colon:
        return String(t"[{host}]:{port}")
    return String(t"{host}:{port}")


def _parse_numeric_socket_address(
    value: StringSlice,
) raises NetError -> SocketAddress:
    var host, port = split_host_port(value)
    var address_text, scope_id = _split_host_zone(host)

    var ip = IPAddress.parse(address_text)
    var original = value.as_bytes()
    if original[0] == Byte(ord("[")):
        if not ip.is_ipv6():
            raise _invalid_socket_address()
    elif ip.is_ipv6():
        raise _invalid_socket_address()
    if scope_id != 0 and not ip.is_ipv6():
        raise _invalid_socket_address()
    return SocketAddress(ip=ip.copy(), port=port, scope_id=scope_id)


def _invalid_zone() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "resolve interface zone",
        None,
        "invalid interface zone",
    )


def _resolve_zone(zone: StringSlice) raises NetError -> UInt32:
    var input = zone.as_bytes()
    if len(input) == 0:
        raise _invalid_zone()
    var numeric = True
    for byte in input:
        if byte == 0:
            raise _invalid_zone()
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            numeric = False
    if numeric:
        var value = UInt32(0)
        for byte in input:
            var digit = UInt32(byte - Byte(ord("0")))
            if value > (UInt32.MAX - digit) // 10:
                raise _invalid_zone()
            value = value * 10 + digit
        if value == 0:
            raise _invalid_zone()
        return value

    var name = String(zone)
    var c_name = name.as_c_string_slice()
    var index = external_call["if_nametoindex", c_uint](c_name.unsafe_ptr())
    if index == 0:
        raise _invalid_zone()
    return UInt32(index)


def _format_zone(scope_id: UInt32) -> String:
    var buffer = Array[Byte, IF_NAMESIZE](fill=0)
    var bytes = Span(buffer)
    var result = external_call[
        "if_indextoname",
        Optional[Pointer[Byte, MutUntrackedOrigin]],
    ](c_uint(scope_id), bytes.unsafe_ptr())
    if not result:
        return String(scope_id)
    var length = 0
    while length < IF_NAMESIZE and bytes[length] != 0:
        length += 1
    if length == 0 or length == IF_NAMESIZE:
        return String(scope_id)
    return String(from_utf8_lossy=bytes[0:length])


def _split_host_zone(
    host: StringSlice,
) raises NetError -> Tuple[String, UInt32]:
    var input = host.as_bytes()
    var separator = -1
    for i in range(len(input)):
        var byte = input[i]
        if byte == 0:
            raise _invalid_socket_address()
        if byte == Byte(ord("%")):
            if separator >= 0:
                raise _invalid_socket_address()
            separator = i
    if separator < 0:
        return String(host), 0
    if separator == 0 or separator == len(input) - 1:
        raise _invalid_socket_address()

    var address = String(from_utf8_lossy=input[0:separator])
    var zone = String(from_utf8_lossy=input[separator + 1 : len(input)])
    var scope_id = _resolve_zone(zone)
    return address^, scope_id


def _resolution_error(status: Int32) -> NetError:
    return NetError(
        NetErrorKind.resolution_failed(),
        "resolve socket address",
        Int(status),
        "name resolution failed",
    )


def _free_addrinfo(address: Pointer[Byte, MutUntrackedOrigin]):
    external_call["freeaddrinfo", NoneType](address)


def resolve_socket_addresses(
    value: StringSlice, socket_type: Int32
) raises NetError -> List[SocketAddress]:
    var host, port = split_host_port(value)
    var address_text, scope_id = _split_host_zone(host)

    try:
        var ip = IPAddress.parse(address_text)
        if scope_id != 0 and not ip.is_ipv6():
            raise _invalid_socket_address()
        var numeric = List[SocketAddress]()
        numeric.append(
            SocketAddress(ip=ip.copy(), port=port, scope_id=scope_id)
        )
        return numeric^
    except error:
        if scope_id != 0:
            raise error^

    var service = String(port)
    var c_host = host.as_c_string_slice()
    var c_service = service.as_c_string_slice()
    var hints = _ResolverHints(socket_type)
    var result: Optional[Pointer[Byte, MutUntrackedOrigin]] = None
    var status = external_call["getaddrinfo", c_int](
        c_host.unsafe_ptr(),
        c_service.unsafe_ptr(),
        hints.unsafe_ptr(),
        Pointer(to=result),
    )
    if status != 0:
        raise _resolution_error(status)
    if not result:
        raise _resolution_error(status)

    var head = result.value()
    var current = result
    var addresses = List[SocketAddress]()
    var count = 0
    try:
        while current and count < 64:
            var info = current.value()
            var family = _addrinfo_family(info)
            if family == AF_INET or family == AF_INET6:
                var raw = _addrinfo_address(info)
                if not raw:
                    raise _invalid_raw_socket_address()
                addresses.append(
                    _socket_address_from_raw(
                        raw.value(), _addrinfo_address_length(info)
                    )
                )
            current = _addrinfo_next(info)
            count += 1
    except error:
        _free_addrinfo(head)
        raise error^
    _free_addrinfo(head)
    if len(addresses) == 0:
        raise _resolution_error(status)
    return addresses^


def _v6only_for_listen(address: SocketAddress, ipv6_only: Bool) -> Bool:
    return address.ip.is_ipv6() and (
        ipv6_only or not address.ip.is_unspecified()
    )


def _listen_addresses(
    value: StringSlice, socket_type: Int32
) raises NetError -> List[SocketAddress]:
    var host, port = _split_host_port(value, True)
    if host.byte_length() != 0:
        return resolve_socket_addresses(value, socket_type)
    var addresses = List[SocketAddress]()
    addresses.append(
        SocketAddress(ip=IPAddress.parse("::"), port=port, scope_id=0)
    )
    addresses.append(
        SocketAddress(ip=IPAddress.parse("0.0.0.0"), port=port, scope_id=0)
    )
    return addresses^
