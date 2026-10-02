"""Authority and host syntax shared by HTTP protocols."""


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
