"""Shared shutdown state and its notification resource."""

from std.ffi import c_size_t, external_call
from std.sys import size_of

from net._actor import PthreadMutex, WakeupChannel
from net.error import NetError, NetErrorKind


struct _ControlState:
    var mutex: PthreadMutex
    var references: Int
    var requested: Bool
    var exited: Bool
    var channel: Optional[WakeupChannel]

    def __init__(out self, var channel: WakeupChannel):
        self.mutex = PthreadMutex._uninitialized()
        self.references = 1
        self.requested = False
        self.exited = False
        self.channel = channel^


struct ServerControl(Copyable, Movable):
    """Copyable, thread-safe shutdown handle that can outlive the server."""

    var _addr: Int

    def __init__(out self) raises NetError:
        var channel = WakeupChannel()
        var raw = external_call["malloc", Pointer[Byte, MutUntrackedOrigin]](
            c_size_t(size_of[_ControlState]())
        )
        if Int(raw) == 0:
            raise NetError(
                NetErrorKind.system_error(),
                "create server control",
                None,
                "could not allocate shutdown state",
            )
        raw.unsafe_bitcast[_ControlState]().unsafe_write(
            _ControlState(channel^)
        )
        self._addr = Int(raw)
        self._state()[].mutex._initialize()

    def __init__(out self, *, copy: Self):
        self._addr = copy._addr
        var state = self._state()
        state[].mutex.lock()
        state[].references += 1
        state[].mutex.unlock()

    def __init__(out self, *, deinit move: Self):
        self._addr = move._addr

    def __deinit__(deinit self):
        var state = self._state()
        state[].mutex.lock()
        state[].references -= 1
        var last = state[].references == 0
        state[].mutex.unlock()
        if last:
            state[].mutex.destroy()
            state.unsafe_deinit_pointee()
            external_call["free", NoneType](state.unsafe_bitcast[Byte]())

    def _state(self) -> Pointer[_ControlState, MutUntrackedOrigin]:
        return Pointer[_ControlState, MutUntrackedOrigin](
            unsafe_from_address=self._addr
        )

    def request_shutdown(self):
        var state = self._state()
        state[].mutex.lock()
        if not state[].exited and not state[].requested:
            state[].requested = True
            # Closing and signaling share the lock to prevent fd reuse races.
            state[].channel.value().signal()
        state[].mutex.unlock()

    def is_shutdown_requested(self) -> Bool:
        var state = self._state()
        state[].mutex.lock()
        var requested = state[].requested
        state[].mutex.unlock()
        return requested

    def mark_exited(self):
        var state = self._state()
        state[].mutex.lock()
        state[].requested = True
        state[].exited = True
        state[].channel = None
        state[].mutex.unlock()

    def _read_fd(self) raises -> Int32:
        return self._state()[].channel.value().read_fd()

    def _drain(self):
        var state = self._state()
        state[].mutex.lock()
        state[].channel.value().drain()
        state[].mutex.unlock()
