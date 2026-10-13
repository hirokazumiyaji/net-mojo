"""Reusable actor and message-passing primitives for `net`.

This module provides concurrency and message-passing building blocks:
- `PthreadMutex`: Thin wrapper around POSIX `pthread_mutex_t` covering
  Darwin (64 bytes) and 64-bit Linux (40 bytes) with 8-byte alignment.
- `WakeupChannel`: Non-blocking inter-thread signaling using a `socketpair`.
  The read side registers with `Reactor` or `Poller`, and the write side
  signals with a 1-byte write to wake event-loop waiters immediately.
- `Mailbox[T]`: Thread-safe FIFO message queue guarded by a mutex, supporting
  individual `push`, batch `pop_all`, and cancellation/closing.
"""

from std.ffi import c_int, c_size_t, c_ssize_t, external_call, get_errno
from std.sys import CompilationTarget
from std.time import perf_counter_ns
from net.timeout import _Deadline

from net._sys.common import (
    AF_UNIX,
    EINTR,
    SOCK_STREAM,
    _close,
    _set_nonblocking_cloexec,
    _OwnedFD,
)
from net.error import NetError, NetErrorKind


comptime _IS_DARWIN = CompilationTarget.is_macos()
comptime _COND_TIMED_OUT: Int32 = 60 if _IS_DARWIN else 110


# Darwin: sizeof(pthread_mutex_t) = 64, align = 8.
# Linux:  sizeof(pthread_mutex_t) = 40 (glibc), align = 8.
# 64 bytes (8 x UInt64) safely covers both targets with 8-byte alignment.
@fieldwise_init
struct PthreadMutex(Movable):
    var _storage: Array[UInt64, 8]

    def __init__(out self):
        self._storage = Array[UInt64, 8](fill=0)
        self._initialize()

    @staticmethod
    def _uninitialized() -> Self:
        """Delay native initialization until storage reaches its final address.
        """
        return Self(_storage=Array[UInt64, 8](fill=0))

    def _initialize(mut self):
        var ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        _ = external_call["pthread_mutex_init", c_int](
            ptr, Optional[Pointer[Byte, MutUntrackedOrigin]](None)
        )

    def lock(mut self):
        var ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        _ = external_call["pthread_mutex_lock", c_int](ptr)

    def unlock(mut self):
        var ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        _ = external_call["pthread_mutex_unlock", c_int](ptr)

    def destroy(mut self):
        var ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        _ = external_call["pthread_mutex_destroy", c_int](ptr)


struct PthreadCond(Movable):
    """Initialize only after relocation; native waiters retain this address."""

    var _storage: Array[UInt64, 6]

    def __init__(out self):
        self._storage = Array[UInt64, 6](fill=0)

    def initialize(mut self):
        var ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        comptime if _IS_DARWIN:
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

    def wait(
        mut self, mut mutex: PthreadMutex, deadline: _Deadline = _Deadline(None)
    ) -> Int32:
        var cond_ptr = Pointer(to=self._storage).unsafe_bitcast[Byte]()
        var mutex_ptr = Pointer(to=mutex._storage).unsafe_bitcast[Byte]()
        if deadline.is_indefinite():
            return external_call["pthread_cond_wait", c_int](
                cond_ptr, mutex_ptr
            )
        var remaining = deadline._expires_at.value() - perf_counter_ns()
        if remaining <= 0:
            return _COND_TIMED_OUT
        var time: Array[Int64, 2] = [
            Int64(remaining // 1_000_000_000),
            Int64(remaining % 1_000_000_000),
        ]
        comptime if _IS_DARWIN:
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


def signal_wakeup_fd(wakeup_fd: Int32):
    """Writes a 1-byte notification to a non-blocking descriptor.

    Used by message senders to wake up event-loop pollers.
    """
    if wakeup_fd < 0:
        return
    var b: Byte = 1
    while True:
        var rc = external_call["send", c_ssize_t](
            c_int(wakeup_fd),
            Pointer(to=b).unsafe_bitcast[Byte](),
            c_size_t(1),
            c_int(0),
        )
        if rc >= 0:
            break
        var errno = get_errno().value
        if errno == EINTR:
            continue
        break


struct WakeupChannel(Movable):
    """Non-blocking socketpair channel for waking up event-loop waiters."""

    var _read_fd: _OwnedFD
    var _write_fd: _OwnedFD

    def __init__(out self) raises NetError:
        var raw = SIMD[DType.int32, 2](0)
        var result = external_call["socketpair", c_int](
            c_int(AF_UNIX),
            c_int(SOCK_STREAM),
            c_int(0),
            Pointer(to=raw).unsafe_bitcast[c_int](),
        )
        if result != 0:
            var errno = get_errno().value
            raise NetError(
                NetErrorKind.system_error(),
                "socketpair",
                Int(errno),
                "failed to create wakeup socketpair",
            )
        self._read_fd = _OwnedFD(raw[0])
        self._write_fd = _OwnedFD(raw[1])
        _set_nonblocking_cloexec(self._read_fd.raw())
        _set_nonblocking_cloexec(self._write_fd.raw())

    def read_fd(self) raises NetError -> Int32:
        return self._read_fd.raw()

    def write_fd(self) raises NetError -> Int32:
        return self._write_fd.raw()

    def signal(self):
        signal_wakeup_fd(self._write_fd._value)

    def drain(mut self):
        """Drains any queued notification bytes from the read side."""
        var buf = Array[Byte, 64](fill=0)
        var fd = self._read_fd._value
        if fd < 0:
            return
        while True:
            var rc = external_call["recv", c_ssize_t](
                c_int(fd),
                Pointer(to=buf).unsafe_bitcast[Byte](),
                c_size_t(64),
                c_int(0),
            )
            if rc <= 0:
                var errno = get_errno().value
                if rc < 0 and errno == EINTR:
                    continue
                break


struct Mailbox[T: Movable & Deinitable](Movable):
    """Thread-safe FIFO message queue protected by a POSIX mutex."""

    var _mutex: PthreadMutex
    var _items: List[Self.T]
    var _closed: Bool

    def __init__(out self):
        self._mutex = PthreadMutex()
        self._items = List[Self.T]()
        self._closed = False

    def push(mut self, var item: Self.T) -> Bool:
        """Pushes an item to the mailbox. Returns False if the mailbox is closed.
        """
        self._mutex.lock()
        if self._closed:
            self._mutex.unlock()
            return False
        self._items.append(item^)
        self._mutex.unlock()
        return True

    def pop_all(mut self) -> List[Self.T]:
        """Pops and returns all pending items as a batch."""
        self._mutex.lock()
        var out = List[Self.T]()
        while len(self._items) > 0:
            out.append(self._items.pop(0))
        self._mutex.unlock()
        return out^

    def close(mut self):
        """Marks the mailbox closed. Subsequent `push` calls will return False.
        """
        self._mutex.lock()
        self._closed = True
        self._mutex.unlock()

    def is_closed(mut self) -> Bool:
        self._mutex.lock()
        var c = self._closed
        self._mutex.unlock()
        return c

    def count(mut self) -> Int:
        self._mutex.lock()
        var n = len(self._items)
        self._mutex.unlock()
        return n
