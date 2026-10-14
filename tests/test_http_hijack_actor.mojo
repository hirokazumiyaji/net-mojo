from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_true, TestSuite
from std.sys import size_of

from net import Timeout, dial_tcp, listen_tcp
from net._actor import WakeupChannel, signal_wakeup_fd
from net._sys.common import _wait_readable
from net.timeout import _Deadline
from net.error import NetErrorKind
from net.http import HijackedConn
from net.http._buffer import SharedBufferBudget, _CapacityTicket
from net.http._hijack import (
    HijackSender,
    _SharedHijackState,
    _create_hijack_state,
    _hijack_state,
    _cancel_hijack_state,
    _complete_hijack_state,
    _release_hijack_state,
)
from tests.support import _join_thread, _to_bytes


@fieldwise_init
struct _TakeContext(Movable):
    var addr: Int
    var ready_fd: Int32
    var connection: Optional[HijackedConn]
    var error_kind: NetErrorKind


def _take_on_worker(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_TakeContext]()
    var sender = HijackSender(context[].addr)
    context[].addr = 0
    signal_wakeup_fd(context[].ready_fd)
    try:
        context[].connection = sender^.take_connection()
    except error:
        context[].error_kind = error.kind.copy()
    return arg


def test_hijack_waiter_receives_owned_connection_or_closed() raises:
    for mode in range(3):
        var budget = SharedBufferBudget(65536)
        var ready = WakeupChannel()
        var addr = _create_hijack_state(4, UInt64(9), budget=budget.copy())
        var context = _TakeContext(
            addr, ready.write_fd(), None, NetErrorKind.unsupported()
        )
        var thread: UInt64 = 0
        assert_equal(
            external_call["pthread_create", c_int](
                Pointer(to=thread),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                _take_on_worker,
                Pointer(to=context).unsafe_bitcast[Byte](),
            ),
            0,
        )
        var notified = _wait_readable(
            ready.read_fd(), _Deadline.from_timeout(Timeout.seconds(5))
        )
        if mode == 0:
            var listener = listen_tcp("127.0.0.1:0")
            var client = dial_tcp(String(listener.local_address()))
            var accepted = listener.accept(Timeout.seconds(1))
            assert_true(
                _complete_hijack_state(
                    addr, HijackedConn(accepted^, _to_bytes("raw"))
                )
            )
            _release_hijack_state(addr, from_sender=False)
            _join_thread(thread)
            assert_true(context.connection)
            var connection = context.connection.take()
            assert_equal(String(from_utf8_lossy=connection.buffered()), "raw")
            assert_equal(connection.try_write(String("x").as_bytes()), 1)
            var byte = Array[Byte, 1](fill=0)
            assert_equal(client.read(Span(byte), Timeout.seconds(1)), 1)
            connection^.close()
        else:
            if mode == 1:
                _cancel_hijack_state(addr)
            _release_hijack_state(addr, from_sender=False)
            _join_thread(thread)
            assert_equal(context.error_kind, NetErrorKind.closed())
        assert_true(notified)
        ready.drain()
        assert_equal(budget.used(), 0)


def test_hijack_abort_refunds_wire_and_state_and_wakes_loop() raises:
    var budget = SharedBufferBudget(65536)
    var wakeup = WakeupChannel()
    var wire = _to_bytes("101")
    assert_true(budget.try_reserve(wire.capacity()))
    var ticket = _CapacityTicket(budget.copy(), wire.capacity())
    var addr = _create_hijack_state(
        2, UInt64(7), wakeup.write_fd(), budget.copy(), wire^, ticket^
    )
    assert_true(budget.used() >= size_of[_SharedHijackState]() + 3)
    assert_equal(_hijack_state(addr)[].slot, 2)
    assert_equal(_hijack_state(addr)[].generation, UInt64(7))
    var sender = HijackSender(addr)
    var moved = sender^
    moved^.abort()
    assert_true(_hijack_state(addr)[].cancelled)
    assert_true(
        _wait_readable(
            wakeup.read_fd(), _Deadline.from_timeout(Timeout.seconds(1))
        )
    )
    _release_hijack_state(addr, from_sender=False)
    assert_equal(budget.used(), 0)


def test_completed_hijack_drop_closes_unclaimed_transport() raises:
    var budget = SharedBufferBudget(65536)
    var addr = _create_hijack_state(0, UInt64(1), budget=budget.copy())
    var sender = HijackSender(addr)
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()))
    var accepted = listener.accept(Timeout.seconds(1))
    assert_true(
        _complete_hijack_state(addr, HijackedConn(accepted^, List[Byte]()))
    )
    _cancel_hijack_state(addr)
    assert_true(not sender.is_cancelled())
    _release_hijack_state(addr, from_sender=False)
    sender^.abort()
    var buffer = Array[Byte, 1](fill=0)
    assert_equal(client.read(Span(buffer), Timeout.seconds(1)), 0)
    assert_equal(budget.used(), 0)


def test_cancelled_hijack_rejects_transport_publication() raises:
    var budget = SharedBufferBudget(65536)
    var addr = _create_hijack_state(0, UInt64(1), budget=budget.copy())
    var sender = HijackSender(addr)
    _cancel_hijack_state(addr)
    assert_true(sender.is_cancelled())
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()))
    var accepted = listener.accept(Timeout.seconds(1))
    assert_true(
        not _complete_hijack_state(addr, HijackedConn(accepted^, List[Byte]()))
    )
    _release_hijack_state(addr, from_sender=False)
    var closed = False
    try:
        _ = sender^.take_connection()
    except error:
        closed = error.kind == NetErrorKind.closed()
    assert_true(closed)
    var buffer = Array[Byte, 1](fill=0)
    assert_equal(client.read(Span(buffer), Timeout.seconds(1)), 0)
    assert_equal(budget.used(), 0)


def test_hijack_state_budget_rejection_leaves_budget_uncharged() raises:
    var budget = SharedBufferBudget(1)
    var rejected = False
    try:
        _ = _create_hijack_state(0, UInt64(1), budget=budget.copy())
    except error:
        rejected = error.kind == NetErrorKind.invalid_argument()
    assert_true(rejected)
    assert_equal(budget.used(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
