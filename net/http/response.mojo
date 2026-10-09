"""Bounded buffered response writer for `net.http`.

The handler mutates the writer; the server sends after the handler
returns. The writer never touches the socket and never waits.
The connection owns the encoded bytes until the send completes, so
handler-local values must be copied in (which `write` does) instead
of borrowed into a send queue.

The synchronous HTTP/1 writer owns its body capacity in the shared budget;
standalone writers enforce their body length limit. Direct body edits are
reconciled separately and do not have the supported writes' growth guarantee.
HTTP/1 response Headers reserve known array/raw value growth and retained
capacity; direct public Headers replacement is admitted after allocation.
"""

from net.error import NetError, NetErrorKind

from ._detach import (
    ResponseSender,
    _cancel_detach_state,
    _create_detach_state,
)
from ._buffer import SharedBufferBudget, _reserve_capacity
from .headers import Headers, _trailer_forbidden


struct ResponseWriter(Movable, Sized):
    """Owned response under construction."""

    var status: Int
    var headers: Headers
    var trailers: Headers
    var body: List[Byte]
    var should_close: Bool
    var _limit: Int
    var _detached: Bool
    var _detach_state_addr: Int
    var _slot: Int
    var _generation: UInt64
    var _wakeup_fd: Int32
    var _queue_limit: Int
    var _body_budget: Optional[SharedBufferBudget]
    var _body_capacity_reserved: Int

    def __init__(
        out self,
        body_limit: Int,
        slot: Int = -1,
        generation: UInt64 = 0,
        wakeup_fd: Int32 = -1,
        queue_limit: Int = 1048576,
    ):
        self.status = 200
        self.headers = Headers()
        self.trailers = Headers()
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
        self._queue_limit = queue_limit
        self._body_budget = None
        self._body_capacity_reserved = 0

    def __init__(out self, *, deinit move: Self):
        self.status = move.status
        self.headers = move.headers^
        self.trailers = move.trailers^
        self.body = move.body^
        self.should_close = move.should_close
        self._limit = move._limit
        self._detached = move._detached
        self._detach_state_addr = move._detach_state_addr
        self._slot = move._slot
        self._generation = move._generation
        self._wakeup_fd = move._wakeup_fd
        self._queue_limit = move._queue_limit
        self._body_budget = move._body_budget^
        self._body_capacity_reserved = move._body_capacity_reserved

    def __deinit__(deinit self):
        self._drop_body()

    def _set_body_budget(mut self, var budget: SharedBufferBudget):
        _ = self.headers._adopt_capacity_budget(Optional(budget.copy()))
        _ = self.trailers._adopt_capacity_budget(Optional(budget.copy()))
        self._body_budget = budget^

    def _drop_headers(mut self):
        self.headers = Headers()
        self.trailers = Headers()

    def _reconcile_body_budget(mut self) -> Bool:
        var capacity = self.body.capacity()
        var difference = capacity - self._body_capacity_reserved
        if difference >= 0:
            if not self._body_budget.value().try_reserve(difference):
                return False
        else:
            self._body_budget.value().release(-difference)
        self._body_capacity_reserved = capacity
        return True

    def _drop_body(mut self):
        self.body = List[Byte]()
        if self._body_budget:
            self._body_budget.value().release(self._body_capacity_reserved)
        self._body_capacity_reserved = 0

    def is_detached(self) -> Bool:
        return self._detached

    def _cancel_detach(mut self):
        if self._detach_state_addr != 0:
            _cancel_detach_state(self._detach_state_addr)
            self._detach_state_addr = 0

    def set_detach_state(mut self, addr: Int):
        self._detach_state_addr = addr

    def detach(mut self) raises NetError -> ResponseSender:
        """Detaches the response from the synchronous handler flow.

        Returns a `ResponseSender` that can be transferred across threads to
        complete or stream the response asynchronously.
        Once detached, the handler must not write further data directly to `ResponseWriter`.
        """
        if self._detached:
            raise NetError(
                NetErrorKind.invalid_state(),
                "detach",
                None,
                "response already detached",
            )
        if self._detach_state_addr != 0:
            self._detached = True
            return ResponseSender(self._detach_state_addr)
        var addr = _create_detach_state(
            slot=self._slot,
            generation=self._generation,
            wakeup_fd=self._wakeup_fd,
            queue_limit=self._queue_limit,
            budget=self._body_budget.copy(),
        )
        self._detach_state_addr = addr
        self._detached = True
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
        if self._body_budget:
            var reservation = 0
            if not self._reconcile_body_budget() or not _reserve_capacity(
                self.body,
                self._body_budget.value(),
                len(self.body) + len(data),
                reservation,
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "write response body",
                    None,
                    "response body capacity exceeds budget",
                )
            self._body_capacity_reserved = self.body.capacity()
        else:
            self.body.reserve(len(self.body) + len(data))
        self.body.extend(data)

    def write_string(mut self, data: StringSlice) raises NetError:
        self.write(data.as_bytes())

    def add_trailer(
        mut self, var name: String, var value: String
    ) raises NetError:
        """Appends a response trailer after validating the name against
        the RFC 9110 §6.5.1 trailer deny-list; the underlying Headers
        store rejects CR/LF/NUL and non-token name bytes."""
        if _trailer_forbidden(name):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "add trailer",
                None,
                "trailer modifies framing, routing, or payload processing",
            )
        self.trailers.add(name^, value^)


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


def maybe_inject_alt_svc(
    mut writer: ResponseWriter, alt_svc: StringSlice
) raises:
    """Adds `Alt-Svc` when configured and the handler did not set it.

    Callers restrict this to HTTPS (TLS) responses. An empty `alt_svc`
    leaves the response unchanged so UDP-unavailable deployments can
    serve HTTPS without advertising HTTP/3.
    """
    if alt_svc.byte_length() == 0:
        return
    if writer.headers._first_lower_index("alt-svc") >= 0:
        return
    writer.headers.add(String("Alt-Svc"), String(alt_svc))
