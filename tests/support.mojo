from std.ffi import external_call, c_int, c_uint, c_ulong
from std.testing import assert_equal

from net._sys.common import F_GETFD, _fcntl


def _assert_bytes_equal[
    left_origin: MutOrigin, right_origin: ImmOrigin
](
    left: Span[mut=True, Byte, left_origin], right: Span[Byte, right_origin]
) raises:
    assert_equal(len(left), len(right))
    for i in range(len(left)):
        assert_equal(left[i], right[i])


comptime _SIGALRM: Int32 = 14


def _join_thread(handle: UInt64) raises:
    """Joins a helper thread spawned with `pthread_create`.

    Every test-spawned thread must be joined before the spawning
    function returns: the thread only touches stack memory that dies
    with the test's frame, so an unjoined thread would race the
    frame's destruction. All thread entries use bounded waits, so a
    join always terminates.
    """
    var rc = external_call["pthread_join", c_int](
        c_ulong(handle), Optional[Pointer[Byte, MutUntrackedOrigin]](None)
    )
    if Int(rc) != 0:
        raise Error("pthread_join failed")


def _noop_sigalrm_handler(sig: Int32):
    pass


def _arm_eintr_probe() raises:
    """Installs a no-op SIGALRM handler that lets blocking syscalls fail
    with EINTR instead of killing the process.

    `siginterrupt(..., 1)` disables SA_RESTART portably so the
    interruption is actually delivered as EINTR on both targets.
    Pair with `_disarm_alarm()` before the test ends.
    """
    _ = external_call["signal", c_int](c_int(_SIGALRM), _noop_sigalrm_handler)
    var intr = external_call["siginterrupt", c_int](c_int(_SIGALRM), c_int(1))
    if Int(intr) != 0:
        raise Error("siginterrupt failed")


def _sound_alarm(seconds: Int):
    _ = external_call["alarm", c_uint](c_uint(seconds))


def _disarm_alarm():
    _ = external_call["alarm", c_uint](c_uint(0))


def _count_open_fds() -> Int:
    """Counts open descriptors by probing 0..<getdtablesize with fcntl.

    Single-threaded use only. Used as a leak detector: count before
    and after repeated dial/close cycles with a warm-up in between.
    """
    var limit = Int(external_call["getdtablesize", c_int]())
    if limit < 0:
        return -1
    if limit > 65536:
        limit = 65536
    var count = 0
    for fd in range(limit):
        if _fcntl(c_int(fd), c_int(F_GETFD), c_int(0)) != -1:
            count += 1
    return count
