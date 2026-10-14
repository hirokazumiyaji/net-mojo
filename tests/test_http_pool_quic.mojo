from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from net import Timeout, listen_tcp
from net.http import HandlerFactory, ServerConfig, ServerPool
from net.http.pool import _WorkerFailure
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp
from tests.http_pool_integration_fixture import _Factory
from tests.support import _count_open_fds


def _endpoint() raises -> QuicUDPEndpoint:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    return QuicUDPEndpoint(provider.server(config^), listen_udp("127.0.0.1:0"))


def test_only_worker_zero_owns_quic_endpoint() raises:
    var pool = ServerPool(ServerConfig.default(), workers=2)
    pool.add_listener(listen_tcp("127.0.0.1:0"))
    var endpoint = _endpoint()
    var udp_fd = endpoint.raw_fd()
    pool.add_quic_endpoint(endpoint^)
    var factory = _Factory(pool.control())
    var failure = _WorkerFailure()
    failure.mutex._initialize()
    var failure_ptr = Pointer[_WorkerFailure, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=failure))
    )
    var contexts = pool._prepare_workers(factory, failure_ptr)
    assert_equal(len(contexts), 2)
    assert_true(Bool(contexts[0].server._quic_endpoint))
    assert_equal(contexts[0].server._quic_endpoint.value().raw_fd(), udp_fd)
    assert_false(Bool(contexts[1].server._quic_endpoint))
    assert_true(Bool(contexts[0].server._listener))
    assert_true(Bool(contexts[1].server._listener))
    assert_true(
        contexts[0].server._listener.value().raw_fd()
        != contexts[1].server._listener.value().raw_fd()
    )
    assert_false(Bool(pool._quic_endpoint))
    contexts.clear()


def test_quic_only_pool_uses_one_active_worker_and_stops() raises:
    var before = _count_open_fds()
    var config = ServerConfig.default()
    config.shutdown_grace = Timeout.milliseconds(10)
    var pool = ServerPool(config^, workers=4)
    pool.add_quic_endpoint(_endpoint())
    var control = pool.control()
    control.request_shutdown()
    var factory = _Factory(control.copy())
    pool.serve(factory)
    assert_true(control.is_shutdown_requested())
    assert_equal(_count_open_fds(), before)


def test_pool_rejects_duplicate_quic_endpoint() raises:
    var pool = ServerPool(ServerConfig.default(), workers=2)
    pool.add_quic_endpoint(_endpoint())
    var second = _endpoint()
    with assert_raises():
        pool.add_quic_endpoint(second^)


@fieldwise_init
struct _FailingFactory(HandlerFactory):
    comptime HandlerType = _Factory.HandlerType
    var inner: _Factory

    def build(mut self, worker_id: Int) raises -> Self.HandlerType:
        if worker_id == 1:
            raise Error("QUIC factory initialization failed")
        return self.inner.build(worker_id)


def test_factory_failure_releases_worker_zero_quic_owner() raises:
    var before = _count_open_fds()
    var pool = ServerPool(ServerConfig.default(), workers=2)
    pool.add_listener(listen_tcp("127.0.0.1:0"))
    pool.add_quic_endpoint(_endpoint())
    var factory = _FailingFactory(_Factory(pool.control()))
    var propagated = False
    try:
        pool.serve(factory)
    except error:
        propagated = (
            String(error).find("QUIC factory initialization failed") >= 0
        )
    assert_true(propagated)
    assert_true(pool.control().is_shutdown_requested())
    assert_equal(_count_open_fds(), before)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
