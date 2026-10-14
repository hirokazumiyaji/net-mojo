"""Shared shutdown state and its notification resource."""

from std.ffi import c_size_t, external_call
from std.sys import size_of

from net._actor import PthreadMutex, WakeupChannel
from net.error import NetError, NetErrorKind


struct _ControlState:
    var mutex: PthreadMutex
    var references: Int
    var requested: Bool
    var channels: List[Optional[WakeupChannel]]

    def __init__(out self):
        self.mutex = PthreadMutex._uninitialized()
        self.references = 1
        self.requested = False
        self.channels = List[Optional[WakeupChannel]]()
        self.channels.append(None)


struct ServerControl(Copyable, Movable):
    """Copyable, thread-safe shutdown handle that can outlive the server."""

    var _addr: Int
    var _channel_id: Int

    def __init__(out self) raises NetError:
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
        raw.unsafe_bitcast[_ControlState]().unsafe_write(_ControlState())
        self._addr = Int(raw)
        self._channel_id = 0
        self._state()[].mutex._initialize()

    def __init__(out self, *, state_address: Int, channel_id: Int):
        self._addr = state_address
        self._channel_id = channel_id
        var state = self._state()
        state[].mutex.lock()
        state[].references += 1
        state[].mutex.unlock()

    def _fork(self) raises -> Self:
        var channel = WakeupChannel()
        var state = self._state()
        state[].mutex.lock()
        var channel_id = len(state[].channels)
        if state[].requested:
            channel.signal()
        state[].channels.append(Optional[WakeupChannel](channel^))
        state[].mutex.unlock()
        return Self(state_address=self._addr, channel_id=channel_id)

    def __init__(out self, *, copy: Self):
        self._addr = copy._addr
        self._channel_id = copy._channel_id
        var state = self._state()
        state[].mutex.lock()
        state[].references += 1
        state[].mutex.unlock()

    def __init__(out self, *, deinit move: Self):
        self._addr = move._addr
        self._channel_id = move._channel_id

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
        self._request_locked(state)
        state[].mutex.unlock()

    def _request_locked(
        self, state: Pointer[_ControlState, MutUntrackedOrigin]
    ):
        if not state[].requested:
            state[].requested = True
            for i in range(len(state[].channels)):
                if state[].channels[i]:
                    state[].channels[i].value().signal()

    def is_shutdown_requested(self) -> Bool:
        var state = self._state()
        state[].mutex.lock()
        var requested = state[].requested
        state[].mutex.unlock()
        return requested

    def mark_exited(self):
        var state = self._state()
        state[].mutex.lock()
        self._request_locked(state)
        state[].channels[self._channel_id] = None
        state[].mutex.unlock()

    def _read_fd(self) raises -> Int32:
        var state = self._state()
        state[].mutex.lock()
        try:
            if self._channel_id == 0 and not state[].channels[0]:
                var channel = WakeupChannel()
                if state[].requested:
                    channel.signal()
                state[].channels[0] = channel^
            var fd = state[].channels[self._channel_id].value().read_fd()
            state[].mutex.unlock()
            return fd
        except error:
            state[].mutex.unlock()
            raise error

    def _drain(self):
        var state = self._state()
        state[].mutex.lock()
        state[].channels[self._channel_id].value().drain()
        state[].mutex.unlock()
