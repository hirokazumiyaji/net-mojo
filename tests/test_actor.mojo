from std.ffi import c_int, c_ulong, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net._actor import Mailbox, PthreadMutex, WakeupChannel
from tests.support import _join_thread


struct _TestActorMessage(Movable):
    var id: Int
    var payload: String

    def __init__(out self, id: Int, payload: String):
        self.id = id
        self.payload = payload

    def __init__(out self, *, deinit move: Self):
        self.id = move.id
        self.payload = move.payload


def test_pthread_mutex_lifecycle() raises:
    var mutex = PthreadMutex()
    mutex.lock()
    mutex.unlock()
    mutex.destroy()


def test_mailbox_push_pop_all() raises:
    var mb = Mailbox[_TestActorMessage]()
    assert_equal(mb.count(), 0)
    assert_false(mb.is_closed())

    assert_true(mb.push(_TestActorMessage(1, String("first"))))
    assert_true(mb.push(_TestActorMessage(2, String("second"))))
    assert_equal(mb.count(), 2)

    var batch = mb.pop_all()
    assert_equal(len(batch), 2)
    assert_equal(batch[0].id, 1)
    assert_equal(batch[0].payload, "first")
    assert_equal(batch[1].id, 2)
    assert_equal(batch[1].payload, "second")
    assert_equal(mb.count(), 0)


def test_mailbox_close_rejects_new_items() raises:
    var mb = Mailbox[_TestActorMessage]()
    assert_true(mb.push(_TestActorMessage(1, String("kept"))))
    mb.close()
    assert_true(mb.is_closed())

    # Subsequent pushes must be rejected
    assert_false(mb.push(_TestActorMessage(2, String("rejected"))))
    assert_equal(mb.count(), 1)

    var batch = mb.pop_all()
    assert_equal(len(batch), 1)
    assert_equal(batch[0].payload, "kept")


def test_wakeup_channel_signal_and_drain() raises:
    var chan = WakeupChannel()
    assert_true(chan.read_fd() >= 0)
    assert_true(chan.write_fd() >= 0)

    chan.signal()
    chan.signal()
    # Drain must consume all bytes without blocking
    chan.drain()


@fieldwise_init
struct _ThreadProducerContext:
    var mb_addr: Int
    var count: Int
    var wakeup_write_fd: Int32


def _producer_thread_entry(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx_ptr = arg.unsafe_bitcast[_ThreadProducerContext]()
    var mb_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=ctx_ptr[].mb_addr
    ).unsafe_bitcast[Mailbox[_TestActorMessage]]()

    for i in range(ctx_ptr[].count):
        _ = mb_ptr[].push(_TestActorMessage(i, String("msg")))
    return arg


def test_actor_threaded_message_passing() raises:
    var mb = Mailbox[_TestActorMessage]()
    var chan = WakeupChannel()

    var ctx = _ThreadProducerContext(
        mb_addr=Int(Pointer(to=mb)),
        count=100,
        wakeup_write_fd=chan.write_fd(),
    )

    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _producer_thread_entry,
        Pointer(to=ctx).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    _join_thread(handle)

    # Receiver verifies all messages arrived in order
    var received = mb.pop_all()
    assert_equal(len(received), 100)
    for i in range(100):
        assert_equal(received[i].id, i)
        assert_equal(received[i].payload, "msg")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
