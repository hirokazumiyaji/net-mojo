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
from net._sys.common import (
    AF_INET,
    AF_INET6,
    SOCK_STREAM,
    _RawSocketAddress,
)


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
        _ = SocketAddress.parse("[fe80::1%net-mojo-no-such-interface]:443")
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


def test_encoded_ipv4_sockaddr_has_platform_abi_bytes() raises:
    var raw = _socket_address_to_raw(SocketAddress.parse("192.0.2.1:4660"))
    var length = raw.length
    var pointer = raw.unsafe_ptr()
    assert_equal(length, UInt32(16))
    comptime if CompilationTarget.is_macos():
        assert_equal(pointer[unsafe_offset=0], Byte(16))
        assert_equal(pointer[unsafe_offset=1], Byte(AF_INET))
    else:
        assert_equal(pointer[unsafe_offset=0], Byte(AF_INET))
        assert_equal(pointer[unsafe_offset=1], Byte(0))
    assert_equal(pointer[unsafe_offset=2], Byte(0x12))
    assert_equal(pointer[unsafe_offset=3], Byte(0x34))
    assert_equal(pointer[unsafe_offset=4], Byte(192))
    assert_equal(pointer[unsafe_offset=5], Byte(0))
    assert_equal(pointer[unsafe_offset=6], Byte(2))
    assert_equal(pointer[unsafe_offset=7], Byte(1))
    assert_equal(raw.length, length)


def test_encoded_ipv6_sockaddr_has_platform_abi_bytes() raises:
    var raw = _socket_address_to_raw(
        SocketAddress.parse("[2001:db8::1%16909060]:43981")
    )
    var length = raw.length
    var expected = IPAddress.parse("2001:db8::1")
    var address_bytes = expected.as_bytes()
    var pointer = raw.unsafe_ptr()
    assert_equal(length, UInt32(28))
    comptime if CompilationTarget.is_macos():
        assert_equal(pointer[unsafe_offset=0], Byte(28))
        assert_equal(pointer[unsafe_offset=1], Byte(AF_INET6))
    else:
        assert_equal(pointer[unsafe_offset=0], Byte(AF_INET6))
        assert_equal(pointer[unsafe_offset=1], Byte(0))
    assert_equal(pointer[unsafe_offset=2], Byte(0xAB))
    assert_equal(pointer[unsafe_offset=3], Byte(0xCD))
    for i in range(16):
        assert_equal(pointer[unsafe_offset=8 + i], address_bytes[i])
    assert_equal(pointer[unsafe_offset=24], Byte(0x04))
    assert_equal(pointer[unsafe_offset=25], Byte(0x03))
    assert_equal(pointer[unsafe_offset=26], Byte(0x02))
    assert_equal(pointer[unsafe_offset=27], Byte(0x01))
    assert_equal(raw.length, length)


def _write_test_family(
    mut raw: _RawSocketAddress, length: UInt32, family: Int32
):
    raw.length = length
    var pointer = raw.unsafe_ptr()
    comptime if CompilationTarget.is_macos():
        pointer[unsafe_offset=0] = Byte(length)
        pointer[unsafe_offset=1] = Byte(family)
    else:
        pointer[unsafe_offset=0] = Byte(UInt32(family) & 0xFF)
        pointer[unsafe_offset=1] = Byte((UInt32(family) >> 8) & 0xFF)


def test_handcrafted_sockaddr_bytes_decode() raises:
    var ipv4 = _RawSocketAddress()
    _write_test_family(ipv4, 16, AF_INET)
    var ipv4_pointer = ipv4.unsafe_ptr()
    ipv4_pointer[unsafe_offset=2] = 0x1F
    ipv4_pointer[unsafe_offset=3] = 0x90
    ipv4_pointer[unsafe_offset=4] = 203
    ipv4_pointer[unsafe_offset=5] = 0
    ipv4_pointer[unsafe_offset=6] = 113
    ipv4_pointer[unsafe_offset=7] = 7
    var decoded_ipv4 = _socket_address_from_raw(ipv4_pointer, 16)
    assert_equal(decoded_ipv4, SocketAddress.parse("203.0.113.7:8080"))
    assert_equal(ipv4.length, UInt32(16))

    var ipv6 = _RawSocketAddress()
    _write_test_family(ipv6, 28, AF_INET6)
    var ipv6_pointer = ipv6.unsafe_ptr()
    ipv6_pointer[unsafe_offset=2] = 0x01
    ipv6_pointer[unsafe_offset=3] = 0xBB
    var expected_ip = IPAddress.parse("2001:db8::1")
    var expected_bytes = expected_ip.as_bytes()
    for i in range(16):
        ipv6_pointer[unsafe_offset=8 + i] = expected_bytes[i]
    ipv6_pointer[unsafe_offset=24] = 0x04
    ipv6_pointer[unsafe_offset=25] = 0x03
    ipv6_pointer[unsafe_offset=26] = 0x02
    ipv6_pointer[unsafe_offset=27] = 0x01
    var decoded_ipv6 = _socket_address_from_raw(ipv6_pointer, 28)
    assert_equal(
        decoded_ipv6,
        SocketAddress.parse("[2001:db8::1%16909060]:443"),
    )
    assert_equal(ipv6.length, UInt32(28))


