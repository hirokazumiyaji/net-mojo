from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from net import Timeout, dial_tcp, listen_tcp
from net.error import NetError, NetErrorKind
from net.timeout import Timeout, _Deadline


def test_error_classification() raises:
    var error = NetError(
        NetErrorKind.timeout(), "read", None, "operation timed out"
    )
    assert_true(error.is_timeout())
    assert_equal(String(error), "read: operation timed out")


def test_error_kind_formats_its_name() raises:
    assert_equal(String(NetErrorKind.invalid_address()), "invalid_address")
    assert_equal(String(NetErrorKind.timeout()), "timeout")
    assert_equal(String(NetErrorKind.unsupported()), "unsupported")


def test_zero_timeout_expires_immediately() raises:
    var deadline = _Deadline.from_timeout(Timeout.nanoseconds(0))
    assert_true(deadline.expired())
    assert_equal(deadline.remaining_milliseconds(), 0)


def test_none_deadline_never_expires() raises:
    var deadline = _Deadline.from_optional(None)
    assert_false(deadline.expired())
    assert_true(deadline.is_indefinite())


def test_timed_deadline_is_not_indefinite() raises:
    var deadline = _Deadline.from_timeout(Timeout.seconds(1))
    assert_false(deadline.is_indefinite())


def test_timeout_conversion_overflow() raises:
    with assert_raises():
        _ = Timeout.seconds(UInt64.MAX)


def test_system_error_reports_strerror_and_errno() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var address = String(listener.local_address())
    listener.close()
    try:
        _ = dial_tcp(address, Timeout.seconds(1))
    except error:
        assert_equal(error.kind, NetErrorKind.system_error())
        var errno_value = -1
        if error.errno:
            errno_value = error.errno.value()
        assert_true(errno_value > 0)
        assert_true(error.has_errno(Int32(errno_value)))
        if error.resolver_status:
            raise Error("system error leaked a resolver status")
        assert_equal(error.message, "Connection refused")
        var expected = String(
            t"connect: Connection refused (errno {errno_value})"
        )
        assert_equal(String(error), expected)
        return
    raise Error("connection unexpectedly succeeded")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
