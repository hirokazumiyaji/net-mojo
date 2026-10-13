from std.ffi import c_int, external_call
from std.time import perf_counter_ns, sleep
from tests.support import _join_thread
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net import Timeout
from net._actor import WakeupChannel, signal_wakeup_fd
from net._sys.common import _wait_readable
from net.timeout import _Deadline
from net.error import NetError, NetErrorKind
from net.http import Headers, HttpVersion, Request, RequestBodyReceiver
from net.http._body_pipe import _BodyPipe
from net.http._buffer import SharedBufferBudget


def test_partial_reads_and_consumed_credit() raises:
    var budget = SharedBufferBudget(1024)
    var pipe = _BodyPipe(8, budget.copy())
    assert_true(pipe.push(String("abc").as_bytes()))
    assert_true(pipe.push(String("def").as_bytes()))
    assert_equal(pipe.total_decoded(), 6)
    var buf = List[Byte](length=2, fill=0)
    assert_equal(pipe.pop(Span(buf)), 2)
    assert_equal(String(from_utf8_lossy=Span(buf)), "ab")
    assert_equal(pipe.take_consumed(), 2)
    assert_equal(pipe.take_consumed(), 0)
    assert_equal(pipe.pop(Span(buf)), 2)
    assert_equal(String(from_utf8_lossy=Span(buf)), "cd")
    assert_equal(pipe.pop(Span(buf)), 2)
    assert_equal(String(from_utf8_lossy=Span(buf)), "ef")
    assert_equal(budget.used(), 0)
    pipe.push_eof()
    assert_equal(pipe.pop(Span(buf)), 0)
    assert_true(pipe.is_eof())
    assert_false(pipe.push(String("g").as_bytes()))


def test_empty_before_eof_is_timeout() raises:
    var pipe = _BodyPipe(8, SharedBufferBudget(64))
    var buf = List[Byte](length=2, fill=0)
    var timed_out = False
    try:
        _ = pipe.pop(Span(buf))
    except error:
        timed_out = error.kind == NetErrorKind.timeout()
    assert_true(timed_out)
    assert_false(pipe.is_eof())


def test_limit_is_unconsumed_bytes() raises:
    var budget = SharedBufferBudget(128)
    var pipe = _BodyPipe(4, budget.copy())
    assert_true(pipe.push(String("abcd").as_bytes()))
    assert_false(pipe.push(String("e").as_bytes()))
    var buf = List[Byte](length=4, fill=0)
    assert_equal(pipe.pop(Span(buf)), 4)
    assert_true(pipe.push(String("efgh").as_bytes()))
    assert_equal(pipe.total_decoded(), 8)
    assert_equal(pipe.pop(Span(buf)), 4)
    assert_equal(budget.used(), 0)


def test_budget_rejection_and_cancellation() raises:
    var budget = SharedBufferBudget(4)
    var pipe = _BodyPipe(32, budget.copy())
    assert_true(pipe.push(String("abcd").as_bytes()))
    assert_false(pipe.push(String("e").as_bytes()))
    assert_equal(budget.used(), 4)
    var alias = pipe.copy()
    alias.cancel()
    assert_equal(budget.used(), 0)
    assert_false(pipe.push(String("e").as_bytes()))
    var buf = List[Byte](length=1, fill=0)
    var cancelled = False
    try:
        _ = pipe.pop(Span(buf))
    except error:
        cancelled = error.kind == NetErrorKind.cancelled()
    assert_true(cancelled)


def test_trailers_after_consumed_eof() raises:
    var pipe = _BodyPipe(8, SharedBufferBudget(4096))
    assert_true(pipe.push(String("a").as_bytes()))
    var trailers = Headers()
    trailers.add("X-Check", "done")
    pipe.push_eof(trailers^)
    var premature = False
    try:
        _ = pipe.trailers()
    except error:
        premature = error.kind == NetErrorKind.invalid_state()
    assert_true(premature)
    var buf = List[Byte](length=1, fill=0)
    assert_equal(pipe.pop(Span(buf)), 1)
    assert_true(pipe.is_eof())
    assert_equal(pipe.trailers().get_first("x-check"), Optional[String]("done"))


def test_buffered_request_view_preserves_list() raises:
    var request = Request("POST", "/", "/", "", HttpVersion.http11())
    request.body.append(Byte(97))
    request.trailers.add("X-Check", "buffered")
    var view = request.body_reader()
    assert_false(view.is_streaming())
    assert_true(view.is_eof())
    assert_equal(view.total_decoded(), 1)
    assert_equal(view.buffered()[0], Byte(97))
    var buf = List[Byte](length=1, fill=0)
    assert_equal(view.read(Span(buf)), 0)
    assert_equal(
        view.trailers().get_first("x-check"), Optional[String]("buffered")
    )
    assert_equal(len(request.body), 1)


