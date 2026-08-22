from std.time import perf_counter_ns

from net import IPAddress


def _address_checksum(address: IPAddress) -> UInt64:
    var checksum = UInt64(4 if address.is_ipv4() else 6)
    var bytes = address.as_bytes()
    for i in range(len(bytes)):
        checksum += UInt64(bytes[i])
    return checksum


def main() raises:
    comptime batch_iterations = 250_000
    comptime total_iterations = batch_iterations * 4
    var checksum = UInt64(0)
    var started = perf_counter_ns()
    for _ in range(batch_iterations):
        checksum += _address_checksum(IPAddress.parse("192.0.2.1"))
        checksum += _address_checksum(IPAddress.parse("203.0.113.254"))
        checksum += _address_checksum(IPAddress.parse("2001:db8::1"))
        checksum += _address_checksum(
            IPAddress.parse("2001:db8:85a3::8a2e:370:7334")
        )
    var elapsed = perf_counter_ns() - started
    if elapsed <= 0:
        raise Error("monotonic clock did not advance")
    var operations_per_second = (
        Float64(total_iterations) * 1_000_000_000.0 / Float64(elapsed)
    )
    print("total nanoseconds:", elapsed)
    print("operations per second:", operations_per_second)
    print("checksum:", checksum)
