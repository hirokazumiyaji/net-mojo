from std.ffi import c_int, c_ulong, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net._sys.common import EINTR
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    Request,
    ResponseSender,
    ResponseWriter,
)
from net.http._detach import (
    MSG_KIND_ABORT,
    MSG_KIND_CHUNK,
    MSG_KIND_FINISH,
    MSG_KIND_RESPOND,
    MSG_KIND_START,
    _create_detach_state,
    _release_detach_state,
    _SharedDetachState,
)
from tests.support import _join_thread


def _move_sender(var sender: ResponseSender) -> ResponseSender:
    return sender^


def test_response_sender_is_movable() raises:
    var writer = ResponseWriter(1024)
    var sender = writer.detach()
    assert_true(writer.is_detached())
    assert_true(sender.is_active())

    var moved = _move_sender(sender^)
    assert_true(moved.is_active())
    assert_false(moved.is_cancelled())


def test_response_writer_detach_once() raises:
    var writer = ResponseWriter(1024)
    _ = writer.detach()
    assert_true(writer.is_detached())

    # Second detach must fail with invalid_state.
    var failed = False
    try:
        _ = writer.detach()
    except e:
        if e.kind == NetErrorKind.invalid_state():
            failed = True
    assert_true(failed)


@fieldwise_init
struct _ThreadProbeContext:
    var sender_addr: Int
    var status_to_send: Int
    var executed: Bool


def _thread_sender_entry(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx_ptr = arg.unsafe_bitcast[_ThreadProbeContext]()
    var sender = ResponseSender(ctx_ptr[].sender_addr)
    try:
        var h = Headers()
        var body = List[Byte]()
        body.append(Byte(ord("o")))
        body.append(Byte(ord("k")))
        sender.respond(ctx_ptr[].status_to_send, h^, body^)
        ctx_ptr[].executed = True
    except:
        ctx_ptr[].executed = False
    return arg


def test_response_sender_callable_from_pthread() raises:
    # Compile probe & runtime verification that ResponseSender can be transferred
    # to and invoked from an external pthread created outside the Mojo runtime.
    var state_addr = _create_detach_state(slot=0, generation=1)
    assert_true(state_addr != 0)

    var ctx = _ThreadProbeContext(
        sender_addr=state_addr,
        status_to_send=201,
        executed=False,
    )
    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _thread_sender_entry,
        Pointer(to=ctx).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    _join_thread(handle)
    assert_true(ctx.executed)

    # Server side inspects the message queue
    var s_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    ).unsafe_bitcast[_SharedDetachState]()
    s_ptr[].mutex.lock()
    assert_equal(len(s_ptr[].messages), 1)
    assert_equal(s_ptr[].messages[0].kind, MSG_KIND_RESPOND)
    assert_equal(s_ptr[].messages[0].status, 201)
    assert_equal(len(s_ptr[].messages[0].body), 2)
    assert_equal(s_ptr[].messages[0].body[0], Byte(ord("o")))
    assert_equal(s_ptr[].messages[0].body[1], Byte(ord("k")))
    s_ptr[].mutex.unlock()

    # Server releases its reference to complete deallocation
    _release_detach_state(state_addr, from_sender=False)


def test_detach_state_lifecycle_and_cleanup() raises:
    var state_addr = _create_detach_state(slot=1, generation=42)
    assert_true(state_addr != 0)

    var sender = ResponseSender(state_addr)
    assert_false(sender.is_cancelled())

    # Cancel connection from server side
    var s_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    ).unsafe_bitcast[_SharedDetachState]()
    s_ptr[].mutex.lock()
    s_ptr[].cancelled = True
    s_ptr[].mutex.unlock()

    # Sender must observe cancellation
    assert_true(sender.is_cancelled())
    var dummy = Array[Byte, 4](fill=0)
    var sent = sender.send(Span(dummy))
    assert_false(sent)

    # Releasing both sides must not leak or crash
    # Server side releases:
    _release_detach_state(state_addr, from_sender=False)
    # sender deinit releases other ref upon exit


def test_sender_drop_without_respond_queues_abort() raises:
    var state_addr = _create_detach_state(slot=2, generation=10)
    assert_true(state_addr != 0)

    # Create and immediately drop sender without calling respond()
    var s_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    ).unsafe_bitcast[_SharedDetachState]()
    s_ptr[].mutex.lock()
    assert_equal(len(s_ptr[].messages), 0)
    s_ptr[].mutex.unlock()

    var sender = ResponseSender(state_addr)
    # Sender is dropped at block exit:
    _ = sender._take()  # manually simulate dropping with cleanup
    _release_detach_state(state_addr, from_sender=True)

    # Inspect that an abort message was automatically queued
    s_ptr[].mutex.lock()
    assert_equal(len(s_ptr[].messages), 1)
    assert_equal(s_ptr[].messages[0].kind, MSG_KIND_ABORT)
    s_ptr[].mutex.unlock()

    # Server side releases remaining ref
    _release_detach_state(state_addr, from_sender=False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
