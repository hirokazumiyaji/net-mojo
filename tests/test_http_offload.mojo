from std.ffi import c_int, c_size_t, external_call
from std.sys import size_of
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net._actor import PthreadMutex
from net.http import (
    Headers,
    ResponseSender,
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    HandlerJob,
    OffloadError,
    WorkerPool,
    WorkerPoolConfig,
)
from net.http._buffer import SharedBufferBudget
from net.http._detach import (
    MSG_KIND_ABORT,
    MSG_KIND_RESPOND,
    _cancel_detach_state,
    _create_detach_state,
    _detach_state,
    _release_detach_state,
    _take_batch,
)
from net.http._offload import (
    _create_pool,
    _start_worker,
    _worker_entry,
    _WorkerSlot,
)
from tests.support import _join_thread
from tests.test_http_detach import (
    _body_of,
    _split_responses,
    _status_of,
    _tick_and_read,
)


struct _JobGate(Movable):
    var mutex: PthreadMutex
    var order: List[Int]
    var destroyed: List[Int]
    var released: Bool
    var blocked_started: Bool
    var observed_cancel: Bool

    def __init__(out self):
        self.mutex = PthreadMutex._uninitialized()
        self.order = List[Int]()
        self.destroyed = List[Int]()
        self.released = False
        self.blocked_started = False
        self.observed_cancel = False

    def __deinit__(deinit self):
        self.mutex.destroy()


def _gate_address(mut gate: _JobGate) -> Int:
    return Int(Pointer(to=gate))


def _gate(addr: Int) -> Pointer[_JobGate, MutUntrackedOrigin]:
    return Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=addr
    ).unsafe_bitcast[_JobGate]()


def _record_start(addr: Int, identity: Int, blocked: Bool = False):
    var gate = _gate(addr)
    gate[].mutex.lock()
    gate[].order.append(identity)
    gate[].blocked_started = gate[].blocked_started or blocked
    gate[].mutex.unlock()


def _record_destroy(addr: Int, identity: Int):
    var gate = _gate(addr)
    gate[].mutex.lock()
    gate[].destroyed.append(identity)
    gate[].mutex.unlock()


def _release_gate(mut gate: _JobGate):
    gate.mutex.lock()
    gate.released = True
    gate.mutex.unlock()


def _wait_started(mut gate: _JobGate) raises:
    var deadline = perf_counter_ns() + 2_000_000_000
    while True:
        gate.mutex.lock()
        var started = gate.blocked_started
        gate.mutex.unlock()
        if started:
            return
        if perf_counter_ns() >= deadline:
            _release_gate(gate)
            raise Error("worker did not start blocked job")
        sleep(0.001)


def _wait_destroyed(mut gate: _JobGate, count: Int) raises:
    var deadline = perf_counter_ns() + 2_000_000_000
    while True:
        gate.mutex.lock()
        var destroyed = len(gate.destroyed)
        gate.mutex.unlock()
        if destroyed == count:
            return
        if perf_counter_ns() >= deadline:
            raise Error("typed job ownership was not released")
        sleep(0.001)


def _sender(
    var budget: Optional[SharedBufferBudget] = None,
) raises -> ResponseSender:
    return ResponseSender(_create_detach_state(0, 1, budget=budget^))


@fieldwise_init
struct _RecordJob(HandlerJob):
    var gate_addr: Int
    var identity: Int

    def run(mut self, mut sender: ResponseSender) raises:
        _record_start(self.gate_addr, self.identity)
        sender.respond(body=List[Byte](length=1, fill=Byte(self.identity)))

    def __deinit__(deinit self):
        _record_destroy(self.gate_addr, self.identity)


@fieldwise_init
struct _BlockedJob(HandlerJob):
    var gate_addr: Int
    var identity: Int

    def run(mut self, mut sender: ResponseSender) raises:
        _record_start(self.gate_addr, self.identity, True)
        var gate = _gate(self.gate_addr)
        while True:
            gate[].mutex.lock()
            var released = gate[].released
            gate[].mutex.unlock()
            if released:
                break
            sleep(0.001)
        var cancelled = sender.is_cancelled()
        gate[].mutex.lock()
        gate[].observed_cancel = cancelled
        gate[].mutex.unlock()
        if not cancelled:
            sender.respond(body=List[Byte](length=1, fill=Byte(self.identity)))

    def __deinit__(deinit self):
        _record_destroy(self.gate_addr, self.identity)


