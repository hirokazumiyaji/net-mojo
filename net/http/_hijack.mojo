"""Single-slot ownership handoff after HTTP/1 output has drained."""

from std.ffi import c_int, c_size_t, external_call, get_errno
from std.sys import size_of

from net._actor import PthreadMutex, PthreadCond, signal_wakeup_fd
from net.error import NetError, NetErrorKind
from ._buffer import SharedBufferBudget, _CapacityTicket
from .switch import HijackedConn


struct _SharedHijackState:
    var mutex: PthreadMutex
    var condition: PthreadCond
    var ref_count: Int
    var slot: Int
    var generation: UInt64
    var wakeup_fd: Int32
    var pending_response: List[Byte]
    var pending_offset: Int
    var response_ticket: _CapacityTicket
    var state_ticket: _CapacityTicket
    var completed: Bool
    var cancelled: Bool
    var connection: Optional[HijackedConn]

    def __init__(
        out self,
        slot: Int,
        generation: UInt64,
        wakeup_fd: Int32,
        var pending_response: List[Byte],
        var response_ticket: _CapacityTicket,
        var state_ticket: _CapacityTicket,
    ):
        self.mutex = PthreadMutex._uninitialized()
        self.condition = PthreadCond()
        self.ref_count = 2
        self.slot = slot
        self.generation = generation
        self.wakeup_fd = wakeup_fd
        self.pending_response = pending_response^
        self.pending_offset = 0
        self.response_ticket = response_ticket^
        self.state_ticket = state_ticket^
        self.completed = False
        self.cancelled = False
        self.connection = None

    def __deinit__(deinit self):
        _ = self.connection^
        _ = self.pending_response^
        self.response_ticket.release()
        self.condition.destroy()
        self.mutex.destroy()


def _create_hijack_state(
    slot: Int,
    generation: UInt64,
    wakeup_fd: Int32 = -1,
    var budget: Optional[SharedBufferBudget] = None,
    var pending_response: List[Byte] = List[Byte](),
    var response_ticket: _CapacityTicket = _CapacityTicket(),
) raises NetError -> Int:
    var ticket = _CapacityTicket(budget^)
    if not ticket._try_reserve(size_of[_SharedHijackState]()):
        raise NetError(
            NetErrorKind.invalid_argument(),
            "hijack",
            None,
            "hijack state exceeds buffer budget",
        )
    var allocation = external_call["malloc", Pointer[Byte, MutUntrackedOrigin]](
        c_size_t(size_of[_SharedHijackState]())
    )
    if Int(allocation) == 0:
        raise NetError(
            NetErrorKind.system_error(),
            "hijack",
            Int(get_errno().value),
            "hijack state allocation failed",
        )
    var state = allocation.unsafe_bitcast[_SharedHijackState]()
    state.unsafe_write(
        _SharedHijackState(
            slot,
            generation,
            wakeup_fd,
            pending_response^,
            response_ticket^,
            ticket^,
        )
    )
    state[].mutex._initialize()
    state[].condition.initialize()
    return Int(allocation)


def _hijack_state(addr: Int) -> Pointer[_SharedHijackState, MutUntrackedOrigin]:
    return Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=addr
    ).unsafe_bitcast[_SharedHijackState]()


def _cancel_hijack_state(addr: Int):
    var state = _hijack_state(addr)
    state[].mutex.lock()
    if not state[].completed:
        state[].cancelled = True
        state[].wakeup_fd = -1
        state[].condition.broadcast()
    state[].mutex.unlock()


def _complete_hijack_state(addr: Int, var connection: HijackedConn) -> Bool:
    var state = _hijack_state(addr)
    state[].mutex.lock()
    if state[].cancelled:
        state[].mutex.unlock()
        return False
    state[].connection = connection^
    state[].completed = True
    state[].condition.broadcast()
    signal_wakeup_fd(state[].wakeup_fd)
    state[].mutex.unlock()
    return True


def _release_hijack_state(addr: Int, from_sender: Bool):
    var state = _hijack_state(addr)
    state[].mutex.lock()
    if not state[].completed and not state[].cancelled:
        state[].cancelled = True
        state[].condition.broadcast()
        if from_sender:
            signal_wakeup_fd(state[].wakeup_fd)
    if not from_sender:
        state[].wakeup_fd = -1
    state[].ref_count -= 1
    var free_state = state[].ref_count == 0
    state[].mutex.unlock()
    if free_state:
        var ticket_ptr = Pointer(to=state[].state_ticket)
        var ticket = ticket_ptr.unsafe_take_pointee()
        ticket_ptr.unsafe_write(_CapacityTicket())
        state.unsafe_deinit_pointee()
        external_call["free", NoneType](state.unsafe_bitcast[Byte]())
        ticket.release()


struct HijackSender(Movable):
    """Worker endpoint; take_connection waits for flush completion or cancellation.

    Transfer it to a worker before calling take_connection: waiting on the
    HTTP loop thread prevents that loop from completing the handoff.
    """

    var _addr: Int

    def __init__(out self, addr: Int):
        self._addr = addr

    def __init__(out self, *, deinit move: Self):
        self._addr = move._take()

    def __deinit__(deinit self):
        var addr = self._take()
        if addr != 0:
            _release_hijack_state(addr, from_sender=True)

    def _take(mut self) -> Int:
        var addr = self._addr
        self._addr = 0
        return addr

    def is_cancelled(self) -> Bool:
        if self._addr == 0:
            return True
        var state = _hijack_state(self._addr)
        state[].mutex.lock()
        var cancelled = state[].cancelled
        state[].mutex.unlock()
        return cancelled

    def abort(deinit self):
        var addr = self._take()
        if addr != 0:
            _release_hijack_state(addr, from_sender=True)

    def take_connection(deinit self) raises NetError -> HijackedConn:
        var addr = self._take()
        if addr == 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "take hijacked connection",
                None,
                "hijack sender has been consumed",
            )
        var state = _hijack_state(addr)
        state[].mutex.lock()
        while not state[].completed and not state[].cancelled:
            _ = state[].condition.wait(state[].mutex)
        if state[].cancelled:
            state[].mutex.unlock()
            _release_hijack_state(addr, from_sender=True)
            raise NetError(
                NetErrorKind.closed(),
                "take hijacked connection",
                None,
                "connection closed before handoff",
            )
        var connection = state[].connection.take()
        state[].mutex.unlock()
        _release_hijack_state(addr, from_sender=True)
        return connection^
