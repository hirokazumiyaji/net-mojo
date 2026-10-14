"""Incremental RFC 6455 frames, bounded before payload allocation."""


@fieldwise_init
struct _WebSocketProtocolError(Copyable, Movable):
    var code: UInt16
    var reason: String


@fieldwise_init
struct _WebSocketFrame(Movable):
    var opcode: UInt8
    var fin: Bool
    var payload: List[Byte]


struct _UTF8Validator(Copyable, Movable):
    var _remaining: Int
    var _low: Byte
    var _high: Byte
    var _valid: Bool

    def __init__(out self):
        self._remaining = 0
        self._low = 128
        self._high = 191
        self._valid = True

    def feed[o: ImmOrigin](mut self, input: Span[Byte, o]) -> Bool:
        if not self._valid:
            return False
        for byte in input:
            if self._remaining > 0:
                if byte < self._low or byte > self._high:
                    self._valid = False
                    return False
                self._remaining -= 1
                self._low = 128
                self._high = 191
            elif byte <= 127:
                pass
            elif byte >= 194 and byte <= 223:
                self._remaining = 1
            elif byte >= 224 and byte <= 239:
                self._remaining = 2
                if byte == 224:
                    self._low = 160
                elif byte == 237:
                    self._high = 159
            elif byte >= 240 and byte <= 244:
                self._remaining = 3
                if byte == 240:
                    self._low = 144
                elif byte == 244:
                    self._high = 143
            else:
                self._valid = False
                return False
        return True

    def complete(self) -> Bool:
        return self._valid and self._remaining == 0


def _valid_close_code(code: UInt16) -> Bool:
    return (
        code >= 1000
        and code <= 1014
        and code != 1004
        and code != 1005
        and code != 1006
    ) or (code >= 3000 and code <= 4999)


def _validate_close[
    o: ImmOrigin
](payload: Span[Byte, o]) raises _WebSocketProtocolError:
    if len(payload) == 1:
        raise _WebSocketProtocolError(
            1002, "close payload needs a two-byte code"
        )
    if len(payload) >= 2:
        var code = (UInt16(payload[0]) << 8) | UInt16(payload[1])
        if not _valid_close_code(code):
            raise _WebSocketProtocolError(1002, "invalid close code")
        var validator = _UTF8Validator()
        if not validator.feed(payload[2:]) or not validator.complete():
            raise _WebSocketProtocolError(1007, "invalid close reason UTF-8")


struct _FrameDecoder(Movable):
    var _header: List[Byte]
    var _header_length: Int
    var _payload_length: Int
    var _payload: List[Byte]
    var _limit: Int
    var _parsed: Bool
    var _opcode: UInt8
    var _fin: Bool

    def __init__(out self, limit: Int):
        self._header = List[Byte]()
        self._header_length = 2
        self._payload_length = 0
        self._payload = List[Byte]()
        self._limit = limit
        self._parsed = False
        self._opcode = 0
        self._fin = False

    def complete(self) -> Bool:
        return self._parsed and len(self._payload) == self._payload_length

    def needed(self) -> Int:
        if self._parsed:
            return self._payload_length - len(self._payload)
        return self._header_length - len(self._header)

    def _parse_prefix(mut self) raises _WebSocketProtocolError:
        var first = self._header[0]
        self._opcode = first & 15
        self._fin = (first & 128) != 0
        if (first & 112) != 0 or not (
            self._opcode <= 2 or self._opcode >= 8 and self._opcode <= 10
        ):
            raise _WebSocketProtocolError(1002, "reserved frame bits or opcode")
        if (self._header[1] & 128) == 0:
            raise _WebSocketProtocolError(1002, "client frame must be masked")
        if self._opcode >= 8 and (
            not self._fin or (self._header[1] & 127) > 125
        ):
            raise _WebSocketProtocolError(1002, "invalid control frame")

    def _parse_header(mut self) raises _WebSocketProtocolError:
        var length_tag = self._header[1] & 127
        var length = UInt64(length_tag)
        if length_tag >= 126:
            var bytes = 2 if length_tag == 126 else 8
            length = 0
            for i in range(bytes):
                length = (length << 8) | UInt64(self._header[2 + i])
            if (length_tag == 126 and length < 126) or (
                length_tag == 127
                and (length < 65536 or (self._header[2] & 128) != 0)
            ):
                raise _WebSocketProtocolError(1002, "noncanonical frame length")
        if self._opcode >= 8 and (not self._fin or length > 125):
            raise _WebSocketProtocolError(1002, "invalid control frame")
        if length > UInt64(self._limit):
            raise _WebSocketProtocolError(
                1009, "frame exceeds configured limit"
            )
        self._payload_length = Int(length)
        self._parsed = True

    def feed[
        o: ImmOrigin
    ](mut self, input: Span[Byte, o]) raises _WebSocketProtocolError -> Int:
        var at = 0
        while at < len(input) and not self.complete():
            if not self._parsed:
                self._header.append(input[at])
                at += 1
                if len(self._header) == 2:
                    self._parse_prefix()
                    var tag = self._header[1] & 127
                    self._header_length = 6
                    if tag == 126:
                        self._header_length = 8
                    elif tag == 127:
                        self._header_length = 14
                if len(self._header) == self._header_length:
                    self._parse_header()
            else:
                var mask_at = self._header_length - 4
                var count = min(len(input) - at, self.needed())
                for i in range(count):
                    self._payload.append(
                        input[at + i]
                        ^ self._header[mask_at + len(self._payload) % 4]
                    )
                at += count
        return at

    def take_frame(mut self) raises _WebSocketProtocolError -> _WebSocketFrame:
        if not self.complete():
            raise _WebSocketProtocolError(1002, "frame is incomplete")
        if self._opcode == 8:
            _validate_close(Span(self._payload))
        var frame = _WebSocketFrame(self._opcode, self._fin, self._payload^)
        self._payload = List[Byte]()
        self._header.clear()
        self._header_length = 2
        self._parsed = False
        self._payload_length = 0
        return frame^


def _encode_frame[
    o: ImmOrigin
](opcode: UInt8, fin: Bool, payload: Span[Byte, o]) -> List[Byte]:
    var output = List[Byte]()
    output.append(opcode | Byte(128 if fin else 0))
    if len(payload) < 126:
        output.append(Byte(len(payload)))
    elif len(payload) <= 65535:
        output.append(126)
        output.append(Byte((len(payload) >> 8) & 255))
        output.append(Byte(len(payload) & 255))
    else:
        output.append(127)
        for i in range(8):
            output.append(
                Byte((UInt64(len(payload)) >> UInt64((7 - i) * 8)) & 255)
            )
    output.extend(payload)
    return output^
