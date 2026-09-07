"""Single event-loop server skeleton. The I/O loop lands in Phase 3.

Ownership rules fixed here:

- `Server.serve` takes listener ownership and runs until shutdown or
  a fatal error. Connections are owned by the internal table, never
  shared across threads.
- `ServerControl.request_shutdown` only passes a shutdown request
  across threads. A wakeup fd wakes the loop; the loop owner performs
  every socket operation. The handle outlives the server, is
  idempotent, and does nothing once the server has exited.
- Handler execution itself cannot be preempted: shutdown waits for
  the running handler to return, subject to the grace deadline.
"""

from net import TCPListener

from .config import ServerConfig
from .handler import Handler


struct ServerControl(Movable):
    """Thread-safe shutdown handle. Only the request crosses threads."""

    var _requested: Bool
    var _exited: Bool

    def __init__(out self):
        self._requested = False
        self._exited = False

    def request_shutdown(mut self):
        """Idempotent shutdown request. Safe to call twice and safe to
        call after the server has exited (then it is a no-op)."""
        if self._exited:
            return
        self._requested = True

    def is_shutdown_requested(self) -> Bool:
        return self._requested

    def mark_exited(mut self):
        self._requested = True
        self._exited = True


struct Server(Movable):
    var config: ServerConfig
    var control: ServerControl

    def __init__(out self, var config: ServerConfig):
        self.config = config^
        self.control = ServerControl()

    def is_shutdown_requested(self) -> Bool:
        return self.control.is_shutdown_requested()

    def request_shutdown(mut self):
        self.control.request_shutdown()

    def serve[
        H: Handler
    ](mut self, var listener: TCPListener, mut handler: H) raises:
        """Runs the event loop until shutdown. Phase 0 fixes the
        signature; the loop implementation lands in Phase 3."""
        _ = listener
        _ = handler
        raise Error("net.http Server.serve is not implemented yet")


def listen_and_serve[
    H: Handler
](address: StringSlice, var config: ServerConfig, mut handler: H) raises:
    """Binds `address` and serves. Convenience wrapper fixed here,
    implemented with the Phase 3 loop."""
    _ = address
    _ = config
    _ = handler
    raise Error("net.http listen_and_serve is not implemented yet")
