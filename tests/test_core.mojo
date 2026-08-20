from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from net.error import NetError, NetErrorKind
from net.timeout import Timeout, _Deadline


def test_error_classification() raises:
    var error = NetError(
        NetErrorKind.timeout(), "read", None, "operation timed out"
    )
    assert_true(error.is_timeout())
    assert_equal(String(error), "read: operation timed out")


def test_zero_timeout_expires_immediately() raises:
    var deadline = _Deadline.from_timeout(Timeout.nanoseconds(0))
    assert_true(deadline.expired())
    assert_equal(deadline.remaining_milliseconds(), 0)


def test_none_deadline_never_expires() raises:
    var deadline = _Deadline.from_optional(None)
    assert_false(deadline.expired())


def test_timeout_conversion_overflow() raises:
    with assert_raises():
        _ = Timeout.seconds(UInt64.MAX)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
