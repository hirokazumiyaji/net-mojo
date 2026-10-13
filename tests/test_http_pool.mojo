from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from std.time import sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net._actor import PthreadMutex
from net.error import NetError
from net.http import (
    Handler,
    HandlerFactory,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
    ServerPool,
    listen_and_serve_pool,
)
from tests.support import _count_open_fds, _join_thread
from net.http.pool import _WorkerContext, _WorkerFailure, _run_workers


@fieldwise_init
struct _WorkerCounts(Movable):
    var mutex: PthreadMutex
    var counts: Array[Int, 4]


@fieldwise_init
struct _CountingHandler(Handler):
    var worker_id: Int
    var counts_address: Int

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        var counts = Pointer[_WorkerCounts, MutUntrackedOrigin](
            unsafe_from_address=self.counts_address
        )
        counts[].mutex.lock()
        counts[].counts[self.worker_id] += 1
        counts[].mutex.unlock()
        sleep(0.001)
        writer.write_string(String("worker:") + String(self.worker_id))


@fieldwise_init
struct _CountingFactory(HandlerFactory):
    comptime HandlerType = _CountingHandler
    var counts_address: Int
    var built: Int
    var fail_on_worker: Int

    def build(mut self, worker_id: Int) raises -> _CountingHandler:
        self.built += 1
        if worker_id == self.fail_on_worker:
            raise Error("factory initialization failed")
        return _CountingHandler(worker_id, self.counts_address)


@fieldwise_init
struct _PoolContext(Movable):
    var pool: ServerPool
    var factory: _CountingFactory
    var failed: Bool


def _pool_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_PoolContext]()
    try:
        context[].pool.serve(context[].factory)
    except:
        context[].failed = True
    return arg


def _spawn_pool(mut context: _PoolContext) raises -> UInt64:
    var thread: UInt64 = 0
    var result = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _pool_entry,
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(result), 0)
    return thread


def _read_response(mut client: TCPConn) raises NetError -> String:
    var response = List[Byte]()
    var buffer = Array[Byte, 1024](fill=0)
    while True:
        var count = client.read(Span(buffer), Timeout.seconds(2))
        if count == 0:
            break
        for i in range(count):
            response.append(buffer[i])
    client.close()
    return String(from_utf8_lossy=Span(response))


