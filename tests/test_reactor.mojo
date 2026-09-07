from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns

from net import Timeout, dial_tcp, listen_tcp
from net._reactor import Reactor
from tests.support import (
    _arm_eintr_probe,
    _count_open_fds,
    _disarm_alarm,
    _sound_alarm,
)


def test_register_wait_remove_single_connection() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    assert_equal(len(reactor), 0)
    assert_true(reactor.is_empty())
    var token = reactor.register(server.raw_fd())
    assert_equal(len(reactor), 1)
    assert_true(reactor.contains(token))

    var greeting: Array[Byte, 5] = [104, 101, 108, 108, 111]
    client.write_all(Span(greeting), Timeout.seconds(1))

    var events = reactor.wait(Timeout.seconds(1))
    assert_equal(len(events), 1)
    assert_equal(events[0].token, token)
    assert_true(events[0].readable)
    assert_false(events[0].writable)
    assert_false(events[0].has_error)

    var received = Array[Byte, 5](fill=0)
    assert_equal(server.try_read(Span(received)), 5)

    assert_true(reactor.remove(token))
    assert_equal(len(reactor), 0)
    assert_false(reactor.contains(token))
    # Second remove reports stale instead of crashing.
    assert_false(reactor.remove(token))

    client.close()
    server.close()
    listener.close()


def test_interest_change_avoids_writable_busy_loop() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    # Readable-only with no data and no unsent bytes: nothing ready.
    # A level-triggered loop must not spin on writable here.
    var token = reactor.register(server.raw_fd(), readable=True, writable=False)
    var idle = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(idle), 0)

    # Enabling writable interest reports the (always writable) socket once.
    assert_true(reactor.modify(token, True, True))
    var writable = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(writable), 1)
    assert_true(writable[0].writable)

    # Disabling writable again silences it.
    assert_true(reactor.modify(token, True, False))
    var quiet = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(quiet), 0)

    # Stale tokens cannot change interests.
    assert_true(reactor.remove(token))
    assert_false(reactor.modify(token, True, True))

    client.close()
    server.close()
    listener.close()


def test_idle_wait_times_out() raises:
    var empty = Reactor()
    var no_syscall = empty.wait(Timeout.nanoseconds(0))
    assert_equal(len(no_syscall), 0)

    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var reactor = Reactor()
    var token = reactor.register(server.raw_fd())
    var start = Int(perf_counter_ns())
    var events = reactor.wait(Timeout.milliseconds(50))
    var elapsed_ms = (Int(perf_counter_ns()) - start) // 1_000_000
    assert_equal(len(events), 0)
    assert_true(elapsed_ms >= 30)
    assert_true(reactor.remove(token))
    client.close()
    server.close()
    listener.close()


