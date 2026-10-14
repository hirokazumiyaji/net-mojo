"""Pure configuration and content-coding negotiation for opt-in compression."""

from net.error import NetError, NetErrorKind


@fieldwise_init
struct CompressionConfig(Copyable, Movable):
    var level: Int
    var min_size: Int
    var skip_content_types: List[String]
    var skip_content_type_prefixes: List[String]
    var skip_extensions: List[String]
    var buffer_size: Int

    @staticmethod
    def default() -> Self:
        return Self(
            level=5,
            min_size=1024,
            skip_content_types=[
                "application/zip",
                "application/gzip",
                "application/x-7z-compressed",
                "font/woff",
                "font/woff2",
            ],
            skip_content_type_prefixes=["image/", "video/", "audio/"],
            skip_extensions=[".gz", ".br", ".zst"],
            buffer_size=32768,
        )

    def validate(self) raises NetError:
        if self.level < 1 or self.level > 9:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "configure compression",
                None,
                "gzip level must be between 1 and 9",
            )
        if self.min_size < 0 or self.buffer_size <= 0:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "configure compression",
                None,
                "minimum size must be nonnegative and buffer size positive",
            )


def _quality(value: StringSlice) -> Int:
    var text = String(value).strip(" \t")
    var bytes = text.as_bytes()
    if len(bytes) == 0 or (bytes[0] != Byte(48) and bytes[0] != Byte(49)):
        return -1
    var result = Int(bytes[0] - Byte(48)) * 1000
    if len(bytes) == 1:
        return result
    if len(bytes) > 5 or bytes[1] != Byte(46):
        return -1
    var scale = 100
    for i in range(2, len(bytes)):
        if bytes[i] < Byte(48) or bytes[i] > Byte(57):
            return -1
        var digit = Int(bytes[i] - Byte(48))
        if result == 1000 and digit != 0:
            return -1
        result += digit * scale
        scale //= 10
    return result


def negotiate_encoding(
    accept_encoding: StringSlice, supported: List[String]
) -> Optional[String]:
    """Select an owned supported coding; no selection means identity fallback.
    """
    var entries = accept_encoding.split(",")
    var best_quality = 0
    var best_position = len(entries)
    var best: Optional[String] = None
    for coding in supported:
        var supported_coding = coding.lower()
        var specific_quality = -1
        var specific_position = len(entries)
        var wildcard_quality = -1
        var wildcard_position = len(entries)
        for position in range(len(entries)):
            var fields = entries[position].split(";")
            var name = String(fields[0]).strip(" \t").lower()
            if name != supported_coding and name != "*":
                continue
            var quality = 1000
            if len(fields) > 2:
                quality = -1
            elif len(fields) == 2:
                var parameter = fields[1].split("=")
                if (
                    len(parameter) != 2
                    or String(parameter[0]).strip(" \t").lower() != "q"
                ):
                    quality = -1
                else:
                    quality = _quality(parameter[1])
            if quality < 0:
                continue
            if name == supported_coding:
                if quality > specific_quality:
                    specific_quality = quality
                    specific_position = position
            elif quality > wildcard_quality:
                wildcard_quality = quality
                wildcard_position = position
        var quality = specific_quality
        var position = specific_position
        if quality < 0:
            quality = wildcard_quality
            position = wildcard_position
        if quality > best_quality or (
            quality > 0 and quality == best_quality and position < best_position
        ):
            best_quality = quality
            best_position = position
            best = supported_coding^
    return best^
