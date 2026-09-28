"""Socket-independent HTTP/2 SETTINGS payload encoding and parsing."""


@fieldwise_init
struct Setting(Movable):
    var identifier: UInt16
    var value: UInt32


@fieldwise_init
struct SettingsParseResult(Movable):
    var kind: UInt8
    var settings: List[Setting]

    @staticmethod
    def complete(var settings: List[Setting]) -> Self:
        return Self(kind=1, settings=settings^)

    @staticmethod
    def failure() -> Self:
        return Self(kind=2, settings=List[Setting]())

    def is_complete(self) -> Bool:
        return self.kind == 1

    def is_error(self) -> Bool:
        return self.kind == 2


def parse_settings_payload[
    origin: Origin
](data: Span[Byte, origin]) -> SettingsParseResult:
    if len(data) % 6 != 0:
        return SettingsParseResult.failure()

    var settings = List[Setting]()
    for offset in range(0, len(data), 6):
        var identifier = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        var value = (
            (UInt32(data[offset + 2]) << 24)
            | (UInt32(data[offset + 3]) << 16)
            | (UInt32(data[offset + 4]) << 8)
            | UInt32(data[offset + 5])
        )
        settings.append(Setting(identifier=identifier, value=value))
    return SettingsParseResult.complete(settings^)


def encode_settings_payload[
    origin: Origin
](settings: Span[Setting, origin]) -> List[Byte]:
    var payload = List[Byte]()
    for i in range(len(settings)):
        var identifier = Int(settings[i].identifier)
        var value = Int(settings[i].value)
        payload.append(Byte((identifier >> 8) & 0xFF))
        payload.append(Byte(identifier & 0xFF))
        payload.append(Byte((value >> 24) & 0xFF))
        payload.append(Byte((value >> 16) & 0xFF))
        payload.append(Byte((value >> 8) & 0xFF))
        payload.append(Byte(value & 0xFF))
    return payload^