def _exercise_pool(workers: Int, request_count: Int) raises:
    var counts = _WorkerCounts(PthreadMutex(), Array[Int, 4](fill=0))
    var config = ServerConfig.default()
    config.max_accept_per_tick = 1
    var pool = ServerPool(config^, workers=workers)
    var control = pool.control()
    var listener = listen_tcp("127.0.0.1:0")
    var address = String(listener.local_address())
    pool.add_listener(listener^)
    var context = _PoolContext(
        pool^, _CountingFactory(Int(Pointer(to=counts)), 0, -1), False
    )
    var thread = _spawn_pool(context)
    var completed = 0
    try:
        var clients = List[TCPConn]()
        var request = String(
            "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        for _ in range(request_count):
            var client = dial_tcp(address, Timeout.seconds(2))
            client.write_all(request.as_bytes(), Timeout.seconds(2))
            clients.append(client^)
        for i in range(len(clients)):
            var response = _read_response(clients[i])
            if response.find("200 OK") >= 0 and response.find("worker:") >= 0:
                completed += 1
    except:
        pass
    control.request_shutdown()
    _join_thread(thread)
    counts.mutex.destroy()
    assert_false(context.failed)
    assert_equal(context.factory.built, workers)
    assert_equal(completed, request_count)
    var total = 0
    for i in range(workers):
        assert_true(counts.counts[i] > 0)
        total += counts.counts[i]
        print("worker", i, "handled", counts.counts[i])
    assert_equal(total, request_count)
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()


def test_two_workers_accept_on_one_listener_and_share_shutdown() raises:
    _exercise_pool(2, 64)


def test_one_worker_pool_serves_requests() raises:
    _exercise_pool(1, 4)


def test_worker_count_is_detected_and_clamped() raises:
    var automatic = ServerPool(ServerConfig.default())
    assert_true(automatic.worker_count() >= 1)
    assert_true(automatic.worker_count() <= 1024)
    var negative = ServerPool(ServerConfig.default(), workers=-10)
    assert_equal(negative.worker_count(), 1)
    var too_many = ServerPool(ServerConfig.default(), workers=9999)
    assert_equal(too_many.worker_count(), 1024)


def test_shutdown_before_pool_start_is_honored() raises:
    var counts = _WorkerCounts(PthreadMutex(), Array[Int, 4](fill=0))
    var pool = ServerPool(ServerConfig.default(), workers=2)
    pool.add_listener(listen_tcp("127.0.0.1:0"))
    var control = pool.control()
    control.request_shutdown()
    var factory = _CountingFactory(Int(Pointer(to=counts)), 0, -1)
    pool.serve(factory)
    counts.mutex.destroy()
    assert_equal(counts.counts[0], 0)
    assert_equal(counts.counts[1], 0)
    assert_true(control.is_shutdown_requested())


def _failed_pool_control() raises -> Bool:
    var counts = _WorkerCounts(PthreadMutex(), Array[Int, 4](fill=0))
    var pool = ServerPool(ServerConfig.default(), workers=2)
    pool.add_listener(listen_tcp("127.0.0.1:0"))
    var factory = _CountingFactory(Int(Pointer(to=counts)), 0, 1)
    var propagated = False
    try:
        pool.serve(factory)
    except error:
        propagated = String(error).find("factory initialization failed") >= 0
    counts.mutex.destroy()
    assert_equal(factory.built, 2)
    assert_true(pool.control().is_shutdown_requested())
    return propagated


def test_factory_failure_closes_prepared_listeners_and_propagates_error() raises:
    var before = _count_open_fds()
    assert_true(_failed_pool_control())
    assert_equal(_count_open_fds(), before)


def test_pool_rejects_missing_and_duplicate_listener() raises:
    var counts = _WorkerCounts(PthreadMutex(), Array[Int, 4](fill=0))
    var pool = ServerPool(ServerConfig.default(), workers=1)
    var factory = _CountingFactory(Int(Pointer(to=counts)), 0, -1)
    with assert_raises():
        pool.serve(factory)
    pool.add_listener(listen_tcp("127.0.0.1:0"))
    var duplicate = listen_tcp("127.0.0.1:0")
    with assert_raises():
        pool.add_listener(duplicate^)
    pool.control().request_shutdown()
    pool.serve(factory)
    with assert_raises():
        pool.serve(factory)
    counts.mutex.destroy()


def test_pool_convenience_api_reports_bind_error() raises:
    var counts = _WorkerCounts(PthreadMutex(), Array[Int, 4](fill=0))
    var factory = _CountingFactory(Int(Pointer(to=counts)), 0, -1)
    with assert_raises():
        listen_and_serve_pool(
            "invalid", ServerConfig.default(), factory, workers=2
        )
    counts.mutex.destroy()


def _control_after_pool_drop() raises -> ServerControl:
    var pool = ServerPool(ServerConfig.default(), workers=1)
    return pool.control()


def test_control_survives_pool_drop_with_shutdown_requested() raises:
    var control = _control_after_pool_drop()
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()


def test_worker_runtime_error_stops_sibling_and_preserves_error() raises:
    var before = _count_open_fds()
    var counts = _WorkerCounts(PthreadMutex(), Array[Int, 4](fill=0))
    var control = ServerControl()
    var listener = listen_tcp("127.0.0.1:0")
    var failure = _WorkerFailure()
    failure.mutex._initialize()
    var failure_ptr = Pointer[_WorkerFailure, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=failure))
    )
    var contexts = List[_WorkerContext[_CountingHandler]]()
    for worker_id in range(2):
        var server = Server(ServerConfig.default())
        server._set_control(control)
        server.add_listener(listener._duplicate())
        contexts.append(
            _WorkerContext[_CountingHandler](
                server^,
                _CountingHandler(worker_id, Int(Pointer(to=counts))),
                failure_ptr,
            )
        )
    listener.close()
    contexts[0].server._reactor._queue._fd.close()
    var propagated = False
    try:
        _run_workers(contexts, control, failure)
    except error:
        var message = String(error)
        propagated = (
            message.find("kevent wait") >= 0 or message.find("epoll_wait") >= 0
        )
    contexts.clear()
    counts.mutex.destroy()
    assert_true(propagated)
    assert_true(control.is_shutdown_requested())
    assert_equal(_count_open_fds(), before)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
