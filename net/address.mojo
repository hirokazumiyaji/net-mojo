from .error import NetError, NetErrorKind
from .ip import IPAddress


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
                writer.write(self.scope_id)
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
    var host = String("")
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
                    host += value[byte=i]
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
                host += value[byte=i]
            continue
        _parse_port_digit(byte, port_value, port_digits)

    if bracketed:
        if not bracket_closed or not separator_found or host.byte_length() == 0:
            raise _invalid_socket_address()
    elif not separator_found:
        raise _invalid_socket_address()
    if host.byte_length() == 0 and not allow_empty_host:
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
    var input = host.as_bytes()
    var address_text = String("")
    var scope_id = UInt32(0)
    var scope_separator = -1

    for i in range(len(input)):
        var byte = input[i]
        if byte == Byte(ord("%")):
            if scope_separator >= 0:
                raise _invalid_socket_address()
            scope_separator = i
        elif scope_separator < 0:
            address_text += host[byte=i]
        else:
            if byte < Byte(ord("0")) or byte > Byte(ord("9")):
                raise _invalid_socket_address()
            var digit = UInt32(byte - Byte(ord("0")))
            if scope_id > (UInt32.MAX - digit) // 10:
                raise _invalid_socket_address()
            scope_id = scope_id * 10 + digit

    if scope_separator < 0:
        address_text = host^
    elif (
        scope_separator == 0
        or scope_separator == len(input) - 1
        or scope_id == 0
    ):
        raise _invalid_socket_address()

    var ip = IPAddress.parse(address_text)
    var original = value.as_bytes()
    if original[0] == Byte(ord("[")):
        if not ip.is_ipv6():
            raise _invalid_socket_address()
    elif ip.is_ipv6():
        raise _invalid_socket_address()
    if scope_separator >= 0 and not ip.is_ipv6():
        raise _invalid_socket_address()
    return SocketAddress(ip=ip.copy(), port=port, scope_id=scope_id)
