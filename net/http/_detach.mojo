"""Actor-style message passing and shared state for detached HTTP responses.

This module provides the thread-safe primitives for detaching an HTTP response
from the synchronous handler on the event loop, enabling deferred responses
and response streaming from another thread (e.g. GPU inference or worker threads).

Architecture (Erlang-inspired Actor / Message-Passing):
- The connection actor on the event loop remains the exclusive owner of the socket
  and reactor interests.
- `ResponseSender` acts as a movable actor endpoint / proxy.
- A copied budget capability charges state allocation until its last reference frees
  it, and message arrays/bodies through queue/batch ownership. Headers remain separate.
- Data messages use a mutex-protected mailbox; ordered finish/abort state requires
  no additional message allocation.
- A non-blocking wakeup file descriptor (via `socketpair`) notifies the reactor
  to awaken the event loop without polling latency.
- Generation checks guard against stale writes if a connection is closed and
  its slot / descriptor is recycled.
"""

from std.ffi import c_int, c_size_t, external_call, get_errno
from std.sys import size_of

from net._actor import PthreadMutex, signal_wakeup_fd
from net.error import NetError, NetErrorKind
from net.http._buffer import SharedBufferBudget, _reserve_capacity
from net.http.headers import Headers


comptime MSG_KIND_NONE: UInt8 = 0
comptime MSG_KIND_RESPOND: UInt8 = 1
comptime MSG_KIND_START: UInt8 = 2
comptime MSG_KIND_CHUNK: UInt8 = 3
comptime MSG_KIND_FINISH: UInt8 = 4
comptime MSG_KIND_ABORT: UInt8 = 5


struct _CapacityTicket(Movable):
    var budget: Optional[SharedBufferBudget]
    var amount: Int

    def __init__(
        out self,
        var budget: Optional[SharedBufferBudget] = None,
        amount: Int = 0,
    ):
        self.budget = budget^
        self.amount = amount

    def _try_reserve(mut self, amount: Int) -> Bool:
        if self.budget and not self.budget.value().try_reserve(amount):
            return False
        self.amount = amount
        return True

    def release(mut self):
        if self.budget:
            self.budget.value().release(self.amount)
        self.amount = 0

    def __deinit__(deinit self):
        self.release()


struct DetachMessage(Movable):
    """Actor message dispatched from ResponseSender to the connection actor."""

    var kind: UInt8
    var status: Int
    var headers: Headers
    var body: List[Byte]
    var should_close: Bool
    var body_ticket: _CapacityTicket

    def __init__(
        out self,
        kind: UInt8,
        status: Int = 200,
        var headers: Headers = Headers(),
        var body: List[Byte] = List[Byte](),
        should_close: Bool = False,
        var body_ticket: _CapacityTicket = _CapacityTicket(),
    ):
        self.kind = kind
        self.status = status
        self.headers = headers^
        self.body = body^
        self.should_close = should_close
        self.body_ticket = body_ticket^

    def __init__(out self, *, deinit move: Self):
        self.kind = move.kind
        self.status = move.status
        self.headers = move.headers^
        self.body = move.body^
        self.should_close = move.should_close
        self.body_ticket = move.body_ticket^

    def __deinit__(deinit self):
        _ = self.body^
        self.body_ticket.release()

    @staticmethod
    def respond(
        status: Int,
        var headers: Headers,
        var body: List[Byte],
        should_close: Bool,
        var body_ticket: _CapacityTicket = _CapacityTicket(),
    ) -> Self:
        return Self(
            MSG_KIND_RESPOND,
            status,
            headers^,
            body^,
            should_close,
            body_ticket^,
        )

    @staticmethod
    def start(status: Int, var headers: Headers) -> Self:
        return Self(
            MSG_KIND_START,
            status,
            headers^,
            List[Byte](),
            False,
        )

    @staticmethod
    def chunk(
        var body: List[Byte],
        var body_ticket: _CapacityTicket = _CapacityTicket(),
    ) -> Self:
        return Self(
            MSG_KIND_CHUNK,
            200,
            Headers(),
            body^,
            False,
            body_ticket^,
        )


@fieldwise_init
struct _DetachedBatch(Movable):
    var messages: List[DetachMessage]
    var ticket: _CapacityTicket
    var terminal_kind: UInt8
    var generation: UInt64

    def __deinit__(deinit self):
        _ = self.messages^
        self.ticket.release()


