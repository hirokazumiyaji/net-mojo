from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net import (
    Poller,
    Timeout,
    dial_tcp,
    listen_tcp,
    listen_udp,
)
from net.error import NetErrorKind


def test_poller_serves_two_connections_single_threaded() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var dial_target = String(listening)

    var client1 = dial_tcp(dial_target, Timeout.seconds(1))
    var server1 = listener.accept(Timeout.seconds(1))
    var client2 = dial_tcp(dial_target, Timeout.seconds(1))
    var server2 = listener.accept(Timeout.seconds(1))

    var server1_fd = server1.raw_fd()
    var server2_fd = server2.raw_fd()

    var poller = Poller()
    poller.add(server1_fd)
    poller.add(server2_fd)
    assert_equal(len(poller), 2)

    var greeting: Array[Byte, 5] = [104, 101, 108, 108, 111]
    client1.write_all(Span(greeting), Timeout.seconds(1))

    assert_equal(poller.wait(Timeout.seconds(1)), 1)
    assert_true(poller.is_readable(0))
    assert_false(poller.is_readable(1))
    assert_false(poller.has_error(0))
    assert_false(poller.has_error(1))

    var received = Array[Byte, 5](fill=0)
    assert_equal(server1.try_read(Span(received)), 5)
    assert_equal(received[0], Byte(104))
    assert_equal(received[4], Byte(111))

    assert_equal(poller.wait(Timeout.nanoseconds(0)), 0)

    # The second registration serves the other client the same way.
    var reply: Array[Byte, 3] = [1, 2, 3]
    client2.write_all(Span(reply), Timeout.seconds(1))
    assert_equal(poller.wait(Timeout.seconds(1)), 1)
    assert_false(poller.is_readable(0))
    assert_true(poller.is_readable(1))
    var received2 = Array[Byte, 3](fill=0)
    assert_equal(server2.try_read(Span(received2)), 3)
    assert_equal(received2[2], Byte(3))

    poller.remove(0)
    assert_equal(len(poller), 1)
    assert_equal(poller.fd(0), server2_fd)
    poller.clear()
    assert_equal(len(poller), 0)
    assert_equal(poller.wait(Timeout.nanoseconds(0)), 0)

    # Pin every socket lifetime: Mojo destroys a move-only value at its
    # last use, which would close its fd while the Poller still watches
    # the number.
    client1.close()
    client2.close()
    server1.close()
    server2.close()
    listener.close()


def test_try_accept_reports_timeout_when_empty() raises:
    var listener = listen_tcp("127.0.0.1:0")
    try:
        _ = listener.try_accept()
    except error:
        assert_equal(error.kind, NetErrorKind.timeout())
        return
    raise Error("try_accept unexpectedly succeeded")


def test_try_read_reports_timeout_then_data() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var empty = Array[Byte, 1](fill=0)
    try:
        _ = server.try_read(Span(empty))
    except error:
        assert_equal(error.kind, NetErrorKind.timeout())
    else:
        raise Error("try_read unexpectedly succeeded without data")

    var sent: Array[Byte, 1] = [99]
    assert_equal(client.try_write(Span(sent)), 1)
    var watcher = Poller()
    watcher.add(server.raw_fd())
    assert_equal(watcher.wait(Timeout.seconds(1)), 1)
    var received = Array[Byte, 1](fill=0)
    assert_equal(server.try_read(Span(received)), 1)
    assert_equal(received[0], Byte(99))

    client.close()
    server.close()
    listener.close()


def test_poller_write_readiness() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var listening = listener.local_address()
    var client = dial_tcp(String(listening), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))

    var poller = Poller()
    poller.add(server.raw_fd(), readable=False, writable=True)
    assert_equal(poller.wait(Timeout.nanoseconds(0)), 1)
    assert_true(poller.is_writable(0))
    assert_false(poller.is_readable(0))

    client.close()
    server.close()
    listener.close()


def test_poller_receives_udp_datagram() raises:
    var receiver = listen_udp("127.0.0.1:0")
    var bound = receiver.local_address()
    var sender = listen_udp("127.0.0.1:0")

    var payload: Array[Byte, 2] = [55, 56]
    assert_equal(sender.try_send_to(Span(payload), bound), 2)

    var poller = Poller()
    poller.add(receiver.raw_fd())
    assert_equal(poller.wait(Timeout.seconds(1)), 1)
    assert_true(poller.is_readable(0))

    var received = Array[Byte, 2](fill=0)
    var result = receiver.try_recv_from(Span(received))
    assert_equal(result.count, 2)
    assert_equal(received[0], Byte(55))
    assert_equal(received[1], Byte(56))

    sender.close()
    receiver.close()


def test_empty_poller_returns_zero_immediately() raises:
    var poller = Poller()
    assert_equal(len(poller), 0)
    assert_equal(poller.wait(), 0)
    assert_equal(poller.wait(Timeout.nanoseconds(0)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
