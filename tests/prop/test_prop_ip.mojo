from std.testing import assert_equal
from proptest import Settings, TestCase, for_all, integers
from net import IPAddress


def _check_roundtrip(address: IPAddress) raises:
    var text = String(address)
    var parsed = IPAddress.parse(text)
    assert_equal(parsed, address)
    assert_equal(hash(parsed), hash(address))
    assert_equal(String(parsed), text)


def _ipv4_roundtrip(mut tc: TestCase) raises:
    var a = tc.draw(integers(0, 255), "a")
    var b = tc.draw(integers(0, 255), "b")
    var c = tc.draw(integers(0, 255), "c")
    var d = tc.draw(integers(0, 255), "d")
    _check_roundtrip(IPAddress(Byte(a), Byte(b), Byte(c), Byte(d)))


def _ipv6_roundtrip(mut tc: TestCase) raises:
    var raw = Array[Byte, 16](fill=0)
    for i in range(16):
        raw[i] = Byte(tc.draw(integers(0, 255), "byte-" + String(i)))
    _check_roundtrip(IPAddress(raw^))


def _ipv6_zero_run_roundtrip(mut tc: TestCase) raises:
    var raw = Array[Byte, 16](fill=0)
    for i in range(16):
        raw[i] = Byte(tc.draw(integers(0, 255), "byte-" + String(i)))
    var start = tc.draw(integers(0, 7), "zero-start")
    var count = tc.draw(integers(1, 8 - start), "zero-count")
    for i in range(start * 2, (start + count) * 2):
        raw[i] = 0
    _check_roundtrip(IPAddress(raw^))


def _ipv4_mapped_roundtrip(mut tc: TestCase) raises:
    var raw = Array[Byte, 16](fill=0)
    raw[10] = 255
    raw[11] = 255
    for i in range(12, 16):
        raw[i] = Byte(tc.draw(integers(0, 255), "tail-" + String(i)))
    _check_roundtrip(IPAddress(raw^))


def main() raises:
    print("::group::IP round-trip properties")
    try:
        for_all(_ipv4_roundtrip, Settings(name="net-ipv4-roundtrip"))
        for_all(_ipv6_roundtrip, Settings(name="net-ipv6-roundtrip"))
        for_all(_ipv6_zero_run_roundtrip, Settings(name="net-ipv6-zero-run"))
        for_all(_ipv4_mapped_roundtrip, Settings(name="net-ipv4-mapped"))
    finally:
        print("::endgroup::")