@fieldwise_init
struct _FailingJob(HandlerJob):
    var gate_addr: Int
    var identity: Int
    var raises_error: Bool

    def run(mut self, mut sender: ResponseSender) raises:
        _record_start(self.gate_addr, self.identity)
        if self.raises_error:
            raise Error("job error")

    def __deinit__(deinit self):
        _record_destroy(self.gate_addr, self.identity)


def _assert_response(addr: Int, status: Int) raises:
    var batch = _take_batch(_detach_state(addr))
    assert_equal(len(batch.messages), 1)
    assert_equal(batch.messages[0].kind, MSG_KIND_RESPOND)
    assert_equal(batch.messages[0].status, status)
    if status == 503:
        var retry = batch.messages[0].headers.get_first("retry-after")
        assert_true(Bool(retry))
        assert_equal(retry.value(), "1")


def test_pool_executes_and_releases_typed_job() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1))
    var sender = _sender()
    var addr = sender._addr
    assert_true(pool.submit(sender^, _RecordJob(_gate_address(gate), 7)))
    pool.shutdown()
    assert_equal(len(gate.order), 1)
    assert_equal(gate.order[0], 7)
    assert_equal(len(gate.destroyed), 1)
    _assert_response(addr, 200)
    _cancel_detach_state(addr)


def test_fifo_full_refusal_owns_sender_and_job() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1, queue_limit=2))
    var first = _sender()
    var first_addr = first._addr
    assert_true(pool.submit(first^, _BlockedJob(_gate_address(gate), 0)))
    _wait_started(gate)
    var addrs = List[Int]()
    for identity in range(1, 4):
        var sender = _sender()
        addrs.append(sender._addr)
        var accepted = pool.submit(
            sender^, _RecordJob(_gate_address(gate), identity)
        )
        assert_equal(accepted, identity < 3)
    _release_gate(gate)
    pool.shutdown()
    assert_equal(len(gate.order), 3)
    for identity in range(3):
        assert_equal(gate.order[identity], identity)
    _assert_response(first_addr, 200)
    _cancel_detach_state(first_addr)
    for i in range(3):
        _assert_response(addrs[i], 200 if i < 2 else 503)
        _cancel_detach_state(addrs[i])
    assert_equal(len(gate.destroyed), 4)


def test_cancelled_queued_job_is_not_run() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1, queue_limit=1))
    var first = _sender()
    var first_addr = first._addr
    assert_true(pool.submit(first^, _BlockedJob(_gate_address(gate), 0)))
    _wait_started(gate)
    var cancelled = _sender()
    var cancelled_addr = cancelled._addr
    assert_true(pool.submit(cancelled^, _RecordJob(_gate_address(gate), 1)))
    _cancel_detach_state(cancelled_addr)
    _release_gate(gate)
    pool.shutdown()
    assert_equal(len(gate.order), 1)
    assert_equal(len(gate.destroyed), 2)
    _cancel_detach_state(first_addr)


def test_job_error_or_missing_response_aborts() raises:
    for raises_error in [False, True]:
        var gate = _JobGate()
        gate.mutex._initialize()
        var pool = WorkerPool(WorkerPoolConfig(workers=1))
        var sender = _sender()
        var addr = sender._addr
        assert_true(
            pool.submit(
                sender^, _FailingJob(_gate_address(gate), 0, raises_error)
            )
        )
        pool.shutdown()
        var batch = _take_batch(_detach_state(addr))
        assert_equal(batch.terminal_kind, MSG_KIND_ABORT)
        assert_equal(len(gate.destroyed), 1)
        _cancel_detach_state(addr)


