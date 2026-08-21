from std.sys import CompilationTarget
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from net import (
    IPAddress,
    SocketAddress,
    join_host_port,
    resolve_socket_addresses,
    split_host_port,
)
from net.address import (
    _resolve_zone,
    _socket_address_from_raw,
    _socket_address_to_raw,
    _split_host_port,
)
from net.error import NetErrorKind
from net._sys import SOCK_STREAM


def test_socket_address_parses_numeric_ipv4_and_formats_it() raises:
    var ipv4 = SocketAddress.parse("127.0.0.1:8080")
    assert_equal(ipv4.port, UInt16(8080))
    assert_equal(String(ipv4), "127.0.0.1:8080")


def test_socket_address_parses_scoped_ipv6_and_formats_it() raises:
    var ipv6 = SocketAddress.parse("[fe80::1%3]:443")
    assert_equal(ipv6.scope_id, UInt32(3))
    assert_equal(ipv6.ip, IPAddress.parse("fe80::1"))
    assert_equal(ipv6.port, UInt16(443))


def test_join_host_port_brackets_hosts_containing_colons() raises:
    assert_equal(join_host_port("::1", UInt16(80)), "[::1]:80")


def test_join_host_port_preserves_hosts_without_colons() raises:
    assert_equal(join_host_port("example.com", UInt16(80)), "example.com:80")


def test_split_host_port_accepts_hostnames_without_resolving_them() raises:
    var host, port = split_host_port("example.com:65535")
    assert_equal(host, "example.com")
    assert_equal(port, UInt16(65535))


def test_socket_address_rejects_invalid_dial_host_port_grammar() raises:
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1")
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1:")
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1:-1")
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1:65536")
    with assert_raises():
        _ = SocketAddress.parse("::1:443")
    with assert_raises():
        _ = SocketAddress.parse("[::1:443")
    with assert_raises():
        _ = SocketAddress.parse("[::1]]:443")
    with assert_raises():
        _ = SocketAddress.parse(":0")
    with assert_raises():
        _ = SocketAddress.parse("[fe80::1%loopback]:443")
    with assert_raises():
        _ = SocketAddress.parse("[fe80::1%0]:443")
    with assert_raises():
        _ = SocketAddress.parse("[fe80::1%4294967296]:443")
    with assert_raises():
        _ = SocketAddress.parse("[fe80::1%3%4]:443")
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1: 80")
    with assert_raises():
        _ = SocketAddress.parse(" 127.0.0.1:80")
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1:80\0")


def test_socket_address_accepts_port_and_scope_boundaries() raises:
    var ipv4 = SocketAddress.parse("127.0.0.1:0")
    assert_equal(ipv4.port, UInt16(0))
    var ipv6 = SocketAddress.parse("[fe80::1%4294967295]:65535")
    assert_equal(ipv6.scope_id, UInt32.MAX)
    assert_equal(ipv6.port, UInt16.MAX)


def test_socket_address_rejects_ports_longer_than_five_digits() raises:
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1:000000")


def test_socket_address_rejects_bracketed_ipv4() raises:
    with assert_raises():
        _ = SocketAddress.parse("[127.0.0.1]:80")


def test_socket_address_rejects_scoped_ipv4() raises:
    with assert_raises():
        _ = SocketAddress.parse("127.0.0.1%3:80")


def test_socket_address_rejects_hostnames() raises:
    with assert_raises():
        _ = SocketAddress.parse("example.com:80")


def test_listen_host_port_allows_an_empty_host() raises:
    var host, port = _split_host_port(":0", True)
    assert_equal(host, "")
    assert_equal(port, UInt16(0))


def _assert_raw_round_trip(value: StringSlice) raises:
    var expected = SocketAddress.parse(value)
    var raw = _socket_address_to_raw(expected)
    var length = raw.length
    var actual = _socket_address_from_raw(raw.unsafe_ptr(), length)
    assert_equal(actual, expected)


def test_raw_socket_addresses_round_trip() raises:
    _assert_raw_round_trip("127.0.0.1:0")
    _assert_raw_round_trip("[::1]:0")
    _assert_raw_round_trip("[fe80::1%3]:9")


def test_raw_socket_address_rejects_invalid_length() raises:
    var raw = _socket_address_to_raw(SocketAddress.parse("127.0.0.1:0"))
    var pointer = raw.unsafe_ptr()
    with assert_raises():
        _ = _socket_address_from_raw(pointer, UInt32(15))


def test_localhost_resolution_is_bounded_and_preserves_port() raises:
    var addresses = resolve_socket_addresses("localhost:80", SOCK_STREAM)
    assert_true(len(addresses) >= 1)
    assert_true(len(addresses) <= 64)
    for address in addresses:
        assert_true(address.ip.is_ipv4() or address.ip.is_ipv6())
        assert_equal(address.port, UInt16(80))


def test_numeric_resolution_preserves_exact_value_without_lookup() raises:
    var expected = SocketAddress.parse(
        "[2001:db8:102:304:506:708:90a:b0c%4294967295]:65535"
    )
    var addresses = resolve_socket_addresses(
        "[2001:db8:102:304:506:708:90a:b0c%4294967295]:65535",
        Int32(-1),
    )
    assert_equal(len(addresses), 1)
    assert_equal(addresses[0], expected)


def _platform_loopback_name() -> String:
    comptime if CompilationTarget.is_macos():
        return "lo0"
    else:
        return "lo"


def _assert_invalid_zone(zone: StringSlice) raises:
    try:
        _ = _resolve_zone(zone)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
        return
    raise Error("expected invalid zone")


def test_interface_zone_lookup_and_reverse_formatting() raises:
    var loopback = _platform_loopback_name()
    var scope_id = _resolve_zone(loopback)
    assert_true(scope_id != 0)
    var address = SocketAddress(
        ip=IPAddress.parse("fe80::1"), port=9, scope_id=scope_id
    )
    assert_equal(String(address), String(t"[fe80::1%{loopback}]:9"))


def test_interface_zone_rejects_unknown_and_nul_names() raises:
    _assert_invalid_zone("net-mojo-no-such-interface")
    _assert_invalid_zone("lo\0ignored")


def test_unknown_scope_formats_as_decimal_fallback() raises:
    var address = SocketAddress(
        ip=IPAddress.parse("fe80::1"), port=9, scope_id=UInt32.MAX
    )
    assert_equal(String(address), "[fe80::1%4294967295]:9")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
