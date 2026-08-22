from std.time import perf_counter_ns

from net import Timeout, listen_udp


def main() raises:
    comptime datagram_size = 1_400
    comptime target_bytes = 64 * 1_024 * 1_024
    var receiver = listen_udp("127.0.0.1:0")
    var sender = listen_udp("127.0.0.1:0")
    var destination = receiver.local_address()
    var payload = Array[Byte, datagram_size](fill=0)
    for i in range(len(payload)):
        payload[i] = Byte(i % 251)
    var buffer = Array[Byte, datagram_size](fill=0)
    var transferred = 0
    var checksum = UInt64(0)
    var started = perf_counter_ns()

    while transferred < target_bytes:
        var sent = sender.send_to(
            Span(payload), destination, Timeout.seconds(5)
        )
        if sent != datagram_size:
            raise Error("UDP send did not transfer one complete datagram")
        var received = receiver.recv_from(Span(buffer), Timeout.seconds(5))
        if received.count != datagram_size or received.truncated:
            raise Error("UDP receive did not preserve the datagram")
        checksum += UInt64(buffer[received.count - 1])
        transferred += received.count

    var elapsed = perf_counter_ns() - started
    sender.close()
    receiver.close()
    if elapsed <= 0:
        raise Error("monotonic clock did not advance")
    var bytes_per_second = (
        Float64(transferred) * 1_000_000_000.0 / Float64(elapsed)
    )
    print("transferred bytes:", transferred)
    print("bytes per second:", bytes_per_second)
    print("checksum:", checksum)