def test_read_write_simultaneous_notifications() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var target = String(listener.local_address())
    var client = dial_tcp(target, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    var server_token = reactor.register(server.raw_fd())
    var client_token = reactor.register(client.raw_fd())
    assert_equal(len(reactor), 2)

    var ping: Array[Byte, 1] = [1]
    var pong: Array[Byte, 1] = [2]
    client.write_all(Span(ping), Timeout.seconds(1))
    server.write_all(Span(pong), Timeout.seconds(1))

    # `wait` returns on the first readiness, so collect across waits
    # until both directions have been observed.
    var saw_server = False
    var saw_client = False
    for _ in range(20):
        var events = reactor.wait(Timeout.milliseconds(100))
        for i in range(len(events)):
            if events[i].token == server_token:
                saw_server = True
                assert_true(events[i].readable)
            if events[i].token == client_token:
                saw_client = True
                assert_true(events[i].readable)
        if saw_server and saw_client:
            break
    assert_true(saw_server)
    assert_true(saw_client)

    assert_true(reactor.remove(server_token))
    assert_true(reactor.remove(client_token))
    client.close()
    server.close()
    listener.close()


def test_fd_reuse_keeps_old_token_stale() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var target = String(listener.local_address())
    var client = dial_tcp(target, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    var old = reactor.register(server.raw_fd())
    var old_slot = old.slot
    assert_true(reactor.remove(old))
    assert_false(reactor.contains(old))

    # Re-registering reuses the freed slot with a new generation.
    var new = reactor.register(server.raw_fd())
    assert_equal(new.slot, old_slot)
    assert_true(new.generation != old.generation)
    assert_false(reactor.contains(old))
    assert_true(reactor.contains(new))
    assert_false(reactor.modify(old, True, True))
    assert_false(reactor.remove(old))

    # Readiness is reported under the new token only.
    var ping: Array[Byte, 1] = [9]
    client.write_all(Span(ping), Timeout.seconds(1))
    var events = reactor.wait(Timeout.seconds(1))
    assert_equal(len(events), 1)
    assert_equal(events[0].token, new)
    assert_true(events[0].token != old)

    assert_true(reactor.remove(new))
    client.close()
    server.close()
    listener.close()


def test_close_and_reopen_never_resurrects_token() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var target = String(listener.local_address())
    var client = dial_tcp(target, Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    var first = reactor.register(server.raw_fd())
    assert_true(reactor.remove(first))
    client.close()
    server.close()

    # Open a fresh pair; even if the OS recycles the fd number, the old
    # token stays stale because its slot is inactive with an old generation.
    var client2 = dial_tcp(target, Timeout.seconds(1))
    var server2 = listener.accept(Timeout.seconds(1))
    var second = reactor.register(server2.raw_fd())
    assert_true(second != first)
    assert_false(reactor.contains(first))
    assert_true(reactor.contains(second))

    var ping: Array[Byte, 1] = [7]
    client2.write_all(Span(ping), Timeout.seconds(1))
    var events = reactor.wait(Timeout.seconds(1))
    assert_equal(len(events), 1)
    assert_equal(events[0].token, second)

    assert_true(reactor.remove(second))
    client2.close()
    server2.close()
    listener.close()


def test_eintr_retries_to_deadline() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var reactor = Reactor()
    var token = reactor.register(server.raw_fd())

    _arm_eintr_probe()
    _sound_alarm(1)
    var start = Int(perf_counter_ns())
    var events = reactor.wait(Timeout.seconds(3))
    var elapsed_ms = (Int(perf_counter_ns()) - start) // 1_000_000
    _disarm_alarm()
    # The alarm interrupts poll with EINTR; the reactor retries against
    # the same deadline and reports a timeout, not a system error.
    assert_equal(len(events), 0)
    assert_true(elapsed_ms >= 2500)

    assert_true(reactor.remove(token))
    client.close()
    server.close()
    listener.close()


def test_remove_then_close_leaves_no_watch_or_leak() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var target = String(listener.local_address())
    for _ in range(3):
        var warm_client = dial_tcp(target, Timeout.seconds(1))
        var warm_server = listener.accept(Timeout.seconds(1))
        warm_client.close()
        warm_server.close()
    var before = _count_open_fds()
    assert_true(before > 0)

    for _ in range(20):
        var reactor = Reactor()
        var client = dial_tcp(target, Timeout.seconds(1))
        var server = listener.accept(Timeout.seconds(1))
        var token = reactor.register(server.raw_fd())
        assert_true(reactor.remove(token))
        reactor.clear()
        client.close()
        server.close()

    var after = _count_open_fds()
    assert_equal(before, after)
    listener.close()


def test_terminal_hangup_reported_without_interests() raises:
    # A registration with neither interest must still surface a peer
    # close: otherwise the loop would spin on an undeliverable hangup
    # with no event to act on.
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    var token = reactor.register(
        server.raw_fd(), readable=False, writable=False
    )
    var quiet = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(quiet), 0)

    client.close()
    var events = reactor.wait(Timeout.seconds(1))
    assert_equal(len(events), 1)
    assert_equal(events[0].token, token)
    assert_true(events[0].readable)

    var eof = Array[Byte, 1](fill=0)
    assert_equal(server.try_read(Span(eof)), 0)

    assert_true(reactor.remove(token))
    server.close()
    listener.close()


def test_paused_readable_direction_stays_quiet() raises:
    # Disabling reads while keeping writes must suppress ordinary
    # readiness: backpressure pauses must not spin or starve others.
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var reactor = Reactor()
    var token = reactor.register(server.raw_fd(), readable=False, writable=True)
    var ping: Array[Byte, 1] = [5]
    client.write_all(Span(ping), Timeout.seconds(1))
    # The idle socket is writable, so an event arrives — but it must
    # not claim readability for the paused direction.
    var quiet = reactor.wait(Timeout.milliseconds(100))
    assert_equal(len(quiet), 1)
    assert_false(quiet[0].readable)
    assert_true(quiet[0].writable)

    assert_true(reactor.modify(token, True, True))
    # The byte was already in flight; collect until readability shows
    # (a wait may return first on the always-ready writable side).
    var seen_readable = False
    for _ in range(20):
        var events = reactor.wait(Timeout.milliseconds(100))
        for i in range(len(events)):
            if events[i].token == token and events[i].readable:
                seen_readable = True
                break
        if seen_readable:
            break
    assert_true(seen_readable)

    assert_true(reactor.remove(token))
    client.close()
    server.close()
    listener.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