struct _SharedDetachState:
    """Heap-allocated state shared between the server connection and ResponseSender.

    Guarded by `mutex`. Cleaned up when `ref_count` reaches zero.
    """

    var mutex: PthreadMutex
    var ref_count: Int
    var wakeup_fd: Int32
    var slot: Int
    var generation: UInt64
    var cancelled: Bool
    var responded: Bool
    var started: Bool
    var finished: Bool
    var queue_limit: Int
    var queued_bytes: Int
    var messages: List[DetachMessage]
    var budget: Optional[SharedBufferBudget]
    var array_ticket: _CapacityTicket
    var terminal_kind: UInt8
    var state_ticket: _CapacityTicket

    def __init__(
        out self,
        slot: Int,
        generation: UInt64,
        var state_ticket: _CapacityTicket,
        wakeup_fd: Int32 = -1,
        queue_limit: Int = 1048576,
        var budget: Optional[SharedBufferBudget] = None,
    ):
        self.mutex = PthreadMutex._uninitialized()
        self.ref_count = 2  # 1 for connection actor, 1 for ResponseSender
        self.wakeup_fd = wakeup_fd
        self.slot = slot
        self.generation = generation
        self.cancelled = False
        self.responded = False
        self.started = False
        self.finished = False
        self.queue_limit = queue_limit
        self.queued_bytes = 0
        self.messages = List[DetachMessage]()
        self.budget = budget^
        self.array_ticket = _CapacityTicket(self.budget.copy())
        self.terminal_kind = MSG_KIND_NONE
        self.state_ticket = state_ticket^

    def __deinit__(deinit self):
        _ = self.messages^
        self.array_ticket.release()
        self.mutex.destroy()


def _append_message(
    state: Pointer[_SharedDetachState, MutUntrackedOrigin],
    var message: DetachMessage,
) -> Bool:
    var needed = len(state[].messages) + 1
    if state[].budget:
        var reservation = 0
        if not _reserve_capacity(
            state[].messages, state[].budget.value(), needed, reservation
        ):
            _ = message^
            state[].cancelled = True
            state[].finished = True
            state[].terminal_kind = MSG_KIND_ABORT
            return False
    else:
        state[].messages.reserve(max(needed, state[].messages.capacity() * 2))
    state[].array_ticket.amount = (
        state[].messages.capacity() * size_of[DetachMessage]()
    )
    state[].messages.append(message^)
    return True


def _take_batch(
    state: Pointer[_SharedDetachState, MutUntrackedOrigin],
) -> _DetachedBatch:
    state[].mutex.lock()
    var messages_ptr = Pointer(to=state[].messages)
    var messages = messages_ptr.unsafe_take_pointee()
    messages_ptr.unsafe_write(List[DetachMessage]())
    var ticket_ptr = Pointer(to=state[].array_ticket)
    var ticket = ticket_ptr.unsafe_take_pointee()
    ticket_ptr.unsafe_write(_CapacityTicket(state[].budget.copy()))
    var terminal_kind = state[].terminal_kind
    var generation = state[].generation
    state[].queued_bytes = 0
    state[].terminal_kind = MSG_KIND_NONE
    state[].mutex.unlock()
    return _DetachedBatch(messages^, ticket^, terminal_kind, generation)


def _create_detach_state(
    slot: Int,
    generation: UInt64,
    wakeup_fd: Int32 = -1,
    queue_limit: Int = 1048576,
    var budget: Optional[SharedBufferBudget] = None,
) raises NetError -> Int:
    """Allocates a new heap _SharedDetachState and returns its integer address.
    """
    var ticket = _CapacityTicket(budget.copy())
    if budget:
        var amount = size_of[_SharedDetachState]()
        if not budget.value().try_reserve(amount):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "detach",
                None,
                "detached state exceeds budget",
            )
        ticket.amount = amount
    var ptr = external_call["malloc", Pointer[Byte, MutUntrackedOrigin]](
        c_size_t(size_of[_SharedDetachState]())
    )
    if Int(ptr) == 0:
        var errno = get_errno().value
        ticket.release()
        raise NetError(
            NetErrorKind.system_error(),
            "detach",
            Int(errno),
            "detached state allocation failed",
        )
    var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
    s_ptr.unsafe_write(
        _SharedDetachState(
            slot=slot,
            generation=generation,
            state_ticket=ticket^,
            wakeup_fd=wakeup_fd,
            queue_limit=queue_limit,
            budget=budget^,
        )
    )
    s_ptr[].mutex._initialize()
    return Int(ptr)