def test_raw_socket_address_rejects_invalid_length() raises:
    var raw = _socket_address_to_raw(SocketAddress.parse("127.0.0.1:0"))
    var pointer = raw.unsafe_ptr()
    with assert_raises():
        _ = _socket_address_from_raw(pointer, UInt32(15))


def test_raw_socket_address_rejects_family_and_length_mismatch() raises:
    var raw = _RawSocketAddress()
    _write_test_family(raw, 28, AF_INET)
    var pointer = raw.unsafe_ptr()
    with assert_raises():
        _ = _socket_address_from_raw(pointer, 28)
    assert_equal(raw.length, UInt32(28))


def test_raw_socket_address_rejects_unknown_family() raises:
    var raw = _RawSocketAddress()
    _write_test_family(raw, 16, 99)
    var pointer = raw.unsafe_ptr()
    with assert_raises():
        _ = _socket_address_from_raw(pointer, 16)
    assert_equal(raw.length, UInt32(16))


def test_darwin_raw_socket_address_rejects_sa_len_mismatch() raises:
    comptime if CompilationTarget.is_macos():
        var raw = _socket_address_to_raw(SocketAddress.parse("127.0.0.1:80"))
        var length = raw.length
        var pointer = raw.unsafe_ptr()
        pointer[unsafe_offset=0] = 28
        with assert_raises():
            _ = _socket_address_from_raw(pointer, length)
        assert_equal(raw.length, length)


def test_localhost_resolution_is_bounded_and_preserves_port() raises:
    var addresses = resolve_socket_addresses("localhost:80", SOCK_STREAM)
    assert_true(len(addresses) >= 1)
    assert_true(len(addresses) <= 64)
    for address in addresses:
        assert_true(address.ip.is_ipv4() or address.ip.is_ipv6())
        assert_equal(address.port, UInt16(80))


def _assert_invalid_resolution(value: StringSlice) raises:
    try:
        _ = resolve_socket_addresses(value, SOCK_STREAM)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_address())
        return
    raise Error("expected invalid socket address")


def test_resolution_rejects_port_and_nul_before_ffi() raises:
    _assert_invalid_resolution("localhost:65536")
    _assert_invalid_resolution("local\0host:80")
    _assert_invalid_resolution("localhost:8\0")


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


def test_socket_address_parses_named_interface_zones() raises:
    var loopback = _platform_loopback_name()
    var scope_id = _resolve_zone(loopback)
    var address = SocketAddress.parse(String(t"[fe80::1%{loopback}]:443"))
    assert_equal(address.scope_id, scope_id)
    assert_equal(address.ip, IPAddress.parse("fe80::1"))
    assert_equal(address.port, UInt16(443))
    assert_equal(SocketAddress.parse(String(address)), address)


def test_interface_zone_rejects_unknown_and_nul_names() raises:
    _assert_invalid_zone("net-mojo-no-such-interface")
    _assert_invalid_zone("lo\0ignored")


def test_unknown_scope_formats_as_decimal_fallback() raises:
    var address = SocketAddress(
        ip=IPAddress.parse("fe80::1"), port=9, scope_id=UInt32.MAX
    )
    assert_equal(String(address), "[fe80::1%4294967295]:9")


def test_resolution_failure_reports_gai_status_not_errno() raises:
    # An invalid socket type fails inside getaddrinfo before any lookup,
    # so this exercises the EAI path without touching the network.
    try:
        _ = resolve_socket_addresses("localhost:80", Int32(-1))
    except error:
        assert_equal(error.kind, NetErrorKind.resolution_failed())
        if error.errno:
            raise Error("resolution status leaked into errno")
        var status = 0
        var has_status = False
        if error.resolver_status:
            status = error.resolver_status.value()
            has_status = True
        assert_true(has_status)
        assert_true(status != 0)
        assert_true(error.message.byte_length() > 0)
        var rendered = String(error)
        assert_true(rendered.byte_length() > error.message.byte_length())
        return
    raise Error("resolution unexpectedly succeeded")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
