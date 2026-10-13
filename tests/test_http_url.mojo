from std.testing import assert_equal, assert_true
from net.http import ClientError
from net.http._url import parse_url


def test_url_parts() raises:
    var url = parse_url("http://Example.COM/a%20b?q=%23#ignored")
    assert_equal(url.scheme, "http")
    assert_equal(url.host, "example.com")
    assert_equal(url.port, UInt16(80))
    assert_equal(url.authority, "example.com")
    assert_equal(url.target, "/a%20b?q=%23")
    var secure = parse_url("HTTPS://example.com:8443?x=1")
    assert_equal(secure.scheme, "https")
    assert_equal(secure.port, UInt16(8443))
    assert_equal(secure.target, "/?x=1")
    assert_equal(secure.authority, "example.com:8443")
    assert_equal(parse_url("https://example.com#fragment").target, "/")
    assert_equal(parse_url("https://example.com").port, UInt16(443))


def test_ipv6() raises:
    var url = parse_url("http://[::1]:8080/path")
    assert_equal(url.host, "::1")
    assert_equal(url.authority, "[::1]:8080")
    assert_equal(url.port, UInt16(8080))
    assert_equal(parse_url("https://[2001:db8::1]/").port, UInt16(443))
    var compressed = parse_url("http://[::1]/")
    var expanded = parse_url("http://[0:0:0:0:0:0:0:1]:80/")
    assert_true(compressed.same_origin(expanded))
    assert_equal(expanded.host, "::1")


def test_invalid_urls() raises:
    var invalid: List[String] = [
        "",
        "/relative",
        "ftp://example.com/",
        "http:example.com",
        "http:///x",
        "http://user:pass@example.com/",
        "http://host:/",
        "http://host:65536/",
        "http://host:0/",
        "http://host:-1/",
        "http://::1/",
        "http://[::1/",
        "http://[nonsense]/",
        "http://host\\evil/",
        "http://host/a b",
        "http://host/\r\nX:y",
        "http://host/%",
        "http://host/%gg",
        "http://ho%st/",
        "http://%65xample.com/",
        "http://%65xample.com:80/",
    ]
    for raw in invalid:
        var rejected = False
        try:
            var ignored = parse_url(raw)
        except error:
            rejected = True
            assert_equal(error.kind, ClientError.PARSE)
        assert_true(rejected, String("accepted invalid URL: ") + raw)


def main() raises:
    test_url_parts()
    test_ipv6()
    test_invalid_urls()
    print("3 HTTP URL tests passed")
