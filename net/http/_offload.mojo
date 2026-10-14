"""Bounded HTTP job offload through detached response capabilities."""

from std.collections import Deque
from std.os import abort
from std.ffi import c_int, c_size_t, c_ulong, external_call, get_errno
from std.sys import CompilationTarget, size_of
from std.time import perf_counter_ns

from net._actor import PthreadMutex
from net._sys.common import _online_cpu_count
from net.error import NetError, NetErrorKind
from net.http._detach import (
    MSG_KIND_ABORT,
    DetachMessage,
    ResponseSender,
    _detach_state,
    _release_detach_state,
    _unlock_and_wake,
)
from net.http.headers import Headers
from net.timeout import Timeout, _Deadline


comptime OffloadError = NetError
comptime _IS_DARWIN = CompilationTarget.is_macos()


struct WorkerPoolConfig(Copyable, Movable):
    var workers: Int
    var queue_limit: Int
    var shutdown_grace: Timeout

    def __init__(
        out self,
        workers: Int = 0,
        queue_limit: Int = 1024,
        shutdown_grace: Timeout = Timeout.nanoseconds(5_000_000_000),
    ):
        self.workers = workers
        self.queue_limit = queue_limit
        self.shutdown_grace = shutdown_grace.copy()


trait HandlerJob(Deinitable, Movable):
    def run(mut self, mut sender: ResponseSender) raises:
        ...


@fieldwise_init
struct _PoolTimespec(Copyable, Movable):
    var seconds: Int64
    var nanoseconds: Int64