def _release_detach_state(addr: Int, from_sender: Bool):
    """Decrements ref_count and destroys the state when reaching zero.

    If `from_sender` is True and the sender was dropped without ever responding
    or aborting, marks the state as aborted and triggers wakeup so the connection
    does not wait indefinitely.
    """
    if addr == 0:
        return
    var ptr = Pointer[Byte, MutUntrackedOrigin](unsafe_from_address=addr)
    var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
    var should_free = False
    var needs_wakeup = False
    var wakeup_fd: Int32 = -1

    s_ptr[].mutex.lock()
    if from_sender and not s_ptr[].responded and not s_ptr[].finished:
        s_ptr[].terminal_kind = MSG_KIND_ABORT
        s_ptr[].finished = True
        needs_wakeup = True
        wakeup_fd = s_ptr[].wakeup_fd

    s_ptr[].ref_count -= 1
    if s_ptr[].ref_count <= 0:
        should_free = True
    s_ptr[].mutex.unlock()

    if needs_wakeup:
        signal_wakeup_fd(wakeup_fd)

    if should_free:
        var ticket_ptr = Pointer(to=s_ptr[].state_ticket)
        var ticket = ticket_ptr.unsafe_take_pointee()
        ticket_ptr.unsafe_write(_CapacityTicket())
        s_ptr.unsafe_deinit_pointee()
        external_call["free", NoneType](ptr)
        ticket.release()


