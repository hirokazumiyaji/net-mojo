"""Absolute monotonic deadlines for the HTTP server loop.

Each phase converts its relative `Timeout` once, at phase entry, into an
absolute nanosecond timestamp. Receiving one more byte never extends a
deadline. `NO_DEADLINE` marks an inactive phase.
"""

from std.time import perf_counter_ns

from net import Timeout

comptime NO_DEADLINE: Int = Int.MAX


def now_ns() -> Int:
    return Int(perf_counter_ns())


def deadline_from_now(timeout: Timeout) -> Int:
    var delta = Int(timeout._value)
    var now = now_ns()
    if delta < 0 or now > Int.MAX - delta:
        return Int.MAX
    return now + delta
