"""RFC 6455 handshake digest without an optional TLS dependency."""

comptime _BASE64 = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
)


def _base64_value(value: Byte) -> Int:
    if value >= 65 and value <= 90:
        return Int(value) - 65
    if value >= 97 and value <= 122:
        return Int(value) - 97 + 26
    if value >= 48 and value <= 57:
        return Int(value) - 48 + 52
    if value == 43:
        return 62
    if value == 47:
        return 63
    return -1


def _valid_websocket_key(key: StringSlice) -> Bool:
    if key.byte_length() != 24:
        return False
    var bytes = key.as_bytes()
    for i in range(22):
        if _base64_value(bytes[i]) < 0:
            return False
    return (
        bytes[22] == 61
        and bytes[23] == 61
        and (_base64_value(bytes[21]) & 15) == 0
    )


def _rotate(value: UInt32, bits: Int) -> UInt32:
    return (value << UInt32(bits)) | (value >> UInt32(32 - bits))


def _sha1[o: ImmOrigin](input: Span[Byte, o]) -> List[Byte]:
    var bytes = List[Byte]()
    bytes.extend(input)
    bytes.append(128)
    while len(bytes) % 64 != 56:
        bytes.append(0)
    var bit_length = UInt64(len(input)) * 8
    for i in range(8):
        bytes.append(Byte((bit_length >> UInt64((7 - i) * 8)) & 255))
    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xEFCDAB89
    var h2: UInt32 = 0x98BADCFE
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xC3D2E1F0
    for offset in range(0, len(bytes), 64):
        var words = List[UInt32](length=80, fill=0)
        for i in range(16):
            var at = offset + i * 4
            words[i] = (
                (UInt32(bytes[at]) << 24)
                | (UInt32(bytes[at + 1]) << 16)
                | (UInt32(bytes[at + 2]) << 8)
                | UInt32(bytes[at + 3])
            )
        for i in range(16, 80):
            words[i] = _rotate(
                words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16], 1
            )
        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        for i in range(80):
            var f: UInt32
            var k: UInt32
            if i < 20:
                f = (b & c) | ((~b) & d)
                k = 0x5A827999
            elif i < 40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            elif i < 60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            else:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            var next_a = _rotate(a, 5) + f + e + k + words[i]
            e = d
            d = c
            c = _rotate(b, 30)
            b = a
            a = next_a
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e
    var digest = List[Byte]()
    for word in [h0, h1, h2, h3, h4]:
        for i in range(4):
            digest.append(Byte((word >> UInt32((3 - i) * 8)) & 255))
    return digest^


def _base64_encode[o: ImmOrigin](input: Span[Byte, o]) -> String:
    var output = String()
    for at in range(0, len(input), 3):
        var value = UInt32(input[at]) << 16
        var remaining = min(3, len(input) - at)
        if remaining > 1:
            value |= UInt32(input[at + 1]) << 8
        if remaining > 2:
            value |= UInt32(input[at + 2])
        for shift in [18, 12, 6, 0]:
            if shift == 6 and remaining < 2 or shift == 0 and remaining < 3:
                output += "="
            else:
                output += _BASE64[byte=Int((value >> UInt32(shift)) & 63)]
    return output^


def _websocket_accept_key(key: StringSlice) -> String:
    var challenge = String(key) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    var digest = _sha1(challenge.as_bytes())
    return _base64_encode(Span(digest))
