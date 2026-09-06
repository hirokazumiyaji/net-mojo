"""Single-threaded readiness multiplexing over `poll(2)`.

`Poller` waits on any number of descriptors at once, so one thread can
serve many connections: register each socket's `raw_fd()`, call `wait`,
then use `try_read` / `try_write` / `try_accept` on the ready indices.
`poll(2)` scales linearly with the registration count; an epoll/kqueue
backend is a future optimization that keeps this API.
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


struct Poller(Movable, Sized):
    """Level-triggered readiness set built on `poll(2)`.

    Registrations are identified by index, so the same fd may appear
    more than once. The `Poller` borrows the descriptors: the owner
    must keep each socket alive until it is removed. Mojo destroys a
    move-only socket at its last use, so hold every registered socket
    in a live binding (or close it explicitly) for as long as its fd
    stays registered — an unreferenced socket may otherwise be closed
    while `wait` still watches its number, and a recycled number can
    then report readiness for the wrong socket.
    """

    var _entries: List[_PollFD]

    def __init__(out self):
        self._entries = List[_PollFD]()

    def __len__(self) -> Int:
        return len(self._entries)

    def add(mut self, fd: Int32, readable: Bool = True, writable: Bool = False):
        var interests: Int16 = 0
        if readable:
            interests |= POLLIN
        if writable:
            interests |= POLLOUT
        self._entries.append(_PollFD(fd=fd, events=interests, revents=0))

    def remove(mut self, index: Int):
        _ = self._entries.pop(index)

    def clear(mut self):
        self._entries.clear()

    def fd(self, index: Int) -> Int32:
        return self._entries[index].fd

    def is_readable(self, index: Int) -> Bool:
        return ((self._entries[index].events & POLLIN) != 0) and (
            (self._entries[index].revents & _READABLE_MASK) != 0
        )

    def is_writable(self, index: Int) -> Bool:
        return ((self._entries[index].events & POLLOUT) != 0) and (
            (self._entries[index].revents & _WRITABLE_MASK) != 0
        )

    def has_error(self, index: Int) -> Bool:
        return (self._entries[index].revents & (POLLERR | POLLNVAL)) != 0

    def wait(
        mut self, timeout: Optional[Timeout] = None
    ) raises NetError -> Int:
        """Waits until at least one registration is ready or the timeout
        expires, and returns how many registrations are ready.

        An empty `Poller` returns 0 immediately. A `None` timeout waits
        indefinitely; a zero timeout only reports what is already ready.
        """
        if len(self._entries) == 0:
            return 0
        var deadline = _Deadline.from_optional(timeout)
        _ = _poll_multiple(self._entries, deadline)
        var ready = 0
        for i in range(len(self._entries)):
            if self.is_readable(i) or self.is_writable(i):
                ready += 1
        return ready