struct ResponseSender(Movable):
    """Movable proxy handle to complete or stream a detached response from another thread.

    Safe to move across threads (Movable). Sends data via an actor message-passing
    channel to the event loop, never touching the underlying socket directly.
    """

    var _addr: Int

    def __init__(out self, addr: Int):
        self._addr = addr

    def __init__(out self, *, deinit move: Self):
        self._addr = move._take()

    def __deinit__(deinit self):
        var a = self._take()
        if a != 0:
            _release_detach_state(a, from_sender=True)

    def _take(mut self) -> Int:
        var a = self._addr
        self._addr = 0
        return a

    def is_active(self) -> Bool:
        return self._addr != 0

    def is_cancelled(self) -> Bool:
        """Reports whether the underlying connection has been closed, timed out,
        or cancelled."""
        if self._addr == 0:
            return True
        var ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )
        var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
        s_ptr[].mutex.lock()
        var c = s_ptr[].cancelled
        s_ptr[].mutex.unlock()
        return c

    def respond(
        mut self,
        status: Int = 200,
        var headers: Headers = Headers(),
        var body: List[Byte] = List[Byte](),
        should_close: Bool = False,
    ) raises NetError:
        """Sends a deferred response with headers and full body.

        Raises `NetError` if called after a response was already started or completed,
        or if the connection has been cancelled (client disconnect, timeout, or shutdown).
        """
        if self._addr == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "respond",
                None,
                "ResponseSender is inactive",
            )
        var ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )
        var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
        s_ptr[].mutex.lock()
        if s_ptr[].cancelled:
            s_ptr[].responded = True
            s_ptr[].finished = True
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.closed(),
                "respond",
                None,
                (
                    "response was cancelled (client disconnect, timeout, or"
                    " shutdown)"
                ),
            )
        if s_ptr[].responded or s_ptr[].started or s_ptr[].finished:
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.invalid_state(),
                "respond",
                None,
                "response already started or finished",
            )
        s_ptr[].responded = True
        s_ptr[].finished = True
        var ticket = _CapacityTicket(s_ptr[].budget.copy())
        var admitted = ticket._try_reserve(body.capacity())
        if admitted:
            admitted = _append_message(
                s_ptr,
                DetachMessage.respond(
                    status, headers^, body^, should_close, ticket^
                ),
            )
        else:
            _ = body^
            _ = headers^
            s_ptr[].cancelled = True
            s_ptr[].finished = True
            s_ptr[].terminal_kind = MSG_KIND_ABORT
        var wakeup_fd = s_ptr[].wakeup_fd
        s_ptr[].mutex.unlock()
        signal_wakeup_fd(wakeup_fd)
        if not admitted:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "respond",
                None,
                "response capacity exceeds budget",
            )

    def start(
        mut self,
        status: Int = 200,
        var headers: Headers = Headers(),
    ) raises NetError:
        """Starts response streaming by sending the HTTP status and headers."""
        if self._addr == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "start",
                None,
                "ResponseSender is inactive",
            )
        if headers.get_first("Content-Length"):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "start",
                None,
                "Content-Length is not permitted with chunked streaming",
            )
        var ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )
        var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
        s_ptr[].mutex.lock()
        if s_ptr[].cancelled:
            s_ptr[].started = True
            s_ptr[].finished = True
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.closed(),
                "start",
                None,
                (
                    "response was cancelled (client disconnect, timeout, or"
                    " shutdown)"
                ),
            )
        if s_ptr[].responded or s_ptr[].started or s_ptr[].finished:
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.invalid_state(),
                "start",
                None,
                "response already started or finished",
            )
        s_ptr[].started = True
        var admitted = _append_message(
            s_ptr, DetachMessage.start(status, headers^)
        )
        var wakeup_fd = s_ptr[].wakeup_fd
        s_ptr[].mutex.unlock()
        signal_wakeup_fd(wakeup_fd)
        if not admitted:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "start",
                None,
                "mailbox capacity exceeds budget",
            )

    def send[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError -> Bool:
        """Enqueues a body chunk for response streaming."""
        if self._addr == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "send",
                None,
                "ResponseSender is inactive",
            )
        if len(data) == 0:
            return True
        var ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )
        var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
        s_ptr[].mutex.lock()
        if s_ptr[].cancelled:
            s_ptr[].mutex.unlock()
            return False
        if not s_ptr[].started or s_ptr[].finished or s_ptr[].responded:
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.invalid_state(),
                "send",
                None,
                "streaming response not started or already finished",
            )
        if s_ptr[].queued_bytes + len(data) > s_ptr[].queue_limit:
            s_ptr[].cancelled = True
            s_ptr[].finished = True
            s_ptr[].terminal_kind = MSG_KIND_ABORT
            var wakeup_fd = s_ptr[].wakeup_fd
            s_ptr[].mutex.unlock()
            signal_wakeup_fd(wakeup_fd)
            raise NetError(
                NetErrorKind.invalid_argument(),
                "send",
                None,
                "stream queue limit exceeded",
            )
        var ticket = _CapacityTicket(s_ptr[].budget.copy())
        var admitted = ticket._try_reserve(len(data))
        if admitted:
            var chunk_bytes = List[Byte](capacity=len(data))
            for i in range(len(data)):
                chunk_bytes.append(data[i])
            admitted = _append_message(
                s_ptr, DetachMessage.chunk(chunk_bytes^, ticket^)
            )
        else:
            s_ptr[].cancelled = True
            s_ptr[].finished = True
            s_ptr[].terminal_kind = MSG_KIND_ABORT
        if admitted:
            s_ptr[].queued_bytes += len(data)
        var wakeup_fd = s_ptr[].wakeup_fd
        s_ptr[].mutex.unlock()
        signal_wakeup_fd(wakeup_fd)
        if not admitted:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "send",
                None,
                "response capacity exceeds budget",
            )
        return True

    def finish(mut self) raises NetError:
        """Finishes the streaming response."""
        if self._addr == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "finish",
                None,
                "ResponseSender is inactive",
            )
        var ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )
        var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
        s_ptr[].mutex.lock()
        if s_ptr[].cancelled:
            s_ptr[].finished = True
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.closed(),
                "finish",
                None,
                (
                    "response was cancelled (client disconnect, timeout, or"
                    " shutdown)"
                ),
            )
        if not s_ptr[].started or s_ptr[].finished or s_ptr[].responded:
            s_ptr[].mutex.unlock()
            raise NetError(
                NetErrorKind.invalid_state(),
                "finish",
                None,
                "streaming response not started or already finished",
            )
        s_ptr[].finished = True
        s_ptr[].terminal_kind = MSG_KIND_FINISH
        var wakeup_fd = s_ptr[].wakeup_fd
        s_ptr[].mutex.unlock()
        signal_wakeup_fd(wakeup_fd)

    def abort(mut self):
        """Aborts the response, causing the server to close or 500 the connection.
        """
        if self._addr == 0:
            return
        var ptr = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )
        var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
        s_ptr[].mutex.lock()
        if s_ptr[].cancelled or s_ptr[].finished:
            s_ptr[].mutex.unlock()
            return
        s_ptr[].finished = True
        s_ptr[].terminal_kind = MSG_KIND_ABORT
        var wakeup_fd = s_ptr[].wakeup_fd
        s_ptr[].mutex.unlock()
        signal_wakeup_fd(wakeup_fd)