def test_shutdown_grace_cancels_active_and_discards_queued_after_owner_drop() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var budget = SharedBufferBudget(1_048_576)
    var pool = WorkerPool(
        WorkerPoolConfig(
            workers=1, queue_limit=1, shutdown_grace=Timeout.milliseconds(10)
        )
    )
    var active = _sender(budget.copy())
    var active_addr = active._addr
    assert_true(pool.submit(active^, _BlockedJob(_gate_address(gate), 0)))
    _wait_started(gate)
    var queued = _sender(budget.copy())
    var queued_addr = queued._addr
    assert_true(pool.submit(queued^, _RecordJob(_gate_address(gate), 1)))
    var started = perf_counter_ns()
    pool.shutdown()
    var elapsed = perf_counter_ns() - started
    var active_batch = _take_batch(_detach_state(active_addr))
    var queued_batch = _take_batch(_detach_state(queued_addr))
    var active_cancelled = _detach_state(active_addr)[].cancelled
    var queued_cancelled = _detach_state(queued_addr)[].cancelled
    var destroyed_before_release = len(gate.destroyed)
    pool.shutdown()
    _ = pool^
    _cancel_detach_state(active_addr)
    _cancel_detach_state(queued_addr)
    var retained = budget.used()
    _release_gate(gate)
    _wait_destroyed(gate, 2)
    var deadline = perf_counter_ns() + 2_000_000_000
    while budget.used() != 0 and perf_counter_ns() < deadline:
        sleep(0.001)
    assert_true(elapsed < 250_000_000)
    assert_true(active_cancelled and queued_cancelled)
    assert_equal(active_batch.terminal_kind, MSG_KIND_ABORT)
    assert_equal(queued_batch.terminal_kind, MSG_KIND_ABORT)
    assert_equal(destroyed_before_release, 0)
    assert_true(retained > 0)
    assert_equal(budget.used(), 0)
    assert_equal(len(gate.order), 1)
    assert_true(gate.observed_cancel)


def test_closed_and_zero_capacity_pools_refuse_with_503() raises:
    for queue_limit in [0, 1]:
        var gate = _JobGate()
        gate.mutex._initialize()
        var pool = WorkerPool(
            WorkerPoolConfig(workers=1, queue_limit=queue_limit)
        )
        if queue_limit != 0:
            pool.shutdown()
        var sender = _sender()
        var addr = sender._addr
        assert_false(pool.submit(sender^, _RecordJob(_gate_address(gate), 3)))
        _assert_response(addr, 503)
        _cancel_detach_state(addr)
        pool.shutdown()
        assert_equal(len(gate.order), 0)
        assert_equal(len(gate.destroyed), 1)


def test_auto_workers_execute_job() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=0))
    var sender = _sender()
    var addr = sender._addr
    assert_true(pool.submit(sender^, _RecordJob(_gate_address(gate), 4)))
    pool.shutdown()
    _assert_response(addr, 200)
    _cancel_detach_state(addr)
    assert_equal(len(gate.order), 1)


def _fail_second_worker(slot: Pointer[_WorkerSlot, MutUntrackedOrigin]) -> Int:
    if slot[].index == 1:
        return 11
    return _start_worker(slot)


def test_partial_worker_start_failure_cleans_up() raises:
    var rejected = False
    try:
        _ = _create_pool[_fail_second_worker](WorkerPoolConfig(workers=2))
    except error:
        rejected = (
            error.kind == NetErrorKind.system_error()
            and error.errno.value() == 11
        )
    assert_true(rejected)


def _delayed_start_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    sleep(0.1)
    return _worker_entry(arg)


def _fail_after_delayed_first_worker(
    slot: Pointer[_WorkerSlot, MutUntrackedOrigin]
) -> Int:
    if slot[].index == 1:
        return 11
    return Int(
        external_call["pthread_create", c_int](
            Pointer(to=slot[].handle),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _delayed_start_entry,
            slot.unsafe_bitcast[Byte](),
        )
    )


def test_zero_grace_startup_failure_joins_started_worker() raises:
    var started = perf_counter_ns()
    var rejected = False
    try:
        _ = _create_pool[_fail_after_delayed_first_worker](
            WorkerPoolConfig(workers=2, shutdown_grace=Timeout.nanoseconds(0))
        )
    except error:
        rejected = (
            error.kind == NetErrorKind.system_error()
            and error.errno.value() == 11
        )
    var elapsed = perf_counter_ns() - started
    sleep(0.12)
    assert_true(rejected)
    assert_true(elapsed >= 80_000_000)


