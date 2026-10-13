from std.testing import assert_equal, assert_raises
from proptest import Settings, TestCase, for_all, integers, integers_of
from net import IPAddress, SocketAddress, join_host_port, split_host_port
from net.address import _split_host_port


def _address_roundtrip(mut tc: TestCase) raises:
    var family = tc.draw(integers(0, 1), "family")
    var raw = Array[Byte, 16](fill=0)
    for i in range(16 if family else 4):
        raw[i] = Byte(tc.draw(integers(0, 255), "byte-" + String(i)))
    var ip = IPAddress(raw^) if family else IPAddress(
        raw[0], raw[1], raw[2], raw[3]
    )
    var port = UInt16(tc.draw(integers(0, 65535), "port"))
    var scope = UInt32(0)
    if family:
        scope = tc.draw(integers_of[DType.uint32](0, UInt32.MAX), "scope")
    var address = SocketAddress(ip=ip^, port=port, scope_id=scope)
    var parsed = SocketAddress.parse(String(address))
    assert_equal(parsed, address)
    assert_equal(hash(parsed), hash(address))
    var host, split_port = split_host_port(String(address))
    assert_equal(split_port, port)
    assert_equal(SocketAddress.parse(join_host_port(host, port)), address)


def _empty_host(mut tc: TestCase) raises:
    var port = UInt16(tc.draw(integers(0, 65535), "port"))
    var wire = join_host_port("", port)
    var host, parsed_port = _split_host_port(wire, True)
    assert_equal(host, "")
    assert_equal(parsed_port, port)
    with assert_raises():
        _ = split_host_port(wire)


def _invalid_port(mut tc: TestCase) raises:
    var port = tc.draw(integers(65536, 999999), "invalid-port")
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1:" + String(port))
    with assert_raises():
        _ = SocketAddress.parse("[::1]:" + String(port))


def main() raises:
    for_all(_address_roundtrip, Settings(name="net-address-roundtrip"))
    for_all(_empty_host, Settings(name="net-address-empty-host"))
    for_all(_invalid_port, Settings(name="net-address-invalid-port"))
