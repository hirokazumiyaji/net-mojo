from std.testing import assert_equal, assert_true, TestSuite
from net import Timeout, listen_tcp
from net.http import (
    Client,
    ClientConfig,
    ClientTLSConfig,
    ClientRequest,
    ClientError,
)
from net.tls import TLSContext
from tests.test_http_client import _LoopFixture


def _tls_fixture() raises -> _LoopFixture:
    var context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )
    return _LoopFixture(context^)


def _trusted_config() raises ClientError -> ClientConfig:
    var config = ClientConfig.default()
    var tls = ClientTLSConfig.default()
    tls.ca_bundle_path = "build/tls/test-cert.pem"
    config.tls = tls^
    return config^


def test_https_client_verified_keepalive_and_response_lifetime() raises:
    assert_true(not ClientTLSConfig.default().insecure_skip_verify)
    var fixture = _tls_fixture()
    var client = Client(_trusted_config())
    var first = client.do(ClientRequest.get(fixture.url))
    assert_equal(first.status, 200)
    assert_equal(String(from_utf8_lossy=first.read_all()), "hello")
    var second = client.do(ClientRequest.get(fixture.url))
    assert_equal(client._pool.state[].origins[0].count, 1)
    client.close()
    _ = client^
    assert_equal(String(from_utf8_lossy=second.read_all()), "hello")
    fixture.finish()
    assert_equal(fixture.state[].handler.requests, 2)


def test_https_client_rejects_untrusted_and_wrong_identity() raises:
    for mode in range(3):
        var fixture = _tls_fixture()
        var config = _trusted_config()
        var url = fixture.url.copy()
        if mode == 0:
            config.tls.value().ca_bundle_path = None
        else:
            url = String("https://127.0.0.1:") + String(
                fixture.url.removeprefix("https://localhost:")
            )
            if mode == 2:
                config.tls.value().sni_override = "localhost"
        var client = Client(config^)
        var caught = False
        try:
            var _ = client.do(ClientRequest.get(url^))
        except error:
            assert_equal(error.kind, ClientError.TLS)
            assert_true(Bool(error.transport))
            caught = True
        assert_true(caught)
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].handler.requests, 0)
        assert_equal(client._pool.state[].origins[0].count, 0)


def test_https_client_explicit_insecure_and_sni_override() raises:
    for insecure in range(2):
        var fixture = _tls_fixture()
        var config = _trusted_config()
        var url = fixture.url.copy()
        if insecure == 0:
            config.tls.value().sni_override = "other.example"
        else:
            config.tls.value().insecure_skip_verify = True
            config.tls.value().ca_bundle_path = None
            url = String("https://127.0.0.1:") + String(
                fixture.url.removeprefix("https://localhost:")
            )
        var client = Client(config^)
        var response = client.do(ClientRequest.get(url^))
        assert_equal(String(from_utf8_lossy=response.read_all()), "hello")
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].handler.requests, 1)


def test_https_client_handshake_deadline_releases_pool_slot() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var config = _trusted_config()
    config.connect_timeout = Timeout.milliseconds(20)
    var client = Client(config^)
    var url = String("https://localhost:") + String(
        listener.local_address().port
    )
    var timed_out = False
    try:
        var _ = client.do(ClientRequest.get(url^))
    except error:
        assert_equal(error.kind, ClientError.TIMEOUT)
        timed_out = True
    assert_true(timed_out)
    assert_equal(client._pool.state[].origins[0].count, 0)
    client.close()
    listener.close()


def _raise_with_tls_fixture() raises:
    var fixture = _tls_fixture()
    raise Error("expected TLS fixture unwind")


def test_https_fixture_exception_unwind_joins_before_release() raises:
    var count = 0
    for _ in range(10):
        try:
            _raise_with_tls_fixture()
        except:
            count += 1
    assert_equal(count, 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
