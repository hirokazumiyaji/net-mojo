from std.testing import assert_equal, assert_true, TestSuite
from net import Timeout
from net.http import (
    Client,
    ClientConfig,
    ClientRequest,
    ClientError,
    RedirectPolicy,
)
from net.http._url import parse_url, resolve_redirect
from tests.test_http_client import _Fixture


def test_redirect_relative_resolution() raises:
    var base = parse_url("http://example.com/a/b/c?old=1")
    var locations: List[String] = [
        "../d?new=1#end",
        "/x/./y/../z",
        "?new=2",
        "#end",
        "//other.example/z",
        "https://other.example/q",
        "../../../../x",
        "./",
        "/a//b",
    ]
    var expected: List[String] = [
        "http://example.com/a/d?new=1",
        "http://example.com/x/z",
        "http://example.com/a/b/c?new=2",
        "http://example.com/a/b/c?old=1",
        "http://other.example/z",
        "https://other.example/q",
        "http://example.com/x",
        "http://example.com/a/b/",
        "http://example.com/a//b",
    ]
    for i in range(len(locations)):
        assert_equal(resolve_redirect(base, locations[i]), expected[i])


def test_redirect_post_rewrite_and_preservation() raises:
    var statuses: List[Int] = [301, 302, 303, 307, 308]
    for i in range(len(statuses)):
        var replies: List[String] = [
            String("HTTP/1.1 ")
            + String(statuses[i])
            + " Redirect\r\nLocation: ../end\r\nContent-Length: 4\r\n\r\nskip",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
        ]
        var fixture = _Fixture(replies^)
        var client = Client(ClientConfig.default())
        var request = ClientRequest.post_bytes(
            fixture.url + "/dir/start", List[Byte]("data".as_bytes())
        )
        request.headers.add("Content-Type", "text/plain")
        var response = client.do(request^)
        assert_equal(response.status, 200)
        assert_equal(String(from_utf8_lossy=response.read_all()), "ok")
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].accepted, 1)
        assert_equal(
            fixture.state[].requests[1],
            "GET /end " if i < 3 else "POST /end data",
        )
        assert_equal(
            fixture.state[].wires[1].lower().find("content-type") >= 0, i >= 3
        )


def test_redirect_head_and_credentials_same_origin() raises:
    var replies: List[String] = [
        "HTTP/1.1 303 Redirect\r\nLocation: /end\r\nContent-Length: 9\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n",
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var request = ClientRequest.get(fixture.url)
    request.method = "HEAD"
    request.headers.add("Authorization", "Bearer example")
    request.headers.add("Cookie", "a=b")
    var response = client.do(request^)
    assert_equal(len(response.read_all()), 0)
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].requests[1], "HEAD /end ")
    assert_true(fixture.state[].wires[1].find("Bearer example") >= 0)
    assert_true(fixture.state[].wires[1].find("a=b") >= 0)


def test_redirect_cross_origin_strips_credentials_and_host() raises:
    var target_replies: List[String] = [
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    ]
    var target = _Fixture(target_replies^)
    var source_replies: List[String] = [
        String("HTTP/1.1 302 Redirect\r\nLocation: ")
        + target.url
        + "/end\r\nContent-Length: 0\r\n\r\n"
    ]
    var source = _Fixture(source_replies^)
    var client = Client(ClientConfig.default())
    var request = ClientRequest.get(source.url)
    request.headers.add("Authorization", "Bearer secret")
    request.headers.add("Cookie", "secret=value")
    request.headers.add("Host", "original.example")
    request.headers.add("X-Keep", "retained")
    var response = client.do(request^)
    var _ = response.read_all()
    client.close()
    source.finish()
    target.finish()
    var wire = target.state[].wires[0].lower()
    assert_equal(wire.find("authorization"), -1)
    assert_equal(wire.find("cookie"), -1)
    assert_equal(wire.find("original.example"), -1)
    assert_true(wire.find("x-keep: retained") >= 0)


def test_redirect_disabled_missing_location_and_limit() raises:
    for mode in range(3):
        var reply = String("HTTP/1.1 302 Redirect\r\nContent-Length: 0\r\n")
        if mode != 1:
            reply += "Location: /again\r\n"
        reply += "\r\n"
        var replies = List[String]()
        replies.append(reply^)
        var fixture = _Fixture(replies^)
        var config = ClientConfig.default()
        if mode == 0:
            config.redirect = RedirectPolicy.never()
        if mode == 2:
            config.redirect.max_hops = 0
        var client = Client(config^)
        var caught = False
        var status = 0
        try:
            var response = client.do(ClientRequest.get(fixture.url))
            status = response.status
            var _ = response.read_all()
        except error:
            assert_equal(error.kind, ClientError.REDIRECT)
            caught = True
        assert_equal(caught, mode == 2)
        if not caught:
            assert_equal(status, 302)
        client.close()
        fixture.finish()


def test_redirect_loop_invalid_location_and_request_deadline() raises:
    for mode in range(3):
        var replies = List[String]()
        var count = 3 if mode == 0 else 1 if mode == 1 else 2
        for _ in range(count):
            replies.append(
                "HTTP/1.1 302 Redirect\r\nLocation: ftp://example.com/\r\nContent-Length: 0\r\n\r\n" if mode
                == 1 else "HTTP/1.1 302 Redirect\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n"
            )
        var fixture = _Fixture(replies^, 0.04 if mode == 2 else 0.0)
        var config = ClientConfig.default()
        config.redirect.max_hops = 2
        var client = Client(config^)
        var request = ClientRequest.get(fixture.url)
        if mode == 2:
            request.deadline = Timeout.milliseconds(70)
        var caught = False
        try:
            var _ = client.do(request^)
        except error:
            assert_equal(
                error.kind,
                ClientError.TIMEOUT if mode == 2 else ClientError.REDIRECT,
            )
            caught = True
        assert_true(caught)
        client.close()
        fixture.finish()
        assert_equal(client._pool.state[].origins[0].count, 0)


def test_redirect_inherits_raw_base_path_for_empty_or_query_reference() raises:
    var base = parse_url("http://example.com/a/../b?old=1")
    assert_equal(resolve_redirect(base, ""), "http://example.com/a/../b?old=1")
    assert_equal(
        resolve_redirect(base, "#fragment"), "http://example.com/a/../b?old=1"
    )
    assert_equal(
        resolve_redirect(base, "?new=2"), "http://example.com/a/../b?new=2"
    )


def test_redirect_follows_after_discarded_body_is_truncated() raises:
    var replies: List[String] = [
        (
            "HTTP/1.1 302 Redirect\r\nLocation: /end\r\nContent-Length:"
            " 4\r\nConnection: close\r\n\r\nx"
        ),
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var response = client.do(ClientRequest.get(fixture.url))
    assert_equal(response.status, 200)
    assert_equal(String(from_utf8_lossy=response.read_all()), "ok")
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].accepted, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
