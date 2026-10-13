from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net import Timeout, dial_tcp, listen_tcp
from net.http.switch import HijackedConn
from tests.support import _assert_bytes_equal, _to_bytes


def test_raw_connection_keeps_owned_buffer_before_socket_bytes() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var address = listener.local_address()
    var client = dial_tcp(String(address))
    var accepted = listener.accept(Timeout.seconds(1))
    var buffered = _to_bytes("first")
    var connection = HijackedConn(accepted^, buffered^)
    assert_false(connection.is_tls())
    assert_equal(connection.local_address(), address)
    assert_equal(connection.remote_address(), client.local_address())
    assert_true(connection.raw_fd() >= 0)
    connection.set_no_delay(True)
    _assert_bytes_equal(connection.buffered(), String("first").as_bytes())
    client.write_all(String("later").as_bytes())
    var piece = Array[Byte, 2](fill=0)
    assert_equal(connection.try_read(Span(piece)), 2)
    _assert_bytes_equal(Span(piece), String("fi").as_bytes())
    var remainder = connection.take_buffered()
    _assert_bytes_equal(Span(remainder), String("rst").as_bytes())
    assert_equal(len(connection.buffered()), 0)
    var incoming = Array[Byte, 5](fill=0)
    assert_equal(connection.read(Span(incoming), Timeout.seconds(1)), 5)
    _assert_bytes_equal(Span(incoming), String("later").as_bytes())
    assert_equal(
        connection.write(String("reply").as_bytes(), Timeout.seconds(1)), 5
    )
    assert_equal(client.read(Span(incoming), Timeout.seconds(1)), 5)
    _assert_bytes_equal(Span(incoming), String("reply").as_bytes())
    connection.shutdown_write()
    assert_equal(client.read(Span(incoming), Timeout.seconds(1)), 0)
    client.write_all(String("after").as_bytes())
    assert_equal(connection.read(Span(incoming), Timeout.seconds(1)), 5)
    connection^.close()


def test_raw_connection_move_and_would_block_preserve_ownership() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()))
    var accepted = listener.accept(Timeout.seconds(1))
    var connection = HijackedConn(accepted^, List[Byte]())
    var moved = connection^
    var buffer = Array[Byte, 1](fill=0)
    var timed_out = False
    try:
        _ = moved.try_read(Span(buffer))
    except error:
        timed_out = error.is_timeout()
    assert_true(timed_out)
    timed_out = False
    try:
        _ = moved.read(Span(buffer), Timeout.milliseconds(1))
    except error:
        timed_out = error.is_timeout()
    assert_true(timed_out)
    assert_equal(moved.try_write(String("x").as_bytes()), 1)
    assert_equal(client.read(Span(buffer), Timeout.seconds(1)), 1)
    moved^.close()
    assert_equal(client.read(Span(buffer), Timeout.seconds(1)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
