from std.testing import assert_equal, assert_true, TestSuite
from net import Timeout, dial_tcp, listen_tcp
from net.http import Client, ClientConfig, ClientRequest, ClientError
from tests.test_http_client import _Fixture
from net.http._url import parse_url
from net.http._client_pool import _ClientConnection, _ClientLease


def test_reused_get_head_and_keyed_post_retry_once() raises:
    for mode in range(3):
        var replies: List[String] = [
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            "",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        ]
        var fixture = _Fixture(replies^)
        var client = Client(ClientConfig.default())
        var seed = client.do(ClientRequest.get(fixture.url))
        var _ = seed.read_all()
        var request = ClientRequest.get(fixture.url + "/retry")
        if mode == 1:
            request.method = "HEAD"
        if mode == 2:
            request = ClientRequest.post_bytes(
                fixture.url + "/retry", List[Byte]("data".as_bytes())
            )
            request.headers.add("Idempotency-Key", "example")
        var response = client.do(request^)
        assert_equal(response.status, 200)
        var _ = response.read_all()
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].accepted, 2)
        assert_equal(fixture.state[].requests[1], fixture.state[].requests[2])


def test_retry_denies_unkeyed_post_and_fresh_failure() raises:
    for mode in range(2):
        var replies = List[String]()
        if mode == 0:
            replies.append("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        replies.append("")
        var fixture = _Fixture(replies^)
        var client = Client(ClientConfig.default())
        if mode == 0:
            var seed = client.do(ClientRequest.get(fixture.url))
            var _ = seed.read_all()
        var caught = False
        try:
            var request = ClientRequest.get(fixture.url)
            if mode == 0:
                request = ClientRequest.post_bytes(
                    fixture.url, List[Byte]("data".as_bytes())
                )
            var _ = client.do(request^)
        except error:
            assert_equal(error.kind, ClientError.READ)
            caught = True
        assert_true(caught)
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].accepted, 1)


def test_retry_is_bounded_and_parse_failures_are_not_retried() raises:
    for mode in range(2):
        var replies: List[String] = [
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            "",
        ]
        if mode == 0:
            replies.append("")
        else:
            replies[1] = (
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length:"
                " 0\r\n\r\n"
            )
        var fixture = _Fixture(replies^)
        var client = Client(ClientConfig.default())
        var seed = client.do(ClientRequest.get(fixture.url))
        var _ = seed.read_all()
        var caught = False
        try:
            var _ = client.do(ClientRequest.get(fixture.url))
        except error:
            assert_equal(
                error.kind, ClientError.READ if mode == 0 else ClientError.PARSE
            )
            caught = True
        assert_true(caught)
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].accepted, 2 if mode == 0 else 1)
        assert_equal(client._pool.state[].origins[0].count, 0)


def test_retry_preserves_request_deadline() raises:
    var replies: List[String] = [
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
    ]
    var fixture = _Fixture(replies^, 0.04)
    var client = Client(ClientConfig.default())
    var seed = client.do(ClientRequest.get(fixture.url))
    var _ = seed.read_all()
    var request = ClientRequest.get(fixture.url)
    request.deadline = Timeout.milliseconds(70)
    var caught = False
    try:
        var _ = client.do(request^)
    except error:
        assert_equal(error.kind, ClientError.TIMEOUT)
        caught = True
    assert_true(caught)
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].accepted, 2)
    assert_equal(client._pool.state[].origins[0].count, 0)


def test_retry_dials_fresh_with_multiple_stale_idle_connections() raises:
    var replies: List[String] = ["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"]
    var fixture = _Fixture(replies^)
    var config = ClientConfig.default()
    config.max_conns_per_host = 2
    var client = Client(config^)
    var sink = listen_tcp("127.0.0.1:0")
    var leases = List[_ClientLease]()
    for _ in range(2):
        var lease = client._pool.acquire(parse_url(fixture.url))
        var socket = dial_tcp(String(sink.local_address()), Timeout.seconds(1))
        var peer = sink.accept(Timeout.seconds(1))
        peer.close()
        lease.connection = _ClientConnection(socket^)
        leases.append(lease^)
    for i in range(len(leases)):
        leases[i].finish(True)
    var response = client.do(ClientRequest.get(fixture.url))
    var _ = response.read_all()
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].accepted, 1)
    assert_equal(client._pool.state[].origins[0].count, 0)


def test_retry_stops_after_partial_or_informational_response() raises:
    for mode in range(2):
        var replies: List[String] = [
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nConnection: close\r\n" if mode
            == 0 else "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1",
        ]
        var fixture = _Fixture(replies^)
        var config = ClientConfig.default()
        config.response_header_timeout = Timeout.milliseconds(20)
        var client = Client(config^)
        var seed = client.do(ClientRequest.get(fixture.url))
        var _ = seed.read_all()
        var caught = False
        try:
            var _ = client.do(ClientRequest.get(fixture.url))
        except error:
            assert_equal(error.kind, ClientError.READ)
            caught = True
        assert_true(caught)
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].accepted, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
