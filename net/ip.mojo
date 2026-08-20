from .error import NetError, NetErrorKind


@fieldwise_init
struct AddressFamily(Copyable, Equatable, Hashable, Writable):
    var value: UInt8

    @staticmethod
    def ipv4() -> Self:
        return Self(value=4)

    @staticmethod
    def ipv6() -> Self:
        return Self(value=6)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.value)


@fieldwise_init
struct IPAddress(Copyable, Equatable, Hashable, Writable):
    var _family: AddressFamily
    var _bytes: Array[Byte, 16]

    @staticmethod
    def parse(value: StringSlice) raises NetError -> Self:
        var input = value.as_bytes()
        var has_colon = False
        for i in range(len(input)):
            if input[i] == Byte(ord(":")):
                has_colon = True
                break
        if has_colon:
            return _parse_ipv6(value)
        return _parse_ipv4(value)

    def is_ipv4(self) -> Bool:
        return self._family == AddressFamily.ipv4()

    def is_ipv6(self) -> Bool:
        return self._family == AddressFamily.ipv6()

    def as_bytes(self) -> Span[Byte, origin_of(self._bytes)]:
        return Span(self._bytes)

    def write_to[W: Writer](self, mut writer: W):
        if self.is_ipv4():
            writer.write(Int(self._bytes[0]))
            writer.write(".")
            writer.write(Int(self._bytes[1]))
            writer.write(".")
            writer.write(Int(self._bytes[2]))
            writer.write(".")
            writer.write(Int(self._bytes[3]))
            return
        _write_ipv6(self._bytes, writer)


def _invalid_address() -> NetError:
    return NetError(
        NetErrorKind.invalid_address(),
        "parse IP address",
        None,
        "invalid IP address",
    )


def _parse_ipv4_components(
    value: StringSlice, start: Int, end: Int
) raises NetError -> Array[Byte, 4]:
    var result = Array[Byte, 4](fill=0)
    var input = value.as_bytes()
    var component = 0
    var accumulator = 0
    var digits = 0
    for i in range(start, end):
        var byte = input[i]
        if byte == Byte(ord(".")):
            if digits == 0 or component >= 3:
                raise _invalid_address()
            result[component] = Byte(accumulator)
            component += 1
            accumulator = 0
            digits = 0
            continue
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            raise _invalid_address()
        if digits > 0 and accumulator == 0:
            raise _invalid_address()
        accumulator = accumulator * 10 + Int(byte - Byte(ord("0")))
        digits += 1
        if accumulator > 255:
            raise _invalid_address()
    if digits == 0 or component != 3:
        raise _invalid_address()
    result[3] = Byte(accumulator)
    return result^


def _parse_ipv4(value: StringSlice) raises NetError -> IPAddress:
    var components = _parse_ipv4_components(value, 0, value.byte_length())
    return _from_ipv4_bytes(
        components[0], components[1], components[2], components[3]
    )


def _hex_value(byte: Byte) raises NetError -> UInt16:
    if byte >= Byte(ord("0")) and byte <= Byte(ord("9")):
        return UInt16(byte - Byte(ord("0")))
    if byte >= Byte(ord("a")) and byte <= Byte(ord("f")):
        return UInt16(byte - Byte(ord("a"))) + 10
    if byte >= Byte(ord("A")) and byte <= Byte(ord("F")):
        return UInt16(byte - Byte(ord("A"))) + 10
    raise _invalid_address()


def _parse_ipv6(value: StringSlice) raises NetError -> IPAddress:
    var input = value.as_bytes()
    var length = len(input)
    if length == 0:
        raise _invalid_address()

    var hextets = Array[UInt16, 8](fill=0)
    var count = 0
    var compression = -1
    var i = 0

    if input[0] == Byte(ord(":")):
        if length < 2 or input[1] != Byte(ord(":")):
            raise _invalid_address()
        compression = 0
        i = 2

    while i < length:
        if count >= 8:
            raise _invalid_address()
        var token_start = i
        var has_dot = False
        while i < length and input[i] != Byte(ord(":")):
            if input[i] == Byte(ord(".")):
                has_dot = True
            i += 1
        var token_end = i
        if token_start == token_end:
            raise _invalid_address()

        if has_dot:
            if token_end != length or count > 6:
                raise _invalid_address()
            var ipv4 = _parse_ipv4_components(value, token_start, length)
            hextets[count] = (UInt16(ipv4[0]) << 8) | UInt16(ipv4[1])
            hextets[count + 1] = (UInt16(ipv4[2]) << 8) | UInt16(ipv4[3])
            count += 2
            break

        var digits = token_end - token_start
        if digits > 4:
            raise _invalid_address()
        var hextet = UInt16(0)
        for digit_index in range(token_start, token_end):
            hextet = (hextet << 4) | _hex_value(input[digit_index])
        hextets[count] = hextet
        count += 1

        if i == length:
            break
        if i + 1 < length and input[i + 1] == Byte(ord(":")):
            if compression >= 0:
                raise _invalid_address()
            compression = count
            i += 2
        else:
            i += 1
            if i == length:
                raise _invalid_address()

    if compression < 0:
        if count != 8:
            raise _invalid_address()
    elif count >= 8:
        raise _invalid_address()

    var result = Array[Byte, 16](fill=0)
    var compressed_count = 8 - count
    for output_index in range(8):
        var hextet = UInt16(0)
        if compression < 0 or output_index < compression:
            hextet = hextets[output_index]
        elif output_index >= compression + compressed_count:
            hextet = hextets[output_index - compressed_count]
        result[output_index * 2] = Byte(hextet >> 8)
        result[output_index * 2 + 1] = Byte(hextet & 0xFF)
    return _from_ipv6_bytes(result^)


def _from_ipv4_bytes(
    byte0: Byte, byte1: Byte, byte2: Byte, byte3: Byte
) -> IPAddress:
    var bytes = Array[Byte, 16](fill=0)
    bytes[0] = byte0
    bytes[1] = byte1
    bytes[2] = byte2
    bytes[3] = byte3
    return IPAddress(_family=AddressFamily.ipv4(), _bytes=bytes^)


def _from_ipv6_bytes(var bytes: Array[Byte, 16]) -> IPAddress:
    return IPAddress(_family=AddressFamily.ipv6(), _bytes=bytes^)


def _write_hextet[W: Writer](value: UInt16, mut writer: W):
    var started = False
    for shift in range(12, -1, -4):
        var digit = Int((value >> UInt16(shift)) & 0xF)
        if digit != 0 or started or shift == 0:
            writer.write("0123456789abcdef"[byte=digit])
            started = True


def _write_ipv6[W: Writer](bytes: Array[Byte, 16], mut writer: W):
    var hextets = Array[UInt16, 8](fill=0)
    for i in range(8):
        hextets[i] = (UInt16(bytes[i * 2]) << 8) | UInt16(bytes[i * 2 + 1])

    var best_start = -1
    var best_length = 0
    var run_start = 0
    var run_length = 0
    for i in range(8):
        if hextets[i] == 0:
            if run_length == 0:
                run_start = i
            run_length += 1
            if run_length > best_length:
                best_start = run_start
                best_length = run_length
        else:
            run_length = 0
    if best_length < 2:
        best_start = -1
        best_length = 0

    var i = 0
    while i < 8:
        if i == best_start:
            writer.write("::")
            i += best_length
            continue
        if i > 0 and i != best_start + best_length:
            writer.write(":")
        _write_hextet(hextets[i], writer)
        i += 1