def test_compaction_preserves_order() raises:
    var budget = SharedBufferBudget(64)
    var pipe = _BodyPipe(8, budget.copy())
    assert_true(pipe.push(String("abcdef").as_bytes()))
    var buf = List[Byte](length=4, fill=0)
    assert_equal(pipe.pop(Span(buf)), 4)
    assert_true(pipe.push(String("ghij").as_bytes()))
    assert_equal(pipe.pop(Span(buf)), 4)
    assert_equal(String(from_utf8_lossy=Span(buf)), "efgh")
    assert_equal(pipe.pop(Span(buf)), 2)
    assert_equal(String(from_utf8_lossy=Span(buf)[0:2]), "ij")
    assert_equal(budget.used(), 0)


def test_discard_drains_future_input() raises:
    var budget = SharedBufferBudget(64)
    var pipe = _BodyPipe(4, budget.copy())
    assert_true(pipe.push(String("abcd").as_bytes()))
    pipe.discard()
    assert_equal(budget.used(), 0)
    assert_true(pipe.push(String("efghijkl").as_bytes()))
    assert_equal(pipe.pending_bytes(), 0)
    assert_equal(pipe.take_consumed(), 12)
    assert_equal(pipe.total_decoded(), 12)
    assert_false(pipe.is_eof())
    pipe.push_eof()
    assert_true(pipe.is_eof())


def test_last_owner_refunds_storage() raises:
    var budget = SharedBufferBudget(64)
    var pipe = _BodyPipe(4, budget.copy())
    assert_true(pipe.push(String("abcd").as_bytes()))
    var alias = pipe.copy()
    _ = pipe^
    assert_equal(budget.used(), 4)
    _ = alias^
    assert_equal(budget.used(), 0)


def test_streaming_request_view_claims_once() raises:
    var request = Request("POST", "/", "/", "", HttpVersion.http11())
    var pipe = _BodyPipe(8, SharedBufferBudget(64))
    request._body_pipe = pipe.copy()
    var view = request.body_reader()
    assert_true(view.is_streaming())
    assert_false(view.is_eof())
    assert_equal(len(view.buffered()), 0)
    var duplicate = False
    try:
        _ = request.body_reader()
    except error:
        duplicate = error.kind == NetErrorKind.invalid_state()
    assert_true(duplicate)
    assert_true(pipe.push(String("hello").as_bytes()))
    pipe.push_eof()
    var buf = List[Byte](length=8, fill=0)
    assert_equal(view.read(Span(buf)), 5)
    assert_equal(String(from_utf8_lossy=Span(buf)[0:5]), "hello")
    assert_equal(view.total_decoded(), 5)
    assert_true(view.is_eof())
    assert_equal(view.read(Span(buf)), 0)


def test_eof_trailer_budget_failure_is_retryable() raises:
    var budget = SharedBufferBudget(4)
    var pipe = _BodyPipe(4, budget.copy())
    var trailers = Headers()
    trailers.add("X-Check", "done")
    var rejected = False
    try:
        pipe.push_eof(trailers^)
    except error:
        rejected = error.kind == NetErrorKind.invalid_argument()
    assert_true(rejected)
    assert_false(pipe.is_eof())
    pipe.push_eof()
    assert_true(pipe.is_eof())
    assert_equal(budget.used(), 0)


@fieldwise_init
struct _PipeProducerContext(Movable):
    var pipe: _BodyPipe
    var failed: Bool


def _produce_pipe(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_PipeProducerContext]()
    for chunk in range(32):
        var bytes = List[Byte](length=16, fill=Byte(chunk))
        while not context[].pipe.push(Span(bytes)):
            if context[].pipe.is_cancelled():
                context[].failed = True
                return arg
            sleep(0.001)
    try:
        context[].pipe.push_eof()
    except:
        context[].failed = True
    return arg