@fieldwise_init
struct _SubmitContext(Movable):
    var pool_addr: Int
    var gate_addr: Int
    var addrs: List[Int]
    var accepted: List[Bool]
    var failed: Bool


def _submit_thread(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_SubmitContext]()
    var pool = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=context[].pool_addr
    ).unsafe_bitcast[WorkerPool]()
    try:
        for identity in range(64):
            var sender = _sender()
            context[].addrs.append(sender._addr)
            context[].accepted.append(
                pool[].submit(
                    sender^, _RecordJob(context[].gate_addr, identity + 1)
                )
            )
            sleep(0.0001)
    except:
        context[].failed = True
    return arg


def test_concurrent_submit_and_shutdown_preserve_one_owner() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(
        WorkerPoolConfig(
            workers=1, queue_limit=4, shutdown_grace=Timeout.milliseconds(10)
        )
    )
    var first = _sender()
    var first_addr = first._addr
    assert_true(pool.submit(first^, _BlockedJob(_gate_address(gate), 0)))
    _wait_started(gate)
    var context = _SubmitContext(
        Int(Pointer(to=pool)),
        _gate_address(gate),
        List[Int](),
        List[Bool](),
        False,
    )
    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _submit_thread,
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    sleep(0.002)
    pool.shutdown()
    _join_thread(handle)
    _release_gate(gate)
    _wait_destroyed(gate, 65)
    assert_false(context.failed)
    assert_equal(len(context.addrs), 64)
    assert_equal(len(context.accepted), 64)
    for i in range(64):
        if not context.accepted[i]:
            _assert_response(context.addrs[i], 503)
        _cancel_detach_state(context.addrs[i])
    _cancel_detach_state(first_addr)
    assert_equal(len(gate.order), 1)


@fieldwise_init
struct _ShutdownContext(Copyable, Movable):
    var pool_addr: Int
    var elapsed: Int


def _shutdown_thread(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_ShutdownContext]()
    var pool = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=context[].pool_addr
    ).unsafe_bitcast[WorkerPool]()
    var started = perf_counter_ns()
    pool[].shutdown()
    context[].elapsed = perf_counter_ns() - started
    return arg


def test_concurrent_shutdown_is_bounded_and_idempotent() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(
        WorkerPoolConfig(workers=1, shutdown_grace=Timeout.milliseconds(10))
    )
    var sender = _sender()
    var addr = sender._addr
    assert_true(pool.submit(sender^, _BlockedJob(_gate_address(gate), 0)))
    _wait_started(gate)
    var contexts = [
        _ShutdownContext(Int(Pointer(to=pool)), 0),
        _ShutdownContext(Int(Pointer(to=pool)), 0),
    ]
    var handles = Array[UInt64, 2](fill=0)
    for i in range(2):
        var rc = external_call["pthread_create", c_int](
            Pointer(to=handles[i]),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _shutdown_thread,
            Pointer(to=contexts[i]).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(rc), 0)
    for i in range(2):
        _join_thread(handles[i])
    _ = pool^
    _release_gate(gate)
    _wait_destroyed(gate, 1)
    for i in range(2):
        assert_true(contexts[i].elapsed < 250_000_000)
    assert_true(gate.observed_cancel)
    _cancel_detach_state(addr)


def _move_pool(var pool: WorkerPool) -> WorkerPool:
    return pool^


def test_moved_pool_keeps_stable_native_synchronization() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var first = WorkerPool(WorkerPoolConfig(workers=2))
    var pool = _move_pool(first^)
    var sender = _sender()
    var addr = sender._addr
    assert_true(pool.submit(sender^, _RecordJob(_gate_address(gate), 8)))
    pool.shutdown()
    _assert_response(addr, 200)
    _cancel_detach_state(addr)
    assert_equal(len(gate.destroyed), 1)


@fieldwise_init
struct _BlockedDestructorJob(HandlerJob):
    var gate_addr: Int

    def run(mut self, mut sender: ResponseSender) raises:
        _record_start(self.gate_addr, 0)
        sender.respond()

    def __deinit__(deinit self):
        var gate = _gate(self.gate_addr)
        gate[].mutex.lock()
        gate[].blocked_started = True
        gate[].mutex.unlock()
        while True:
            gate[].mutex.lock()
            var released = gate[].released
            gate[].mutex.unlock()
            if released:
                break
            sleep(0.001)
        _record_destroy(self.gate_addr, 0)