struct _PoolCondition:
    var storage: Array[UInt64, 6]
    var initialized: Bool

    def __init__(out self):
        self.storage = Array[UInt64, 6](fill=0)
        self.initialized = False

    def initialize(mut self) raises NetError:
        var ptr = Pointer(to=self.storage).unsafe_bitcast[Byte]()
        var result: c_int
        comptime if _IS_DARWIN:
            result = external_call["pthread_cond_init", c_int](
                ptr, Optional[Pointer[Byte, MutUntrackedOrigin]](None)
            )
        else:
            var attributes: Int32 = 0
            _ = external_call["pthread_condattr_init", c_int](
                Pointer(to=attributes)
            )
            _ = external_call["pthread_condattr_setclock", c_int](
                Pointer(to=attributes), c_int(1)
            )
            result = external_call["pthread_cond_init", c_int](
                ptr, Pointer(to=attributes)
            )
            _ = external_call["pthread_condattr_destroy", c_int](
                Pointer(to=attributes)
            )
        if result != 0:
            raise NetError(
                NetErrorKind.system_error(),
                "pthread_cond_init",
                Int(result),
                "worker condition initialization failed",
            )
        self.initialized = True

    def signal(mut self):
        _ = external_call["pthread_cond_signal", c_int](
            Pointer(to=self.storage)
        )

    def broadcast(mut self):
        _ = external_call["pthread_cond_broadcast", c_int](
            Pointer(to=self.storage)
        )

    def wait(mut self, mut mutex: PthreadMutex):
        _ = external_call["pthread_cond_wait", c_int](
            Pointer(to=self.storage), Pointer(to=mutex._storage)
        )

    def wait_for(mut self, mut mutex: PthreadMutex, nanoseconds: Int):
        var deadline = _PoolTimespec(
            Int64(nanoseconds // 1_000_000_000),
            Int64(nanoseconds % 1_000_000_000),
        )
        comptime if _IS_DARWIN:
            _ = external_call["pthread_cond_timedwait_relative_np", c_int](
                Pointer(to=self.storage),
                Pointer(to=mutex._storage),
                Pointer(to=deadline),
            )
        else:
            var now = _PoolTimespec(0, 0)
            _ = external_call["clock_gettime", c_int](c_int(1), Pointer(to=now))
            deadline.seconds += now.seconds
            deadline.nanoseconds += now.nanoseconds
            if deadline.nanoseconds >= 1_000_000_000:
                deadline.seconds += 1
                deadline.nanoseconds -= 1_000_000_000
            _ = external_call["pthread_cond_timedwait", c_int](
                Pointer(to=self.storage),
                Pointer(to=mutex._storage),
                Pointer(to=deadline),
            )

    def destroy(mut self):
        if self.initialized:
            _ = external_call["pthread_cond_destroy", c_int](
                Pointer(to=self.storage)
            )


def _run_job[
    J: HandlerJob
](data: Pointer[Byte, MutUntrackedOrigin], mut sender: ResponseSender) raises:
    data.unsafe_bitcast[J]()[].run(sender)


def _destroy_job[J: HandlerJob](data: Pointer[Byte, MutUntrackedOrigin]):
    data.unsafe_bitcast[J]().unsafe_deinit_pointee()
    external_call["free", NoneType](data)


struct _PendingJob(Movable):
    var sender: ResponseSender
    var data_addr: Int
    var run_job: def(
        Pointer[Byte, MutUntrackedOrigin], mut ResponseSender
    ) thin raises -> None
    var destroy_job: def(Pointer[Byte, MutUntrackedOrigin]) thin -> None

    def __init__[
        J: HandlerJob
    ](out self, var sender: ResponseSender, var job: J) raises NetError:
        var data = external_call["malloc", Pointer[Byte, MutUntrackedOrigin]](
            c_size_t(max(1, size_of[J]()))
        )
        if Int(data) == 0:
            raise NetError(
                NetErrorKind.system_error(),
                "malloc",
                Int(get_errno().value),
                "worker job allocation failed",
            )
        data.unsafe_bitcast[J]().unsafe_write(job^)
        self.sender = sender^
        self.data_addr = Int(data)
        self.run_job = _run_job[J]
        self.destroy_job = _destroy_job[J]

    def __init__(out self, *, deinit move: Self):
        self.sender = move.sender^
        self.data_addr = move.data_addr
        self.run_job = move.run_job
        self.destroy_job = move.destroy_job

    def __deinit__(deinit self):
        self.destroy_job(
            Pointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=self.data_addr
            )
        )

    def execute(mut self):
        if self.sender.is_cancelled():
            return
        try:
            self.run_job(
                Pointer[Byte, MutUntrackedOrigin](
                    unsafe_from_address=self.data_addr
                ),
                self.sender,
            )
        except:
            self.sender.abort()


@fieldwise_init
struct _WorkerSlot(Copyable, Movable):
    var pool_addr: Int
    var index: Int
    var handle: UInt64
    var exited: Bool
    var active_addr: Int


struct _PoolState:
    var mutex: PthreadMutex
    var condition: _PoolCondition
    var queue: Deque[_PendingJob]
    var workers: List[_WorkerSlot]
    var references: Int
    var started_workers: Int
    var live_workers: Int
    var accepting: Bool
    var aborting: Bool
    var shutdown_started: Bool
    var handles_claimed: Bool
    var shutdown_expires_at: Int
    var queue_limit: Int
    var grace: Timeout

    def __init__(out self, config: WorkerPoolConfig, count: Int, addr: Int):
        self.mutex = PthreadMutex._uninitialized()
        self.condition = _PoolCondition()
        self.queue = Deque[_PendingJob]()
        self.workers = List[_WorkerSlot]()
        self.workers.reserve(count)
        for index in range(count):
            self.workers.append(_WorkerSlot(addr, index, 0, False, 0))
        self.references = 1
        self.started_workers = 0
        self.live_workers = 0
        self.accepting = True
        self.aborting = False
        self.shutdown_started = False
        self.handles_claimed = False
        self.shutdown_expires_at = 0
        self.queue_limit = config.queue_limit
        self.grace = config.shutdown_grace.copy()

    def __deinit__(deinit self):
        self.condition.destroy()
        self.mutex.destroy()