def _exercise_cross_thread_producer_and_consumer() raises:
    var budget = SharedBufferBudget(128)
    var pipe = _BodyPipe(32, budget.copy())
    var context = _PipeProducerContext(pipe.copy(), False)
    var thread: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _produce_pipe,
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    var buffer = List[Byte](length=7, fill=0)
    var total = 0
    var valid = True
    var deadline = perf_counter_ns() + 10_000_000_000
    while perf_counter_ns() < deadline:
        var count = -1
        try:
            count = pipe.pop(Span(buffer))
        except error:
            valid = valid and error.kind == NetErrorKind.timeout()
            sleep(0.001)
        if count == 0:
            break
        if count > 0:
            for i in range(count):
                valid = valid and buffer[i] == Byte((total + i) // 16)
            total += count
    var completed = pipe.is_eof()
    if not completed:
        pipe.cancel()
    _join_thread(thread)
    assert_false(context.failed)
    assert_true(completed)
    assert_true(valid)
    assert_equal(total, 512)
    assert_equal(pipe.take_consumed(), 512)
    assert_equal(budget.used(), 0)


def test_cross_thread_producer_and_consumer() raises:
    for _ in range(16):
        _exercise_cross_thread_producer_and_consumer()


def test_detached_receiver_outlives_request() raises:
    var request = Request("POST", "/", "/", "", HttpVersion.http11())
    var pipe = _BodyPipe(16, SharedBufferBudget(128))
    request._body_pipe = pipe.copy()
    var view = request.body_reader()
    var receiver = view.detach()
    var unavailable = False
    var buffer = List[Byte](length=16, fill=0)
    try:
        _ = view.read(Span(buffer))
    except error:
        unavailable = error.kind == NetErrorKind.invalid_state()
    assert_true(unavailable)
    _ = view^
    _ = request^
    assert_true(pipe.push(String("owned").as_bytes()))
    pipe.push_eof()
    assert_equal(receiver.receive(Span(buffer), Timeout.nanoseconds(0)), 5)
    assert_equal(String(from_utf8_lossy=Span(buffer)[0:5]), "owned")
    assert_equal(receiver.receive(Span(buffer), Timeout.nanoseconds(0)), 0)
    assert_true(receiver.is_eof())


def test_detached_receive_timeout_and_cancellation() raises:
    var request = Request("POST", "/", "/", "", HttpVersion.http11())
    var pipe = _BodyPipe(16, SharedBufferBudget(128))
    request._body_pipe = pipe.copy()
    var view = request.body_reader()
    var receiver = view.detach()
    var buffer = List[Byte](length=1, fill=0)
    var timed_out = False
    try:
        _ = receiver.receive(Span(buffer), Timeout.milliseconds(1))
    except error:
        timed_out = error.kind == NetErrorKind.timeout()
    assert_true(timed_out)
    pipe.cancel()
    var cancelled = False
    try:
        _ = receiver.receive(Span(buffer))
    except error:
        cancelled = error.kind == NetErrorKind.cancelled()
    assert_true(cancelled)


@fieldwise_init
struct _ReceiverContext(Movable):
    var receiver: RequestBodyReceiver
    var buffer: Array[Byte, 8]
    var count: Int
    var error_kind: NetErrorKind
    var ready_fd: Int32


def _receive_pipe(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_ReceiverContext]()
    signal_wakeup_fd(context[].ready_fd)
    try:
        context[].count = context[].receiver.receive(
            Span(context[].buffer), Timeout.seconds(1)
        )
    except error:
        context[].error_kind = error.kind.copy()
    return arg


def test_blocked_receiver_wakes_on_input_eof_and_cancel() raises:
    for mode in range(3):
        var ready = WakeupChannel()
        var pipe = _BodyPipe(16, SharedBufferBudget(128))
        var request = Request("POST", "/", "/", "", HttpVersion.http11())
        request._body_pipe = pipe.copy()
        var view = request.body_reader()
        var context = _ReceiverContext(
            view.detach(),
            Array[Byte, 8](fill=0),
            -1,
            NetErrorKind.unsupported(),
            ready.write_fd(),
        )
        var thread: UInt64 = 0
        var result = external_call["pthread_create", c_int](
            Pointer(to=thread),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _receive_pipe,
            Pointer(to=context).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(result), 0)
        var notified = _wait_readable(
            ready.read_fd(), _Deadline.from_timeout(Timeout.seconds(1))
        )
        if mode == 0:
            _ = pipe.push(String("ready").as_bytes())
        elif mode == 1:
            pipe.push_eof()
        else:
            pipe.cancel()
        _join_thread(thread)
        assert_true(notified)
        if mode == 0:
            assert_equal(context.count, 5)
            assert_equal(
                String(from_utf8_lossy=Span(context.buffer)[0:5]), "ready"
            )
        elif mode == 1:
            assert_equal(context.count, 0)
        else:
            assert_equal(context.error_kind, NetErrorKind.cancelled())
        ready.drain()


def test_consumption_signals_server_wakeup() raises:
    var wakeup = WakeupChannel()
    var pipe = _BodyPipe(16, SharedBufferBudget(128), wakeup.write_fd())
    assert_true(pipe.push(String("credit").as_bytes()))
    var buffer = Array[Byte, 8](fill=0)
    assert_equal(pipe.pop(Span(buffer)), 6)
    assert_true(
        _wait_readable(
            wakeup.read_fd(), _Deadline.from_timeout(Timeout.milliseconds(10))
        )
    )
    wakeup.drain()
    pipe.cancel()
    wakeup.drain()


def test_empty_detached_receive_buffer_is_rejected() raises:
    var request = Request("POST", "/", "/", "", HttpVersion.http11())
    var pipe = _BodyPipe(16, SharedBufferBudget(128))
    request._body_pipe = pipe.copy()
    var view = request.body_reader()
    var receiver = view.detach()
    var empty = List[Byte]()
    var rejected = False
    try:
        _ = receiver.receive(Span(empty))
    except error:
        rejected = error.kind == NetErrorKind.invalid_argument()
    assert_true(rejected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
