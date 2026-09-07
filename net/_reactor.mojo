"""Single-threaded readiness layer with stable tokens (poll baseline).

`Reactor` is the internal successor to the public `Poller` for server
use: registrations return a stable `ReactorToken` (slot + generation)
instead of a shifting index, interests can be updated in place, and
`wait` returns only the ready batch. The poll backend scans every
registration per call; Phase 4 replaces the inside with epoll/kqueue
while keeping this token contract.

Ownership mirrors `Poller`: the reactor borrows descriptor numbers,
the socket owner keeps each registered socket alive until it is
removed. Drive from one thread only.
"""

from net._sys.common import (
    POLLERR,
    POLLHUP,
    POLLIN,
    POLLNVAL,
    POLLOUT,
    _PollFD,
    _poll_multiple,
)
from net.error import NetError
from net.timeout import Timeout, _Deadline


comptime _READABLE_MASK: Int16 = POLLIN | POLLERR | POLLHUP | POLLNVAL
comptime _WRITABLE_MASK: Int16 = POLLOUT | POLLERR | POLLHUP | POLLNVAL


@fieldwise_init
struct ReactorToken(Copyable, Equatable, Hashable, Writable):
    """Stable registration handle. A removed or replaced slot never
    matches an old token: `modify` and `remove` report `False` and
    `wait` never emits the old token again."""

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
    """Level-triggered readiness set over `poll(2)` with stable tokens.

    The poll scratch buffers live on the reactor and are reused every
    `wait` so the loop tick performs no per-call registrations-list
    allocation.
    """

    var _slots: List[_ReactorSlot]
    var _free: List[Int]
    var _active_count: Int
    var _next_generation: UInt64
    var _pollfds: List[_PollFD]
    var _poll_slots: List[Int]

    def __init__(out self):
        self._slots = List[_ReactorSlot]()
        self._free = List[Int]()
        self._active_count = 0
        # Generation 0 is reserved for never-issued tokens so a
        # default-constructed token never validates.
        self._next_generation = 1
        self._pollfds = List[_PollFD]()
        self._poll_slots = List[Int]()

    def __len__(self) -> Int:
        return self._active_count

    def is_empty(self) -> Bool:
        return self._active_count == 0

    def register(
        mut self, fd: Int32, readable: Bool = True, writable: Bool = False
    ) -> ReactorToken:
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
        return token^

    def contains(self, token: ReactorToken) -> Bool:
        if token.slot < 0 or token.slot >= len(self._slots):
            return False
        if not self._slots[token.slot].active:
            return False
        return self._slots[token.slot].generation == token.generation

    def modify(
        mut self, token: ReactorToken, readable: Bool, writable: Bool
    ) -> Bool:
        if not self.contains(token):
            return False
        self._slots[token.slot].readable = readable
        self._slots[token.slot].writable = writable
        return True

    def remove(mut self, token: ReactorToken) -> Bool:
        if not self.contains(token):
            return False
        self._slots[token.slot].active = False
        self._free.append(token.slot)
        self._active_count -= 1
        return True

    def clear(mut self):
        for i in range(len(self._slots)):
            self._slots[i].active = False
        self._free.clear()
        for i in range(len(self._slots)):
            self._free.append(len(self._slots) - 1 - i)
        self._active_count = 0

    def wait(
        mut self, timeout: Optional[Timeout] = None
    ) raises NetError -> List[ReactorEvent]:
        """Waits for readiness and returns only the ready batch.

        An empty reactor returns an empty list without a syscall. A
        `None` timeout waits indefinitely; a zero timeout reports what
        is already ready. Stale tokens never appear in the output.

        Terminal conditions (`POLLERR`, `POLLNVAL`, `POLLHUP`) are
        always reported. In addition, an observed `POLLIN` is always
        surfaced as readable even when `POLLIN` was not requested:
        `poll` cannot tell data from EOF without reading (macOS in
        particular reports an orderly peer shutdown as bare `POLLIN`,
        and reports nothing at all for an empty mask, hence the
        always-on `POLLIN` watch above). The event obliges the owner
        to drain via `try_*` until would-block or EOF and to remove
        the registration on EOF. Every delivered event therefore makes
        progress (bytes or EOF) and no hangup can trap the loop
        eventlessly; over-delivery on a level-triggered baseline is
        always safe. The interest flags keep their meaning as the
        delivery contract for the Phase 4 edge backends. `has_error`
        stays reserved for `POLLERR | POLLNVAL`; a pure hangup arrives
        as `readable` with `has_error == False`.
        """
        var out = List[ReactorEvent]()
        if self._active_count == 0:
            return out^
        self._pollfds.clear()
        self._poll_slots.clear()
        for i in range(len(self._slots)):
            if not self._slots[i].active:
                continue
            # POLLIN is always watched: several platforms only report an
            # orderly peer shutdown when it is in the mask (with an empty
            # mask, macOS reports nothing at all). Delivery still follows
            # the reporting rules below.
            var interests: Int16 = POLLIN
            if self._slots[i].writable:
                interests |= POLLOUT
            self._pollfds.append(
                _PollFD(fd=self._slots[i].fd, events=interests, revents=0)
            )
            self._poll_slots.append(i)
        var deadline = _Deadline.from_optional(timeout)
        var polled = _poll_multiple(self._pollfds, deadline)
        if polled == 0:
            return out^
        for i in range(len(self._pollfds)):
            # The mask always watches POLLIN (see above), so any
            # observed readiness bit here is worth reporting; terminal
            # bits ride along in the mask.
            var readable = (self._pollfds[i].revents & _READABLE_MASK) != 0
            var writable = ((self._pollfds[i].events & POLLOUT) != 0) and (
                (self._pollfds[i].revents & _WRITABLE_MASK) != 0
            )
            if not readable and not writable:
                continue
            var slot = self._poll_slots[i]
            out.append(
                ReactorEvent(
                    token=ReactorToken(
                        slot=slot,
                        generation=self._slots[slot].generation,
                    ),
                    fd=self._pollfds[i].fd,
                    readable=readable,
                    writable=writable,
                    has_error=(self._pollfds[i].revents & (POLLERR | POLLNVAL))
                    != 0,
                )
            )
        return out^
