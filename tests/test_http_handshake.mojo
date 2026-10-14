from std.testing import assert_equal, assert_true, TestSuite
from net.http._websocket_hash import _websocket_accept_key, _valid_websocket_key


def test_rfc6455_accept_vector() raises:
    assert_equal(
        _websocket_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    )


def test_handshake_key_is_exactly_16_bytes() raises:
    assert_true(_valid_websocket_key("dGhlIHNhbXBsZSBub25jZQ=="))
    for key in [
        "",
        "AAAA",
        "dGhlIHNhbXBsZSBub25jZQ=",
        "dGhlIHNhbXBsZSBub25jZR==",
        "dGhlIHNhbXBsZSBub25jZQ== ",
    ]:
        assert_equal(_valid_websocket_key(key), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
