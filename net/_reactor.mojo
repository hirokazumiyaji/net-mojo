"""Single-threaded readiness layer with stable tokens (epoll/kqueue).

`Reactor` is the internal successor to the public `Poller` for server use:
registrations return a stable `ReactorToken` (slot + generation) instead of
a shifting index, interests can be updated in place, and `wait` returns only
the ready batch. The backend is Linux `epoll` or macOS `kqueue` (compile-time
choice, level-triggered); there is no poll fallback in production.

Ownership mirrors `Poller`: the reactor borrows descriptor numbers, the
socket owner keeps each registered socket alive until it is removed. Drive
from one thread only.
"""

from net._sys.readiness import (
    _decode_gen_low,
    _decode_slot,
    _encode_token,
    _EventQueue,
)
from net.error import NetError
from net.timeout import Timeout, _Deadline


@fieldwise_init
struct ReactorToken(Copyable, Equatable, Hashable, Writable):
    """Stable registration handle. A removed or replaced slot never matches
    an old token: `modify` and `remove` report `False` and `wait` never emits
    the old token again."""

    var slot: Int
    var generation: UInt64

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.slot)
        writer.write(":")
        writer.write(self.generation)


@fieldwise_init
struct ReactorEvent(Copyable, Movable):
    var token: ReactorToken
    var fd: Int32
    var readable: Bool
    var writable: Bool
    var has_error: Bool


struct _ReactorSlot(Copyable, Movable):
    var fd: Int32
    var readable: Bool
    var writable: Bool
    var generation: UInt64
    var active: Bool

    def __init__(out self):
        self.fd = -1
        self.readable = True
        self.writable = False
        self.generation = 0
        self.active = False


struct Reactor(Movable, Sized):
    """Level-triggered readiness set over epoll/kqueue with stable tokens.

    `wait` returns only the ready batch: unlike the old poll baseline it
    never builds a kernel set proportional to the registration count, so
    thousands of idle connections cost no per-tick scan.
    """

    var _slots: List[_ReactorSlot]
    var _free: List[Int]
    var _active_count: Int
    var _next_generation: UInt64
    var _queue: _EventQueue

    def __init__(out self) raises NetError:
        self._slots = List[_ReactorSlot]()
        self._free = List[Int]()
        self._active_count = 0
        # Generation 0 is reserved for never-issued tokens so a
        # default-constructed token never validates.
        self._next_generation = 1
        self._queue = _EventQueue()

    def __len__(self) -> Int:
        return self._active_count

    def is_empty(self) -> Bool:
        return self._active_count == 0

    def register(
        mut self, fd: Int32, readable: Bool = True, writable: Bool = False
    ) raises NetError -> ReactorToken:
        var slot: Int
        if len(self._free) > 0:
            slot = self._free.pop()
            self._slots[slot].fd = fd
            self._slots[slot].readable = readable
            self._slots[slot].writable = writable
            self._slots[slot].generation = self._next_generation
            self._slots[slot].active = True
        else:
            slot = len(self._slots)
            var entry = _ReactorSlot()
            entry.fd = fd
            entry.readable = readable
            entry.writable = writable
            entry.generation = self._next_generation
            entry.active = True
            self._slots.append(entry^)
        var token = ReactorToken(slot=slot, generation=self._next_generation)
        self._next_generation += 1
        # Generation must never wrap to 0 (reserved).
        if self._next_generation == 0:
            self._next_generation = 1
        self._active_count += 1
        var wire = _encode_token(slot, token.generation)
        try:
            self._queue.register(fd, readable, writable, wire)
        except e:
            # Roll back the slot so a failed registration never validates.
            self._slots[slot].active = False
            self._free.append(slot)
            self._active_count -= 1
            raise e^
        return token^

    def contains(self, token: ReactorToken) -> Bool:
        if token.slot < 0 or token.slot >= len(self._slots):
            return False
        if not self._slots[token.slot].active:
            return False
        return self._slots[token.slot].generation == token.generation

    def modify(
        mut self, token: ReactorToken, readable: Bool, writable: Bool
    ) raises NetError -> Bool:
        if not self.contains(token):
            return False
        self._slots[token.slot].readable = readable
        self._slots[token.slot].writable = writable
        var wire = _encode_token(token.slot, token.generation)
        self._queue.modify(self._slots[token.slot].fd, readable, writable, wire)
        return True

    def remove(mut self, token: ReactorToken) -> Bool:
        if not self.contains(token):
            return False
        var fd = self._slots[token.slot].fd
        self._queue.remove(fd)
        self._slots[token.slot].active = False
        self._free.append(token.slot)
        self._active_count -= 1
        return True

    def wait(
        mut self, timeout: Optional[Timeout] = None
    ) raises NetError -> List[ReactorEvent]:
        """Waits for readiness and returns only the ready batch.

        An empty reactor returns an empty list without a syscall. A `None`
        timeout waits indefinitely; a zero timeout reports what is already
        ready. Stale tokens never appear in the output.

        Terminal conditions (hangup/error) are always reported. An observed
        readability is surfaced as readable when it was requested, or —
        regardless of interests — when the registration asked for nothing
        at all: the queue cannot tell data from EOF without reading (macOS
        in particular reports an orderly peer shutdown as readable, and an
        empty watch would report nothing at all, hence the forced read watch
        for disinterested slots in the queue). A deliberately paused
        direction stays quiet — ordinary readability on a
        `readable == False, writable == True` registration is neither
        watched nor reported — so disabling reads reliably suppresses work
        (e.g. backpressure) instead of spinning on suppressed wakeups, while
        a fully disinterested slot can still learn that its peer went away.
        Any surfaced hangup obliges the owner to drain via `try_*` until
        would-block or EOF and to remove the registration on EOF, so no
        hangup can trap the loop eventlessly. `has_error` stays reserved for
        kernel errors; a pure hangup arrives as `readable` with
        `has_error == False`.
        """
        var out = List[ReactorEvent]()
        if self._active_count == 0:
            return out^
        var deadline = _Deadline.from_optional(timeout)
        var batch = self._queue.wait(deadline)
        for i in range(len(batch)):
            var slot = _decode_slot(batch[i].token_data)
            if slot < 0 or slot >= len(self._slots):
                continue
            if not self._slots[slot].active:
                continue
            # The wire carries the low 32 bits of the generation; 2**32
            # reuses of one slot would be needed to collide.
            if _decode_gen_low(self._slots[slot].generation) != _decode_gen_low(
                batch[i].token_data
            ):
                continue
            var want_read = self._slots[slot].readable
            var want_write = self._slots[slot].writable
            var no_interests = (not want_read) and (not want_write)
            var readable = False
            if want_read and batch[i].readable:
                readable = True
            if batch[i].eof:
                # Terminal hangup/error wakes even a write-only waiter.
                readable = True
            if no_interests and batch[i].readable:
                readable = True
            var writable = want_write and batch[i].writable
            if want_write and batch[i].eof:
                writable = True
            if not readable and not writable:
                continue
            # On Linux the queue cannot report the fd; recover it from the
            # slot. On Darwin the kernel ident must agree with the slot.
            var fd = self._slots[slot].fd
            if batch[i].fd >= 0 and batch[i].fd != fd:
                continue
            out.append(
                ReactorEvent(
                    token=ReactorToken(
                        slot=slot,
                        generation=self._slots[slot].generation,
                    ),
                    fd=fd,
                    readable=readable,
                    writable=writable,
                    has_error=batch[i].has_error,
                )
            )
        return out^
