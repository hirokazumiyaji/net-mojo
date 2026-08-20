from std.testing import assert_equal, assert_raises, TestSuite
from net import SocketAddress, join_host_port, split_host_port
from net.address import _split_host_port


def test_socket_address_parses_numeric_ipv4_and_formats_it() raises:
    var ipv4 = SocketAddress.parse("127.0.0.1:8080")
    assert_equal(ipv4.port, UInt16(8080))
    assert_equal(String(ipv4), "127.0.0.1:8080")


def test_socket_address_parses_scoped_ipv6_and_formats_it() raises:
    var ipv6 = SocketAddress.parse("[fe80::1%3]:443")
    assert_equal(ipv6.scope_id, UInt32(3))
    assert_equal(String(ipv6), "[fe80::1%3]:443")


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


def test_listen_host_port_allows_an_empty_host() raises:
    var host, port = _split_host_port(":0", True)
    assert_equal(host, "")
    assert_equal(port, UInt16(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