def test_user_destructor_does_not_block_shutdown_or_owner_drop() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(
        WorkerPoolConfig(
            workers=1, queue_limit=1, shutdown_grace=Timeout.milliseconds(10)
        )
    )
    var first = _sender()
    var first_addr = first._addr
    assert_true(pool.submit(first^, _BlockedDestructorJob(_gate_address(gate))))
    _wait_started(gate)
    var queued = _sender()
    var queued_addr = queued._addr
    assert_true(pool.submit(queued^, _RecordJob(_gate_address(gate), 1)))
    var started = perf_counter_ns()
    pool.shutdown()
    _ = pool^
    var elapsed = perf_counter_ns() - started
    _assert_response(first_addr, 200)
    var queued_batch = _take_batch(_detach_state(queued_addr))
    _cancel_detach_state(first_addr)
    _cancel_detach_state(queued_addr)
    _release_gate(gate)
    _wait_destroyed(gate, 2)
    assert_true(elapsed < 250_000_000)
    assert_equal(queued_batch.terminal_kind, MSG_KIND_ABORT)
    assert_equal(len(gate.order), 1)


def test_invalid_config_and_inactive_sender_report_error() raises:
    for workers, queue_limit in [(-1, 1), (1, -1)]:
        var rejected = False
        try:
            _ = WorkerPool(
                WorkerPoolConfig(workers=workers, queue_limit=queue_limit)
            )
        except error:
            rejected = error.kind == NetErrorKind.invalid_argument()
        assert_true(rejected)
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1))
    var rejected = False
    try:
        _ = pool.submit(ResponseSender(0), _RecordJob(_gate_address(gate), 9))
    except error:
        rejected = error.kind == NetErrorKind.invalid_state()
    pool.shutdown()
    assert_true(rejected)
    assert_equal(len(gate.destroyed), 1)


def test_writer_offload_accepts_and_full_pool_completes_503() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    for queue_limit in [1, 0]:
        var pool = WorkerPool(
            WorkerPoolConfig(workers=1, queue_limit=queue_limit)
        )
        var writer = ResponseWriter(1024)
        assert_equal(
            writer.offload(pool, _RecordJob(_gate_address(gate), queue_limit)),
            queue_limit == 1,
        )
        assert_true(writer.is_detached())
        var addr = writer._detach_state_addr
        pool.shutdown()
        _assert_response(addr, 200 if queue_limit == 1 else 503)
        writer._cancel_detach()
    assert_equal(len(gate.destroyed), 2)


def test_writer_offload_failed_detach_releases_job_without_submission() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1))
    var writer = ResponseWriter(1024)
    writer._set_mailbox_budget(SharedBufferBudget(0))
    var rejected = False
    try:
        _ = writer.offload(pool, _RecordJob(_gate_address(gate), 8))
    except:
        rejected = True
    pool.shutdown()
    assert_true(rejected)
    assert_false(writer.is_detached())
    assert_equal(len(gate.order), 0)
    assert_equal(len(gate.destroyed), 1)


def test_writer_offload_already_detached_releases_unsubmitted_job() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1))
    var writer = ResponseWriter(1024)
    var sender = writer.detach()
    var rejected = False
    try:
        _ = writer.offload(pool, _RecordJob(_gate_address(gate), 8))
    except error:
        rejected = error.kind == NetErrorKind.invalid_state()
    sender.abort()
    pool.shutdown()
    writer._cancel_detach()
    assert_true(rejected)
    assert_equal(len(gate.order), 0)
    assert_equal(len(gate.destroyed), 1)


@fieldwise_init
struct _HTTPJob(HandlerJob):
    var gate_addr: Int
    var body: List[Byte]

    def run(mut self, mut sender: ResponseSender) raises:
        _record_start(self.gate_addr, 0, True)
        var gate = _gate(self.gate_addr)
        while True:
            gate[].mutex.lock()
            var released = gate[].released
            gate[].mutex.unlock()
            if released:
                break
            sleep(0.001)
        var cancelled = sender.is_cancelled()
        gate[].mutex.lock()
        gate[].observed_cancel = cancelled
        gate[].mutex.unlock()
        if not cancelled:
            var body = self.body^
            self.body = List[Byte]()
            sender.respond(body=body^)

    def __deinit__(deinit self):
        _record_destroy(self.gate_addr, 0)