def _pool_state(addr: Int) -> Pointer[_PoolState, MutUntrackedOrigin]:
    return Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=addr
    ).unsafe_bitcast[_PoolState]()


def _release_pool(addr: Int):
    var state = _pool_state(addr)
    state[].mutex.lock()
    state[].references -= 1
    var destroy = state[].references == 0
    state[].mutex.unlock()
    if destroy:
        state.unsafe_deinit_pointee()
        external_call["free", NoneType](state.unsafe_bitcast[Byte]())


def _retain_response(addr: Int):
    var state = _detach_state(addr)
    state[].mutex.lock()
    state[].ref_count += 1
    state[].mutex.unlock()


def _cancel_response(addr: Int):
    var state = _detach_state(addr)
    state[].mutex.lock()
    if state[].cancelled:
        state[].mutex.unlock()
        return
    state[].cancelled = True
    if state[].finished:
        state[].mutex.unlock()
        return
    state[].finished = True
    state[].messages = List[DetachMessage]()
    state[].array_ticket.release()
    state[].queued_bytes = 0
    state[].terminal_trailers = Headers()
    state[].terminal_kind = MSG_KIND_ABORT
    _unlock_and_wake(state)


def _worker_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var slot = arg.unsafe_bitcast[_WorkerSlot]()
    var addr = slot[].pool_addr
    var index = slot[].index
    var state = _pool_state(addr)
    while True:
        state[].mutex.lock()
        while len(state[].queue) == 0 and state[].accepting:
            state[].condition.wait(state[].mutex)
        if len(state[].queue) == 0:
            state[].workers[index].exited = True
            state[].live_workers -= 1
            state[].condition.broadcast()
            state[].mutex.unlock()
            _release_pool(addr)
            return arg
        var job: _PendingJob
        try:
            job = state[].queue.popleft()
        except:
            abort("nonempty worker queue failed to pop")
        var active_addr = 0
        if not state[].aborting:
            active_addr = job.sender._addr
            _retain_response(active_addr)
            state[].workers[index].active_addr = active_addr
        state[].mutex.unlock()
        job.execute()
        _ = job^
        state[].mutex.lock()
        state[].workers[index].active_addr = 0
        state[].mutex.unlock()
        if active_addr != 0:
            _release_detach_state(active_addr, from_sender=False)


def _start_worker(slot: Pointer[_WorkerSlot, MutUntrackedOrigin]) -> Int:
    return Int(
        external_call["pthread_create", c_int](
            Pointer(to=slot[].handle),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _worker_entry,
            slot.unsafe_bitcast[Byte](),
        )
    )


def _shutdown_pool(addr: Int):
    var state = _pool_state(addr)
    state[].mutex.lock()
    if state[].handles_claimed:
        state[].mutex.unlock()
        return
    if not state[].shutdown_started:
        state[].shutdown_started = True
        state[].accepting = False
        state[].shutdown_expires_at = _Deadline.from_timeout(
            state[].grace
        )._expires_at.value()
        state[].condition.broadcast()
    while state[].live_workers > 0 and not state[].handles_claimed:
        var remaining = state[].shutdown_expires_at - perf_counter_ns()
        if remaining <= 0:
            break
        state[].condition.wait_for(state[].mutex, remaining)
    if state[].handles_claimed:
        state[].mutex.unlock()
        return
    state[].handles_claimed = True
    if state[].live_workers > 0:
        state[].aborting = True
        for index in range(len(state[].queue)):
            _cancel_response(state[].queue[index].sender._addr)
        for index in range(state[].started_workers):
            var active_addr = state[].workers[index].active_addr
            if active_addr != 0:
                _cancel_response(active_addr)
        state[].condition.broadcast()
    var joined = List[UInt64]()
    var detached = List[UInt64]()
    for index in range(state[].started_workers):
        if state[].workers[index].exited:
            joined.append(state[].workers[index].handle)
        else:
            detached.append(state[].workers[index].handle)
    state[].mutex.unlock()
    for handle in joined:
        _ = external_call["pthread_join", c_int](
            c_ulong(handle), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
        )
    for handle in detached:
        _ = external_call["pthread_detach", c_int](c_ulong(handle))


