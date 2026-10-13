from std.testing import assert_equal, assert_true

from net import Timeout, listen_tcp
from net.http import HijackedConn
from net.http.switch import _wait_tls
from net.timeout import _Deadline
from net.tls import TLSContext


def main() raises:
    var listener = listen_tcp("127.0.0.1:0")
    print("READY", listener.local_address().port)
    var accepted = listener.accept(Timeout.seconds(5))
    var context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )
    var tls = context.accept(accepted^)
    var deadline = _Deadline.from_timeout(Timeout.seconds(5))
    while True:
        var progress = tls.handshake()
        if progress.is_complete():
            break
        _wait_tls(tls.raw_fd(), progress, deadline, "fixture handshake")
    var scratch = List[Byte](length=8192, fill=0)
    var pending = tls.try_read(Span(scratch))
    assert_true(pending.progress.is_wants_read())
    var connection = HijackedConn(tls^, List[Byte](), scratch^, 8192)
    assert_true(connection.is_tls())
    assert_equal(connection.local_address().port, listener.local_address().port)
    assert_true(connection.remote_address().port != 0)
    connection.set_no_delay(True)
    print("TLS_PENDING")
    var first = Array[Byte, 1](fill=0)
    assert_equal(connection.read(Span(first), Timeout.seconds(5)), 1)
    assert_equal(first[0], Byte(ord("h")))
    var rest = connection.take_buffered()
    assert_equal(len(rest), 9)
    assert_equal(connection.write(Span(first), Timeout.seconds(5)), 1)
    var offset = 0
    while offset < len(rest):
        offset += connection.write(Span(rest)[offset:], Timeout.seconds(5))
    connection.shutdown_write()
    connection^.close()
    print("DONE")
