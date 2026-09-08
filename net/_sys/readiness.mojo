"""OS event-queue bindings for the reactor (Phase 4).

Level-triggered production path: Linux `epoll`, macOS `kqueue`, chosen at
compile time. There is no runtime fallback. HTTP code must not call libc
directly — it goes through `Reactor`, which owns this queue.

Token transport: the kernel returns one `UInt64` per event (`epoll_data.u64`
/ `kevent.udata`). The reactor encodes `slot` and `generation` there, so a
recycled fd can never steer an old event at the wrong connection.
"""

from std.ffi import c_int, external_call, get_errno
from std.sys import CompilationTarget, align_of, size_of

import net._sys.darwin as darwin
import net._sys.linux as linux
from net._sys.common import EINTR, _OwnedFD, _system_error
from net.error import NetError
from net.timeout import _Deadline


comptime _IS_DARWIN = CompilationTarget.is_macos()
comptime _MAX_EVENTS: Int = 128


@fieldwise_init
struct _Timespec(Copyable, ImplicitlyCopyable, Movable):
    var tv_sec: Int64
    var tv_nsec: Int64


@fieldwise_init
struct _ReadyEvent(Copyable, ImplicitlyCopyable, Movable):
    var fd: Int32
    var readable: Bool
    var writable: Bool
    var has_error: Bool
    var eof: Bool
    var token_data: UInt64


def _encode_token(slot: Int, generation: UInt64) -> UInt64:
    return (UInt64(slot) << 32) | (generation & UInt64(0xFFFFFFFF))


def _decode_slot(token_data: UInt64) -> Int:
    return Int(token_data >> 32)


def _decode_gen_low(token_data: UInt64) -> UInt64:
    return token_data & UInt64(0xFFFFFFFF)


def _verify_readiness_abi():
    comptime assert size_of[_Timespec]() == 16, "invalid timespec ABI"
    comptime assert align_of[_Timespec]() == 8, "invalid timespec align"
    comptime if _IS_DARWIN:
        comptime assert size_of[darwin._Kevent]() == 32, "invalid kevent ABI"
        comptime assert align_of[darwin._Kevent]() == 8, "invalid kevent align"
    else:
        comptime assert (
            size_of[linux._EpollEvent]() == 16
        ), "invalid epoll_event ABI"
        comptime assert (
            align_of[linux._EpollEvent]() == 8
        ), "invalid epoll_event align"


def _epoll_mask(readable: Bool, writable: Bool) -> UInt32:
    var mask: UInt32 = 0
    # Fully disinterested slots still watch IN so a peer shutdown surfaces
    # instead of hiding behind silence (mirrors the poll baseline).
    if readable or not writable:
        mask |= linux.EPOLLIN
    if writable:
        mask |= linux.EPOLLOUT
    return mask


def _kqueue_wants_read(readable: Bool, writable: Bool) -> Bool:
    return readable or not writable


