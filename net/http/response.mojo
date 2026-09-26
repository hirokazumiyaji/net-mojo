"""Bounded buffered response writer for `net.http`.

The handler mutates the writer; the server sends after the handler
returns. The writer never touches the socket and never waits.
The connection owns the encoded bytes until the send completes, so
handler-local values must be copied in (which `write` does) instead
of borrowed into a send queue.
"""

from net.error import NetError, NetErrorKind

from ._detach import ResponseSender, _create_detach_state
from .headers import Headers


struct ResponseWriter(Movable, Sized):
    """Owned response under construction."""

    var status: Int
    var headers: Headers
    var body: List[Byte]
    var should_close: Bool
    var _limit: Int
    var _detached: Bool
    var _detach_state_addr: Int
    var _slot: Int
    var _generation: UInt64
    var _wakeup_fd: Int32

    def __init__(
        out self,
        body_limit: Int,
        slot: Int = -1,
        generation: UInt64 = 0,
        wakeup_fd: Int32 = -1,
    ):
        self.status = 200
        self.headers = Headers()
        self.body = List[Byte]()
        self.should_close = False
        self._limit = body_limit
        self._detached = False
        self._detach_state_addr = 0
        self._slot = slot
        self._generation = generation
        # Note on _wakeup_fd: raw descriptor borrowed from Server._wakeup_channel.
        # The channel owns descriptor lifecycle; DetachState.cancelled guards
        # against late signaling if Server deinitializes.
        self._wakeup_fd = wakeup_fd

    def __init__(out self, *, deinit move: Self):
        self.status = move.status
        self.headers = move.headers^
        self.body = move.body^
        self.should_close = move.should_close
        self._limit = move._limit
        self._detached = move._detached
        self._detach_state_addr = move._detach_state_addr
        self._slot = move._slot
        self._generation = move._generation
        self._wakeup_fd = move._wakeup_fd

    def is_detached(self) -> Bool:
        return self._detached

    def set_detach_state(mut self, addr: Int):
        self._detach_state_addr = addr

    def detach(mut self) raises NetError -> ResponseSender:
        """Detaches the response from the synchronous handler flow.

        Returns a `ResponseSender` that can be transferred across threads to
        complete the response asynchronously (response streaming is planned for Phase C).
        Once detached, the handler must not write further data directly to `ResponseWriter`.
        """
        if self._detached:
            raise NetError(
                NetErrorKind.invalid_state(),
                "detach",
                None,
                "response already detached",
            )
        self._detached = True
        if self._detach_state_addr != 0:
            return ResponseSender(self._detach_state_addr)
        var addr = _create_detach_state(
            slot=self._slot,
            generation=self._generation,
            wakeup_fd=self._wakeup_fd,
        )
        self._detach_state_addr = addr
        return ResponseSender(addr)

    def __len__(self) -> Int:
        return len(self.body)

    def set_status(mut self, status: Int):
        self.status = status

    def set_should_close(mut self, should_close: Bool):
        self.should_close = should_close

    def body_limit(self) -> Int:
        return self._limit

    def write[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError:
        if len(self.body) + len(data) > self._limit:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "write response body",
                None,
                "response body exceeds limit",
            )
        self.body.reserve(len(self.body) + len(data))
        for i in range(len(data)):
            self.body.append(data[i])

    def write_string(mut self, data: StringSlice) raises NetError:
        var bytes = data.as_bytes()
        if len(self.body) + len(bytes) > self._limit:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "write response body",
                None,
                "response body exceeds limit",
            )
        self.body.reserve(len(self.body) + len(bytes))
        for i in range(len(bytes)):
            self.body.append(bytes[i])


def has_body_for_status(status: Int, is_head: Bool) -> Bool:
    """Reports whether the encoder must frame a response body.

    HEAD never frames a body, and 1xx / 204 / 205 / 304 never do either,
    regardless of any buffered bytes (RFC 9110: none of them allow
    content).
    """
    if is_head:
        return False
    if status >= 100 and status <= 199:
        return False
    if status == 204 or status == 205 or status == 304:
        return False
    return True
