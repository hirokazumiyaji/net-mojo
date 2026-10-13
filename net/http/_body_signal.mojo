"""Fixed-address receiver notification with monotonic timeout semantics."""

from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.time import perf_counter_ns

from net._actor import PthreadMutex
from net.timeout import _Deadline


comptime _DARWIN = CompilationTarget.is_macos()
comptime _TIMED_OUT: Int32 = 60 if _DARWIN else 110


struct _BodyCondition(Movable):
    """Initialize only after relocation; native waiters retain this address."""

    var _storage: Array[UInt64, 6]

    def __init__(out self):
        self._storage = Array[UInt64, 6](fill=0)

    def initialize(mut self):
        var ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        comptime if _DARWIN:
            _ = external_call["pthread_cond_init", c_int](
                ptr, Optional[Pointer[Byte, MutUntrackedOrigin]](None)
            )
        else:
            var attributes: UInt64 = 0
            var attr_ptr = Pointer(to=attributes).unsafe_bitcast[Byte]()
            _ = external_call["pthread_condattr_init", c_int](attr_ptr)
            _ = external_call["pthread_condattr_setclock", c_int](
                attr_ptr, c_int(1)
            )
            _ = external_call["pthread_cond_init", c_int](ptr, attr_ptr)
            _ = external_call["pthread_condattr_destroy", c_int](attr_ptr)

    def destroy(mut self):
        _ = external_call["pthread_cond_destroy", c_int](
            Pointer(to=self._storage).unsafe_bitcast[Byte]()
        )

    def broadcast(mut self):
        _ = external_call["pthread_cond_broadcast", c_int](
            Pointer(to=self._storage).unsafe_bitcast[Byte]()
        )

    def wait(mut self, mut mutex: PthreadMutex, deadline: _Deadline) -> Int32:
        var cond_ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        var mutex_ptr = Pointer(to=mutex._storage).unsafe_bitcast[Byte]()
        if deadline.is_indefinite():
            return external_call["pthread_cond_wait", c_int](
                cond_ptr, mutex_ptr
            )
        var remaining = deadline._expires_at.value() - perf_counter_ns()
        if remaining <= 0:
            return _TIMED_OUT
        var time: Array[Int64, 2] = [
            Int64(remaining // 1_000_000_000),
            Int64(remaining % 1_000_000_000),
        ]
        comptime if _DARWIN:
            return external_call["pthread_cond_timedwait_relative_np", c_int](
                cond_ptr, mutex_ptr, Pointer(to=time).unsafe_bitcast[Int64]()
            )
        else:
            var now = Array[Int64, 2](fill=0)
            _ = external_call["clock_gettime", c_int](
                c_int(1), Pointer(to=now).unsafe_bitcast[Int64]()
            )
            time[0] += now[0]
            time[1] += now[1]
            if time[1] >= 1_000_000_000:
                time[0] += 1
                time[1] -= 1_000_000_000
            return external_call["pthread_cond_timedwait", c_int](
                cond_ptr, mutex_ptr, Pointer(to=time).unsafe_bitcast[Int64]()
            )