@fieldwise_init
struct _OffloadHTTPHandler(Handler):
    var pool_addr: Int
    var gate_addr: Int
    var submitted: Int
    var synchronous: Int

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/offload":
            var pool = Pointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=self.pool_addr
            ).unsafe_bitcast[WorkerPool]()
            _ = writer.offload(
                pool[], _HTTPJob(self.gate_addr, req.body.copy())
            )
            self.submitted += 1
        else:
            writer.write_string("SECOND")
            self.synchronous += 1


def _wait_submitted(
    mut server: Server, mut handler: _OffloadHTTPHandler
) raises:
    var deadline = perf_counter_ns() + 2_000_000_000
    while handler.submitted == 0 and perf_counter_ns() < deadline:
        _ = server.tick(handler, Timeout.nanoseconds(0))
        sleep(0.001)
    assert_equal(handler.submitted, 1)


def test_http1_offload_preserves_pipeline_order_and_sibling_progress() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(WorkerPoolConfig(workers=1))
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _OffloadHTTPHandler(
        Int(Pointer(to=pool)), _gate_address(gate), 0, 0
    )
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var first = dial_tcp(address, Timeout.seconds(1))
    first.write_all(
        (
            "POST /offload HTTP/1.1\r\nHost: x\r\nContent-Length:"
            " 5\r\n\r\nFIRSTGET /sync HTTP/1.1\r\nHost: x\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_submitted(server, handler)
    _wait_started(gate)
    var before_release = handler.synchronous
    var sibling = dial_tcp(address, Timeout.seconds(1))
    sibling.write_all(
        "GET /sync HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    var sibling_response = _tick_and_read(server, handler, sibling)
    _release_gate(gate)
    var response = List[Byte]()
    var scratch = Array[Byte, 8192](fill=0)
    var deadline = perf_counter_ns() + 2_000_000_000
    while perf_counter_ns() < deadline:
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var count = first.try_read(Span(scratch))
            response.extend(Span(scratch)[0:count])
        except error:
            assert_equal(error.kind, NetErrorKind.timeout())
        if len(_split_responses(response)) == 2:
            break
        sleep(0.001)
    pool.shutdown()
    _wait_destroyed(gate, 1)
    var parts = _split_responses(response)
    assert_equal(before_release, 0)
    assert_equal(_status_of(sibling_response), 200)
    assert_equal(_body_of(sibling_response), "SECOND")
    assert_equal(len(parts), 2)
    assert_equal(_body_of(parts[0]), "FIRST")
    assert_equal(_body_of(parts[1]), "SECOND")
    assert_equal(handler.synchronous, 2)
    first.close()
    sibling.close()


def test_blocked_worker_outlives_server_and_pool_safely() raises:
    var gate = _JobGate()
    gate.mutex._initialize()
    var pool = WorkerPool(
        WorkerPoolConfig(workers=1, shutdown_grace=Timeout.milliseconds(10))
    )
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var budget = server._budget.copy()
    var handler = _OffloadHTTPHandler(
        Int(Pointer(to=pool)), _gate_address(gate), 0, 0
    )
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "POST /offload HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nBODY"
        .as_bytes(),
        Timeout.seconds(1),
    )
    _wait_submitted(server, handler)
    _wait_started(gate)
    var started = perf_counter_ns()
    pool.shutdown()
    _ = server^
    _ = pool^
    var elapsed = perf_counter_ns() - started
    var held = budget.used()
    _release_gate(gate)
    _wait_destroyed(gate, 1)
    var deadline = perf_counter_ns() + 2_000_000_000
    while budget.used() != 0 and perf_counter_ns() < deadline:
        sleep(0.001)
    assert_true(elapsed < 250_000_000)
    assert_true(held > 0)
    assert_equal(budget.used(), 0)
    assert_true(gate.observed_cancel)
    client.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
