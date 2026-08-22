from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from net import IPAddress
from net.ip import _from_ipv4_bytes, _from_ipv6_bytes


def test_canonical_formatting() raises:
    assert_equal(String(IPAddress.parse("192.0.2.1")), "192.0.2.1")
    assert_equal(
        String(IPAddress.parse("2001:0db8:0:0:0:0:0:1")), "2001:db8::1"
    )
    assert_equal(
        String(IPAddress.parse("2001:0:0:1:0:0:1:1")),
        "2001::1:0:0:1:1",
    )
    assert_equal(String(IPAddress.parse("::ffff:192.0.2.1")), "::ffff:c000:201")


def test_single_zero_hextet_is_not_compressed() raises:
    assert_equal(
        String(IPAddress.parse("2001:db8:0:1:1:1:1:1")),
        "2001:db8:0:1:1:1:1:1",
    )


def test_address_family_is_part_of_equality() raises:
    assert_true(IPAddress.parse("127.0.0.1").is_ipv4())
    assert_true(IPAddress.parse("::1").is_ipv6())
    assert_false(
        IPAddress.parse("192.0.2.1") == IPAddress.parse("::ffff:192.0.2.1")
    )


def test_ipv4_bytes_are_normalized_to_sixteen_bytes() raises:
    var bytes = IPAddress.parse("192.0.2.1").as_bytes()
    assert_equal(len(bytes), 16)
    assert_equal(Int(bytes[0]), 192)
    assert_equal(Int(bytes[1]), 0)
    assert_equal(Int(bytes[2]), 2)
    assert_equal(Int(bytes[3]), 1)
    for i in range(4, 16):
        assert_equal(Int(bytes[i]), 0)


def test_ipv4_raw_bytes_build_a_normalized_ipv4_value() raises:
    var address = _from_ipv4_bytes(192, 0, 2, 1)
    assert_true(address.is_ipv4())
    assert_equal(String(address), "192.0.2.1")
    var bytes = address.as_bytes()
    for i in range(4, 16):
        assert_equal(Int(bytes[i]), 0)


def test_ipv6_raw_bytes_build_an_ipv6_value() raises:
    var bytes: Array[Byte, 16] = [
        0x20,
        0x01,
        0x0D,
        0xB8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
    ]
    var address = _from_ipv6_bytes(bytes^)
    assert_true(address.is_ipv6())
    assert_equal(String(address), "2001:db8::1")


def test_rejects_malformed_addresses() raises:
    with assert_raises():
        _ = IPAddress.parse("01.2.3.4")
    with assert_raises():
        _ = IPAddress.parse("256.0.0.1")
    with assert_raises():
        _ = IPAddress.parse("1.2.3")
    with assert_raises():
        _ = IPAddress.parse("1.2.3.4.5")
    with assert_raises():
        _ = IPAddress.parse("2001::db8::1")
    with assert_raises():
        _ = IPAddress.parse("12345::1")
    with assert_raises():
        _ = IPAddress.parse(":::1")
    with assert_raises():
        _ = IPAddress.parse("")
    with assert_raises():
        _ = IPAddress.parse("+1.2.3.4")
    with assert_raises():
        _ = IPAddress.parse("-1.2.3.4")
    with assert_raises():
        _ = IPAddress.parse(" 1.2.3.4")
    with assert_raises():
        _ = IPAddress.parse("1.2.3.4 ")
    with assert_raises():
        _ = IPAddress.parse("1.2.3.4\0")


def test_rejects_zero_width_compression() raises:
    with assert_raises():
        _ = IPAddress.parse("1:2:3:4:5:6:7:8::")
    with assert_raises():
        _ = IPAddress.parse("::1:2:3:4:5:6:7:8")


def test_rejects_ipv4_tail_before_end() raises:
    with assert_raises():
        _ = IPAddress.parse("::ffff:192.0.2.1:1")
    with assert_raises():
        _ = IPAddress.parse("1:2:3:4:5:6:192.0.2.1:1")


def test_parse_format_round_trips_preserve_value_and_hash() raises:
    var addresses = [
        "0.0.0.0",
        "255.255.255.255",
        "::",
        "::1",
        "1::",
        "2001:db8:0:1:1:1:1:1",
        "2001:0:0:1:0:0:1:1",
        "::ffff:192.0.2.1",
    ]
    for address in addresses:
        var first = IPAddress.parse(address)
        var second = IPAddress.parse(String(first))
        assert_equal(first, second)
        assert_equal(hash(first), hash(second))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
