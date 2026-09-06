from net import Timeout, dial_tcp, listen_tcp


def main() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var ping: Array[Byte, 4] = [1, 2, 3, 4]
    client.write_all(Span(ping), Timeout.seconds(1))
    var received = Array[Byte, 4](fill=0)
    var count = server.read(Span(received), Timeout.seconds(1))
    if count != 4 or received[0] != 1 or received[3] != 4:
        raise Error("packaged artifact roundtrip mismatch")
    client.close()
    server.close()
    listener.close()
    print("packaged artifact roundtrip succeeded")
