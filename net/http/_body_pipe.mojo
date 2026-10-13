"""Decoded input queue; protocol adapters retain ownership of receive credit.

Only retained byte capacity and trailer storage use the shared buffer budget.
The Arc allocation and consumer-owned trailer copies remain separate.
"""

from std.memory import ArcPointer

from net._actor import PthreadMutex, signal_wakeup_fd
from net import Timeout
from net.timeout import _Deadline
from ._body_signal import _BodyCondition, _TIMED_OUT
from net.error import NetError, NetErrorKind
from ._buffer import SharedBufferBudget, _reserve_capacity
from .headers import Headers


struct _BodyPipeState(Movable):
    var mutex: PthreadMutex
    var condition: _BodyCondition
    var loop_wakeup_fd: Int32
    var budget: SharedBufferBudget
    var limit: Int
    var bytes: List[Byte]
    var head: Int
    var decoded: Int
    var consumed: Int
    var finished: Bool
    var cancelled: Bool
    var claimed: Bool
    var discarded: Bool
    var terminal_trailers: Headers

    def __init__(
        out self, limit: Int, var budget: SharedBufferBudget, wakeup_fd: Int32
    ):
        self.mutex = PthreadMutex._uninitialized()
        self.condition = _BodyCondition()
        self.loop_wakeup_fd = wakeup_fd
        self.budget = budget^
        self.limit = limit
        self.bytes = List[Byte]()
        self.head = 0
        self.decoded = 0
        self.consumed = 0
        self.finished = False
        self.cancelled = False
        self.claimed = False
        self.discarded = False
        self.terminal_trailers = Headers()

    def __deinit__(deinit self):
        _drop_body_bytes(Pointer(to=self))
        self.condition.destroy()
        self.mutex.destroy()


# Keep owned-field replacement from moving the live native mutex.
def _drop_body_bytes[origin: MutOrigin](state: Pointer[_BodyPipeState, origin]):
    var bytes_ptr = Pointer(to=state[].bytes)
    var bytes = bytes_ptr.unsafe_take_pointee()
    bytes_ptr.unsafe_write(List[Byte]())
    var capacity = bytes.capacity()
    _ = bytes^
    state[].head = 0
    state[].budget.release(capacity)


def _body_error(kind: NetErrorKind, message: String) -> NetError:
    return NetError(kind, "read request body", None, message)


def _copy_body_trailers(headers: Headers) raises NetError -> Headers:
    var copied = Headers()
    for i in range(len(headers)):
        copied.add_bytes(headers.name_at(i), headers._value_bytes_span(i))
    return copied^