struct _EventQueue(Movable):
    var _fd: _OwnedFD
    # Raw scratch for the ready batch: 128 x 32B (kqueue) fits in 512 u64.
    # Linux needs 128 x 16B. Reused every wait, no per-wait allocation.
    var _scratch: List[UInt64]

    def __init__(out self) raises NetError:
        _verify_readiness_abi()
        var raw: Int32
        comptime if _IS_DARWIN:
            raw = external_call["kqueue", c_int]()
        else:
            raw = external_call["epoll_create1", c_int](
                c_int(linux.EPOLL_CLOEXEC)
            )
        if raw == -1:
            var errno = get_errno().value
            raise _system_error("event queue create", errno)
        self._fd = _OwnedFD(raw)
        self._scratch = List[UInt64]()
        for _ in range(512):
            self._scratch.append(0)

    def raw_fd(self) raises NetError -> Int32:
        return self._fd.raw()

    def register(
        mut self, fd: Int32, readable: Bool, writable: Bool, token: UInt64
    ) raises NetError:
        comptime if _IS_DARWIN:
            if _kqueue_wants_read(readable, writable):
                self._kevent_add(fd, darwin.EVFILT_READ, token)
            if writable:
                self._kevent_add(fd, darwin.EVFILT_WRITE, token)
        else:
            var event = linux._EpollEvent(
                events=_epoll_mask(readable, writable),
                _reserved=0,
                data=token,
            )
            var rc = external_call["epoll_ctl", c_int](
                c_int(self._fd.raw()),
                c_int(linux.EPOLL_CTL_ADD),
                c_int(fd),
                Pointer(to=event),
            )
            if rc == -1:
                var errno = get_errno().value
                raise _system_error("epoll_ctl add", errno)

    def modify(
        mut self, fd: Int32, readable: Bool, writable: Bool, token: UInt64
    ) raises NetError:
        comptime if _IS_DARWIN:
            # Drop both filters, re-add what is wanted. Modify is off the
            # hot path (interest flips only on queued sends).
            self._kevent_delete(fd, darwin.EVFILT_READ)
            self._kevent_delete(fd, darwin.EVFILT_WRITE)
            if _kqueue_wants_read(readable, writable):
                self._kevent_add(fd, darwin.EVFILT_READ, token)
            if writable:
                self._kevent_add(fd, darwin.EVFILT_WRITE, token)
        else:
            var event = linux._EpollEvent(
                events=_epoll_mask(readable, writable),
                _reserved=0,
                data=token,
            )
            var rc = external_call["epoll_ctl", c_int](
                c_int(self._fd.raw()),
                c_int(linux.EPOLL_CTL_MOD),
                c_int(fd),
                Pointer(to=event),
            )
            if rc == -1:
                var event2 = linux._EpollEvent(
                    events=_epoll_mask(readable, writable),
                    _reserved=0,
                    data=token,
                )
                var rc2 = external_call["epoll_ctl", c_int](
                    c_int(self._fd.raw()),
                    c_int(linux.EPOLL_CTL_ADD),
                    c_int(fd),
                    Pointer(to=event2),
                )
                if rc2 == -1:
                    var errno2 = get_errno().value
                    raise _system_error("epoll_ctl mod", errno2)

    def remove(mut self, fd: Int32):
        # Best-effort and idempotent: deleting a missing filter is fine.
        comptime if _IS_DARWIN:
            self._kevent_delete(fd, darwin.EVFILT_READ)
            self._kevent_delete(fd, darwin.EVFILT_WRITE)
        else:
            var event = linux._EpollEvent(events=0, _reserved=0, data=0)
            _ = external_call["epoll_ctl", c_int](
                c_int(self._fd._value),
                c_int(linux.EPOLL_CTL_DEL),
                c_int(fd),
                Pointer(to=event),
            )

    def wait(
        mut self, deadline: _Deadline
    ) raises NetError -> List[_ReadyEvent]:
        comptime if _IS_DARWIN:
            return self._wait_kqueue(deadline)
        else:
            return self._wait_epoll(deadline)

    def _wait_epoll(
        mut self, deadline: _Deadline
    ) raises NetError -> List[_ReadyEvent]:
        var out = List[_ReadyEvent]()
        var base = Pointer(to=self._scratch[0]).unsafe_bitcast[
            linux._EpollEvent
        ]()
        while True:
            var timeout = _epoll_timeout_ms(deadline)
            var rc = external_call["epoll_wait", c_int](
                c_int(self._fd._value),
                base,
                c_int(_MAX_EVENTS),
                c_int(timeout),
            )
            if rc == -1:
                var errno = get_errno().value
                if errno == EINTR:
                    if deadline.expired():
                        return out^
                    continue
                raise _system_error("epoll_wait", errno)
            if rc == 0:
                if deadline.expired():
                    return out^
                continue
            var count = Int(rc)
            for i in range(count):
                var ev = base[unsafe_offset=i]
                var readable = (ev.events & linux.EPOLLIN) != 0
                var writable = (ev.events & linux.EPOLLOUT) != 0
                var eof = (
                    ev.events
                    & (linux.EPOLLERR | linux.EPOLLHUP | linux.EPOLLRDHUP)
                ) != 0
                out.append(
                    _ReadyEvent(
                        fd=-1,
                        readable=readable,
                        writable=writable,
                        has_error=(ev.events & linux.EPOLLERR) != 0,
                        eof=eof,
                        token_data=ev.data,
                    )
                )
            return out^

    def _wait_kqueue(
        mut self, deadline: _Deadline
    ) raises NetError -> List[_ReadyEvent]:
        var out = List[_ReadyEvent]()
        # NOTE: all kevent calls in this module use raw (non-Optional)
        # pointers with dummy storage for logically-NULL slots. Optional
        # wrappers mis-lower through FFI and fail with EINVAL.
        var use_timeout = not deadline.is_indefinite()
        while True:
            var rc: Int32
            if use_timeout:
                # Refresh the remaining time across EINTR restarts.
                var remaining_ms = deadline.remaining_milliseconds()
                if remaining_ms < 0:
                    remaining_ms = 0
                var remaining_ns = remaining_ms * 1_000_000
                var spec = _Timespec(
                    tv_sec=Int64(remaining_ns // 1_000_000_000),
                    tv_nsec=Int64(remaining_ns % 1_000_000_000),
                )
                var dummy_change = darwin._Kevent(
                    ident=0, filter=0, flags=0, fflags=0, data=0, udata=0
                )
                rc = external_call["kevent", c_int](
                    c_int(self._fd._value),
                    Pointer(to=dummy_change),
                    c_int(0),
                    Pointer(to=self._scratch[0]).unsafe_bitcast[
                        darwin._Kevent
                    ](),
                    c_int(_MAX_EVENTS),
                    Pointer(to=spec),
                )
            else:
                var dummy_change = darwin._Kevent(
                    ident=0, filter=0, flags=0, fflags=0, data=0, udata=0
                )
                var day = _Timespec(tv_sec=86400, tv_nsec=0)
                rc = external_call["kevent", c_int](
                    c_int(self._fd._value),
                    Pointer(to=dummy_change),
                    c_int(0),
                    Pointer(to=self._scratch[0]).unsafe_bitcast[
                        darwin._Kevent
                    ](),
                    c_int(_MAX_EVENTS),
                    Pointer(to=day),
                )
            if rc == -1:
                var errno = get_errno().value
                if errno == EINTR:
                    if deadline.expired():
                        return out^
                    continue
                raise _system_error("kevent wait", errno)
            if rc == 0:
                if deadline.expired():
                    return out^
                continue
            var count = Int(rc)
            # Coalesce the two filters per token into one event.
            var base = Pointer(to=self._scratch[0]).unsafe_bitcast[
                darwin._Kevent
            ]()
            var seen_token = List[UInt64]()
            var seen_fd = List[Int32]()
            var seen_read = List[Bool]()
            var seen_write = List[Bool]()
            var seen_err = List[Bool]()
            var seen_eof = List[Bool]()
            for i in range(count):
                var kev = base[unsafe_offset=i]
                var fd = Int32(kev.ident & UInt64(0xFFFFFFFF))
                var is_read = kev.filter == darwin.EVFILT_READ
                var is_write = kev.filter == darwin.EVFILT_WRITE
                var eof = (kev.flags & darwin.EV_EOF) != 0
                var err = (kev.flags & darwin.EV_ERROR) != 0
                var idx = -1
                for j in range(len(seen_token)):
                    if seen_token[j] == kev.udata:
                        idx = j
                        break
                if idx < 0:
                    seen_token.append(kev.udata)
                    seen_fd.append(fd)
                    seen_read.append(False)
                    seen_write.append(False)
                    seen_err.append(False)
                    seen_eof.append(False)
                    idx = len(seen_token) - 1
                if is_read:
                    seen_read[idx] = True
                if is_write:
                    seen_write[idx] = True
                if eof or err:
                    seen_eof[idx] = True
                if err:
                    seen_err[idx] = True
            for j in range(len(seen_token)):
                out.append(
                    _ReadyEvent(
                        fd=seen_fd[j],
                        readable=seen_read[j],
                        writable=seen_write[j],
                        has_error=seen_err[j],
                        eof=seen_eof[j],
                        token_data=seen_token[j],
                    )
                )
            return out^

    def _kevent_add(
        mut self, fd: Int32, filter: Int16, token: UInt64
    ) raises NetError:
        var change = darwin._Kevent(
            ident=UInt64(Int(fd)),
            filter=filter,
            flags=darwin.EV_ADD | darwin.EV_ENABLE,
            fflags=0,
            data=0,
            udata=token,
        )
        var dummy_ev = darwin._Kevent(
            ident=0, filter=0, flags=0, fflags=0, data=0, udata=0
        )
        var dummy_ts = _Timespec(tv_sec=0, tv_nsec=0)
        var rc = external_call["kevent", c_int](
            c_int(self._fd.raw()),
            Pointer(to=change),
            c_int(1),
            Pointer(to=dummy_ev),
            c_int(0),
            Pointer(to=dummy_ts),
        )
        if rc == -1:
            var errno = get_errno().value
            raise _system_error("kevent add", errno)

    def _kevent_delete(mut self, fd: Int32, filter: Int16):
        var change = darwin._Kevent(
            ident=UInt64(Int(fd)),
            filter=filter,
            flags=darwin.EV_DELETE,
            fflags=0,
            data=0,
            udata=0,
        )
        var dummy_ev = darwin._Kevent(
            ident=0, filter=0, flags=0, fflags=0, data=0, udata=0
        )
        var dummy_ts = _Timespec(tv_sec=0, tv_nsec=0)
        _ = external_call["kevent", c_int](
            c_int(self._fd._value),
            Pointer(to=change),
            c_int(1),
            Pointer(to=dummy_ev),
            c_int(0),
            Pointer(to=dummy_ts),
        )


def _epoll_timeout_ms(deadline: _Deadline) -> Int32:
    if deadline.is_indefinite():
        return -1
    var remaining = deadline.remaining_milliseconds()
    if remaining < 0:
        return 0
    if remaining > Int(Int32.MAX):
        return Int32.MAX
    return Int32(remaining)
