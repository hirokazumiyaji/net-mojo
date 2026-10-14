from std.testing import assert_equal, assert_true, assert_raises
from std.time import perf_counter_ns
from proptest import Settings, TestCase, for_all, integers_of
from net import Timeout
from net.timeout import _Deadline


def _units(mut tc: TestCase) raises:
    var seconds = tc.draw(
        integers_of[DType.uint64](0, UInt64.MAX // 1_000_000_000), "seconds"
    )
    var value = Timeout.seconds(seconds)
    assert_equal(value, Timeout.milliseconds(seconds * 1000))
    assert_equal(value, Timeout.nanoseconds(seconds * 1_000_000_000))


def _overflow(mut tc: TestCase) raises:
    var seconds = tc.draw(
        integers_of[DType.uint64](UInt64.MAX // 1_000_000_000 + 1, UInt64.MAX),
        "seconds",
    )
    var milliseconds = tc.draw(
        integers_of[DType.uint64](UInt64.MAX // 1_000_000 + 1, UInt64.MAX),
        "milliseconds",
    )
    with assert_raises():
        _ = Timeout.seconds(seconds)
    with assert_raises():
        _ = Timeout.milliseconds(milliseconds)


def _deadline(mut tc: TestCase) raises:
    var duration = tc.draw(
        integers_of[DType.uint64](0, UInt64.MAX), "nanoseconds"
    )
    var before = perf_counter_ns()
    var deadline = _Deadline.from_timeout(Timeout.nanoseconds(duration))
    var after = perf_counter_ns()
    var lower = Int.MAX
    if duration <= UInt64(Int.MAX - before):
        lower = before + Int(duration)
    var upper = Int.MAX
    if duration <= UInt64(Int.MAX - after):
        upper = after + Int(duration)
    var expires = deadline._expires_at.value()
    assert_true(expires >= lower)
    assert_true(expires <= upper)
    assert_true(not deadline.is_indefinite())


def main() raises:
    for_all(_units, Settings(name="net-timeout-units"))
    for_all(_overflow, Settings(name="net-timeout-overflow"))
    for_all(_deadline, Settings(name="net-deadline-saturation"))