struct _BodyPipe(Copyable):
    var _state: ArcPointer[_BodyPipeState]

    def __init__(
        out self,
        limit: Int,
        var budget: SharedBufferBudget,
        wakeup_fd: Int32 = -1,
    ) raises NetError:
        if limit < 1:
            raise _body_error(
                NetErrorKind.invalid_argument(), "body limit must be positive"
            )
        self._state = ArcPointer(_BodyPipeState(limit, budget^, wakeup_fd))
        self._state[].mutex._initialize()
        self._state[].condition.initialize()

    def push[origin: ImmOrigin](self, data: Span[Byte, origin]) -> Bool:
        ref state = self._state[]
        state.mutex.lock()
        if state.finished or state.cancelled:
            state.mutex.unlock()
            return False
        if state.discarded:
            state.decoded += len(data)
            state.consumed += len(data)
            state.mutex.unlock()
            return True
        var pending = len(state.bytes) - state.head
        if len(data) > state.limit - pending:
            state.mutex.unlock()
            return False
        if state.head > 0 and state.head >= len(state.bytes) // 2:
            for i in range(pending):
                state.bytes[i] = state.bytes[state.head + i]
            state.bytes.resize(pending, fill=0)
            state.head = 0
        var reservation = 0
        if not _reserve_capacity(
            state.bytes, state.budget, len(state.bytes) + len(data), reservation
        ):
            state.mutex.unlock()
            return False
        for byte in data:
            state.bytes.append(byte)
        state.decoded += len(data)
        state.condition.broadcast()
        state.mutex.unlock()
        return True

    def push_eof(self, var trailers: Headers = Headers()) raises NetError:
        ref state = self._state[]
        state.mutex.lock()
        if state.finished or state.cancelled:
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.invalid_state(), "body already terminated"
            )
        if not trailers._adopt_capacity_budget(Optional(state.budget.copy())):
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.invalid_argument(),
                "body trailers exceed buffer budget",
            )
        var trailers_ptr = Pointer(to=state.terminal_trailers)
        var previous = trailers_ptr.unsafe_take_pointee()
        trailers_ptr.unsafe_write(trailers^)
        _ = previous^
        state.finished = True
        state.condition.broadcast()
        state.mutex.unlock()

    def pop[
        origin: MutOrigin
    ](self, buffer: Span[mut=True, Byte, origin]) raises NetError -> Int:
        ref state = self._state[]
        state.mutex.lock()
        if state.cancelled:
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.cancelled(), "request body cancelled"
            )
        var pending = len(state.bytes) - state.head
        if pending == 0:
            var finished = state.finished
            state.mutex.unlock()
            if finished:
                return 0
            raise _body_error(
                NetErrorKind.timeout(), "request body needs more input"
            )
        if len(buffer) == 0:
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.invalid_argument(), "body read buffer is empty"
            )
        var count = min(pending, len(buffer))
        for i in range(count):
            buffer[i] = state.bytes[state.head + i]
        state.head += count
        state.consumed += count
        if state.head == len(state.bytes):
            _drop_body_bytes(Pointer(to=state))
        signal_wakeup_fd(state.loop_wakeup_fd)
        state.mutex.unlock()
        return count

    def receive[
        origin: MutOrigin
    ](
        self,
        buffer: Span[mut=True, Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        if len(buffer) == 0:
            raise _body_error(
                NetErrorKind.invalid_argument(), "body receive buffer is empty"
            )
        var deadline = _Deadline.from_optional(timeout)
        ref state = self._state[]
        state.mutex.lock()
        while (
            state.head == len(state.bytes)
            and not state.finished
            and not state.cancelled
        ):
            var result = state.condition.wait(state.mutex, deadline)
            if result != 0:
                state.mutex.unlock()
                if result == _TIMED_OUT:
                    raise _body_error(
                        NetErrorKind.timeout(), "request body receive timed out"
                    )
                raise NetError(
                    NetErrorKind.system_error(),
                    "wait request body",
                    Int(result),
                    "condition wait failed",
                )
        state.mutex.unlock()
        return self.pop(buffer)

    def is_eof(self) -> Bool:
        ref state = self._state[]
        state.mutex.lock()
        var eof = (
            state.finished
            and not state.cancelled
            and state.head == len(state.bytes)
        )
        state.mutex.unlock()
        return eof

    def is_cancelled(self) -> Bool:
        ref state = self._state[]
        state.mutex.lock()
        var cancelled = state.cancelled
        state.mutex.unlock()
        return cancelled

    def total_decoded(self) -> Int:
        ref state = self._state[]
        state.mutex.lock()
        var count = state.decoded
        state.mutex.unlock()
        return count

    def pending_bytes(self) -> Int:
        ref state = self._state[]
        state.mutex.lock()
        var count = len(state.bytes) - state.head
        state.mutex.unlock()
        return count

    def take_consumed(self) -> Int:
        ref state = self._state[]
        state.mutex.lock()
        var count = state.consumed
        state.consumed = 0
        state.mutex.unlock()
        return count

    def trailers(self) raises NetError -> Headers:
        ref state = self._state[]
        state.mutex.lock()
        if state.cancelled:
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.cancelled(), "request body cancelled"
            )
        if not state.finished or state.head != len(state.bytes):
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.invalid_state(),
                "body trailers require consumed EOF",
            )
        try:
            var trailers = _copy_body_trailers(state.terminal_trailers)
            state.mutex.unlock()
            return trailers^
        except error:
            state.mutex.unlock()
            raise error^

    def discard(self) raises NetError:
        ref state = self._state[]
        state.mutex.lock()
        if state.cancelled:
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.cancelled(), "request body cancelled"
            )
        state.consumed += len(state.bytes) - state.head
        _drop_body_bytes(Pointer(to=state))
        state.discarded = True
        signal_wakeup_fd(state.loop_wakeup_fd)
        state.mutex.unlock()

    def cancel(self):
        ref state = self._state[]
        state.mutex.lock()
        _drop_body_bytes(Pointer(to=state))
        var trailers_ptr = Pointer(to=state.terminal_trailers)
        var trailers = trailers_ptr.unsafe_take_pointee()
        trailers_ptr.unsafe_write(Headers())
        _ = trailers^
        state.cancelled = True
        state.loop_wakeup_fd = -1
        state.condition.broadcast()
        state.mutex.unlock()

    def claim_reader(self) raises NetError:
        ref state = self._state[]
        state.mutex.lock()
        if state.claimed or state.cancelled:
            state.mutex.unlock()
            raise _body_error(
                NetErrorKind.invalid_state(),
                "body reader already claimed or cancelled",
            )
        state.claimed = True
        state.mutex.unlock()
