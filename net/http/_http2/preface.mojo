"""Incremental parsing of the HTTP/2 client connection preface."""


@fieldwise_init
struct PrefaceParseResult(Movable):
    var kind: UInt8
    var consumed: Int

    @staticmethod
    def need_more() -> Self:
        return Self(kind=0, consumed=0)

    @staticmethod
    def complete(consumed: Int) -> Self:
        return Self(kind=1, consumed=consumed)

    @staticmethod
    def failure() -> Self:
        return Self(kind=2, consumed=0)

    def is_need_more(self) -> Bool:
        return self.kind == 0

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def parse_client_preface[
    origin: Origin
](data: Span[Byte, origin]) -> PrefaceParseResult:
    var expected = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".as_bytes()
    var compared = len(data)
    if compared > len(expected):
        compared = len(expected)

    for i in range(compared):
        if data[i] != expected[i]:
            return PrefaceParseResult.failure()

    if len(data) < len(expected):
        return PrefaceParseResult.need_more()
    return PrefaceParseResult.complete(len(expected))
