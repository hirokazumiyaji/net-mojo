from std.time import perf_counter_ns

from .error import NetError, NetErrorKind


@fieldwise_init
struct Timeout(Copyable, Equatable, Hashable, Writable):
    var _value: UInt64

    @staticmethod
    def nanoseconds(value: UInt64) -> Self:
        return Self(_value=value)

    @staticmethod
    def milliseconds(value: UInt64) raises NetError -> Self:
        return Self.nanoseconds(Self._scaled(value, 1_000_000))

    @staticmethod
    def seconds(value: UInt64) raises NetError -> Self:
        return Self.nanoseconds(Self._scaled(value, 1_000_000_000))

    @staticmethod
    def _scaled(value: UInt64, scale: UInt64) raises NetError -> UInt64:
        if value > UInt64.MAX // scale:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "timeout",
                None,
                "timeout is too large",
            )
        return value * scale

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self._value)


struct _Deadline(Copyable):
    var _expires_at: Optional[Int]

    def __init__(out self, _expires_at: Optional[Int]):
        self._expires_at = _expires_at.copy()

    @staticmethod
    def from_timeout(timeout: Timeout) -> Self:
        var now = perf_counter_ns()
        if timeout._value > UInt64(Int.MAX - now):
            return Self(_expires_at=Int.MAX)
        return Self(_expires_at=now + Int(timeout._value))

    @staticmethod
    def from_optional(timeout: Optional[Timeout]) -> Self:
        if timeout:
            return Self.from_timeout(timeout.value())
        return Self(_expires_at=None)

    def is_indefinite(self) -> Bool:
        if self._expires_at:
            return False
        return True

    def expired(self) -> Bool:
        if self._expires_at:
            return perf_counter_ns() >= self._expires_at.value()
        return False

    def remaining_milliseconds(self) -> Int:
        if not self._expires_at:
            return Int.MAX
        var remaining = self._expires_at.value() - perf_counter_ns()
        if remaining <= 0:
            return 0
        var milliseconds = remaining // 1_000_000
        if remaining % 1_000_000 != 0:
            milliseconds += 1
        return milliseconds