def _stop_started_workers(addr: Int):
    var state = _pool_state(addr)
    state[].mutex.lock()
    state[].accepting = False
    state[].condition.broadcast()
    state[].mutex.unlock()
    for index in range(state[].started_workers):
        _ = external_call["pthread_join", c_int](
            c_ulong(state[].workers[index].handle),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        )


def _create_pool[
    start_worker: def(
        Pointer[_WorkerSlot, MutUntrackedOrigin]
    ) thin -> Int = _start_worker
](config: WorkerPoolConfig) raises NetError -> Int:
    if config.workers < 0 or config.queue_limit < 0:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "WorkerPool",
            None,
            "worker and queue limits must be nonnegative",
        )
    var count = config.workers
    if count == 0:
        count = max(1, _online_cpu_count() // 2)
    var data = external_call["malloc", Pointer[Byte, MutUntrackedOrigin]](
        c_size_t(size_of[_PoolState]())
    )
    if Int(data) == 0:
        raise NetError(
            NetErrorKind.system_error(),
            "malloc",
            Int(get_errno().value),
            "worker pool allocation failed",
        )
    var state = data.unsafe_bitcast[_PoolState]()
    var addr = Int(data)
    state.unsafe_write(_PoolState(config, count, addr))
    state[].mutex._initialize()
    try:
        state[].condition.initialize()
    except error:
        _release_pool(addr)
        raise error^
    for index in range(count):
        state[].mutex.lock()
        state[].references += 1
        state[].live_workers += 1
        state[].mutex.unlock()
        var result = start_worker(Pointer(to=state[].workers[index]))
        state[].mutex.lock()
        if result != 0:
            state[].references -= 1
            state[].live_workers -= 1
            state[].mutex.unlock()
            _stop_started_workers(addr)
            _release_pool(addr)
            raise NetError(
                NetErrorKind.system_error(),
                "pthread_create",
                result,
                "worker startup failed",
            )
        state[].started_workers += 1
        state[].mutex.unlock()
    return addr


struct WorkerPool(Movable):
    """FIFO job workers with bounded admission and grace-limited shutdown.

    Running jobs and their destruction may outlive the pool after grace expires.
    Jobs must own values they need or hold independent lifetime-safe capabilities.
    """

    var _addr: Int

    def __init__(
        out self, config: WorkerPoolConfig = WorkerPoolConfig()
    ) raises OffloadError:
        self._addr = _create_pool(config)

    def __init__(out self, *, deinit move: Self):
        self._addr = move._addr

    def __deinit__(deinit self):
        _shutdown_pool(self._addr)
        _release_pool(self._addr)

    def submit[
        J: HandlerJob
    ](
        mut self, var sender: ResponseSender, var job: J
    ) raises OffloadError -> Bool:
        if not sender.is_active():
            raise NetError(
                NetErrorKind.invalid_state(),
                "WorkerPool.submit",
                None,
                "offload requires an active response sender",
            )
        var pending = _PendingJob(sender^, job^)
        var state = _pool_state(self._addr)
        state[].mutex.lock()
        if not state[].accepting or len(state[].queue) >= state[].queue_limit:
            state[].mutex.unlock()
            var headers = Headers()
            headers.add("Retry-After", "1")
            try:
                pending.sender.respond(status=503, headers=headers^)
            except:
                pending.sender.abort()
            return False
        state[].queue.append(pending^)
        state[].condition.signal()
        state[].mutex.unlock()
        return True

    def shutdown(mut self):
        _shutdown_pool(self._addr)
