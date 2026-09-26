"""Single event-loop HTTP/1.1 origin server (epoll/kqueue).

The loop owns one listener and a table of connections. Handler code runs
synchronously on the loop thread: blocking I/O or long CPU work inside a
handler stalls every connection, so handlers must stay small and fast.
Heavy-handler offload and multi-loop workers are later designs.

Ownership and resources:

- `serve` takes listener ownership and runs until shutdown completes or
  the listener and every connection are gone. Connections live in the
  internal table; only raw fd numbers are ever handed to the reactor.
- One global `BufferBudget` counts wire bytes held in receive buffers
  and queued responses. Request admission (known body length) and the
  `ResponseWriter` cap derive from the remaining budget; a request that
  cannot be admitted gets 503 and close, a handler overrun becomes 500.
- Deadlines are absolute monotonic timestamps fixed at phase entry:
  the header clock starts on the first byte, never per byte. Expired
  connections close without a response.
- `ServerControl.request_shutdown` only records the request; the loop
  owner performs every socket operation. Shutdown stops accepting,
  closes idle connections at once, drains in-flight requests within the
  grace period, then marks the control exited. A cross-thread wakeup fd
  is future work: `tick` bounds every wait, so a request is noticed on
  the next tick boundary at the latest.
- Fairness: each connection moves at most `max_bytes_per_tick` bytes
  and completes at most `max_requests_per_tick` requests per tick, and
  each tick accepts at most `max_accept_per_tick` connections.
- While a response is unsent, further request bytes stay in the kernel
  (reads are paused) so one slow reader cannot grow user buffers.
"""

from net import SocketAddress, TCPListener, Timeout, listen_tcp
from net._actor import WakeupChannel
from net._reactor import Reactor, ReactorToken
from net.error import NetError, NetErrorKind

from ._buffer import BufferBudget
from ._connection import (
    HttpConnection,
    STATE_DETACHED,
    STATE_READING,
    STATE_SENDING,
    STATE_SENDING_100,
)
from ._deadline import NO_DEADLINE, deadline_from_now, now_ns
from ._detach import (
    MSG_KIND_ABORT,
    MSG_KIND_RESPOND,
    _release_detach_state,
    _SharedDetachState,
    DetachMessage,
)
from ._encoder import (
    current_http_date,
    encode_100_continue,
    encode_error,
    encode_response,
)
from ._parser import ParseResult, parse_head, parse_one
from .config import ServerConfig
from .handler import Handler
from .headers import Headers
from .response import ResponseWriter


comptime _TICK_POLL_CAP_MS: Int = 100
comptime _READ_CHUNK: Int = 8192
comptime _SHUTDOWN_QUIET_MS: Int = 10


@fieldwise_init
struct _HeapEntry(Copyable, ImplicitlyCopyable, Movable):
    var deadline: Int
    var idx: Int
    var seq: UInt64


struct ServerControl(Movable):
    """Shutdown request handle polled by the loop owner.

    NOT yet safe to share across threads (plain `Bool` fields, no
    atomics available): today the owner thread calls `request_shutdown`
    or drives shutdown through `Server`. Cross-thread requests plus a
    wakeup fd are tracked Phase 4 work; see the module docstring.
    """

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
    var _reactor: Reactor
    var _listener: Optional[TCPListener]
    var _listener_token: ReactorToken
    var _listener_paused: Bool
    var _conns: List[HttpConnection]
    var _conn_free: List[Int]
    var _slot_map: List[Int]
    var _active_conns: Int
    var _budget: BufferBudget
    var _shutdown_at: Int
    var _tick_date: String
    # Phase 4: no per-tick full-table scans. Fairness counters reset lazily
    # via _tick_seen, capped pipelines re-drive via _urgent, and deadlines
    # expire via _deadline_heap. Ready events drive only touched conns.
    var _tick_id: Int
    var _tick_seen: List[Int]
    var _urgent: List[Int]
    var _urgent_flag: List[Bool]
    var _deadline_heap: List[_HeapEntry]
    var _deadline_seq: List[UInt64]
    var _armed_mark: List[Int]
    var _wakeup_channel: WakeupChannel
    var _wakeup_token: ReactorToken
    var _detached_conns: List[Int]

    def __init__(out self, var config: ServerConfig) raises:
        var budget_total = config.total_buffer_budget
        self.config = config^
        self.control = ServerControl()
        self._reactor = Reactor()
        self._listener = None
        self._listener_token = ReactorToken(slot=-1, generation=0)
        self._listener_paused = False
        self._conns = List[HttpConnection]()
        self._conn_free = List[Int]()
        self._slot_map = List[Int]()
        self._active_conns = 0
        self._budget = BufferBudget(budget_total)
        self._shutdown_at = NO_DEADLINE
        self._tick_date = String("")
        self._tick_id = 0
        self._tick_seen = List[Int]()
        self._urgent = List[Int]()
        self._urgent_flag = List[Bool]()
        self._deadline_heap = List[_HeapEntry]()
        self._deadline_seq = List[UInt64]()
        self._armed_mark = List[Int]()
        self._wakeup_channel = WakeupChannel()
        var wtoken = self._reactor.register(self._wakeup_channel.read_fd())
        self._wakeup_token = wtoken.copy()
        self._detached_conns = List[Int]()
        while len(self._slot_map) <= wtoken.slot:
            self._slot_map.append(-1)

    def __deinit__(deinit self):
        for idx in range(len(self._conns)):
            var addr = self._conns[idx].detach_state_addr
            if addr != 0:
                self._conns[idx].detach_state_addr = 0
                var ptr = Pointer[Byte, MutUntrackedOrigin](
                    unsafe_from_address=addr
                )
                var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
                s_ptr[].mutex.lock()
                s_ptr[].cancelled = True
                s_ptr[].mutex.unlock()
                _release_detach_state(addr, from_sender=False)

    def is_shutdown_requested(self) -> Bool:
        return self.control.is_shutdown_requested()

    def request_shutdown(mut self):
        self.control.request_shutdown()

    def active_connections(self) -> Int:
        return self._active_conns

    def add_listener(mut self, var listener: TCPListener) raises:
        if self._listener:
            raise NetError(
                NetErrorKind.invalid_state(),
                "add listener",
                None,
                "server already has a listener",
            )
        var token = self._reactor.register(listener.raw_fd())
        self._listener = listener^
        self._listener_token = token.copy()
        self._listener_paused = False

    def tick[
        H: Handler
    ](
        mut self, mut handler: H, timeout: Optional[Timeout] = None
    ) raises -> Bool:
        """Runs one loop iteration. Returns False once the listener is
        gone and no connection remains (the control is then marked
        exited). Tests drive this directly for deterministic I/O."""
        var now = now_ns()
        self._tick_date = current_http_date()
        self._note_shutdown(now)
        if not self._listener and self._active_conns == 0:
            self.control.mark_exited()
            return False
        self._tick_id += 1
        # Capped pipelines from the previous tick re-drive without a kernel
        # event; blocking up to the wait cap here would stall a pipelined
        # flood ~100ms per 16 requests.
        var urgent = List[Int]()
        for i in range(len(self._urgent)):
            var idx = self._urgent[i]
            if idx >= 0 and idx < len(self._conns) and self._conns[idx].active:
                urgent.append(idx)
            if idx >= 0 and idx < len(self._urgent_flag):
                self._urgent_flag[idx] = False
        var wait_timeout = self._compute_timeout(now, timeout)
        self._process_detached_messages(now)
        while len(self._urgent) > 0:
            var nidx = self._urgent.pop(0)
            if (
                nidx >= 0
                and nidx < len(self._urgent_flag)
                and self._conns[nidx].active
            ):
                urgent.append(nidx)
            if nidx >= 0 and nidx < len(self._urgent_flag):
                self._urgent_flag[nidx] = False
        if len(urgent) > 0:
            wait_timeout = Timeout.nanoseconds(0)
        var events = self._reactor.wait(wait_timeout)
        now = now_ns()
        if self._listener:
            for i in range(len(events)):
                if events[i].token == self._listener_token:
                    self._accept_pending(now)
                    break
        for i in range(len(events)):
            if events[i].token == self._wakeup_token:
                self._wakeup_channel.drain()
                self._process_detached_messages(now)
                break
        # Fold the ready batch into per-connection masks via the slot map.
        # Token equality pins the generation, so a reused reactor slot can
        # never steer an event at the wrong connection. Only touched conns
        # plus urgent pipelines are driven; idle conns cost nothing.
        var touched = List[Int]()
        var masks = List[UInt8]()
        for k in range(len(events)):
            var slot = events[k].token.slot
            if slot < 0 or slot >= len(self._slot_map):
                continue
            var idx = self._slot_map[slot]
            if idx < 0 or idx >= len(self._conns):
                continue
            if not self._conns[idx].active:
                continue
            if not (self._conns[idx].token == events[k].token):
                continue
            var found = -1
            for t in range(len(touched)):
                if touched[t] == idx:
                    found = t
                    break
            var mask: UInt8 = 0
            if found >= 0:
                mask = masks[found]
            if events[k].readable:
                mask |= 1
            if events[k].writable:
                mask |= 2
            if found >= 0:
                masks[found] = mask
            else:
                touched.append(idx)
                masks.append(mask)
        for u in range(len(urgent)):
            var idx = urgent[u]
            var seen = False
            for t in range(len(touched)):
                if touched[t] == idx:
                    seen = True
                    break
            if not seen:
                touched.append(idx)
                masks.append(0)
        for t in range(len(touched)):
            var idx = touched[t]
            if not self._conns[idx].active:
                continue
            if self._tick_seen[idx] != self._tick_id:
                self._conns[idx].reset_tick()
                self._tick_seen[idx] = self._tick_id
            var readable = (masks[t] & 1) != 0
            var writable = (masks[t] & 2) != 0
            self._conns[idx].more_work = False
            self._drive_conn(idx, readable, writable, handler, now)
            if not self._conns[idx].active:
                continue
            if self._conns[idx].more_work:
                self._push_urgent(idx)
            else:
                self._arm_deadline(idx)
        self._expire_deadlines(now_ns())
        self._process_detached_messages(now_ns())
        if not self._listener and self._active_conns == 0:
            self.control.mark_exited()
            return False
        return True

    def serve[
        H: Handler
    ](mut self, var listener: TCPListener, mut handler: H) raises:
        """Runs the event loop until shutdown completes. Takes listener
        ownership."""
        self.add_listener(listener^)
        while True:
            if not self.tick(handler, None):
                break

    def serve_with_control[
        H: Handler
    ](
        mut self,
        var listener: TCPListener,
        mut handler: H,
        mut control: ServerControl,
    ) raises:
        """Runs the event loop like `serve`, but polls and exits through
        a caller-held `ServerControl` instead of the owned one.

        The handle is polled, not shared: it is mutably borrowed for the
        whole call, so the caller cannot use it while this runs, and
        calling `request_shutdown` from another thread becomes safe only
        once the control is backed by shared atomic state (tracked Phase 4
        work). Today this only supports pre-requesting shutdown before
        entry (then it exits promptly); to stop a running server, drive
        `add_listener` + `tick` and call `request_shutdown` between ticks.
        """
        self.add_listener(listener^)
        while True:
            if control.is_shutdown_requested():
                self.control.request_shutdown()
            if not self.tick(handler, None):
                break
            if self.control.is_shutdown_requested():
                control.request_shutdown()
        control.mark_exited()

    def local_address(self) raises NetError -> SocketAddress:
        """Returns the bound listener address (handy with ephemeral
        ports). Fails when no listener is installed."""
        if not self._listener:
            raise NetError(
                NetErrorKind.invalid_state(),
                "local address",
                None,
                "server has no listener",
            )
        return self._listener.value().local_address()

    def _ensure_slot_map(mut self, slot: Int):
        while len(self._slot_map) <= slot:
            self._slot_map.append(-1)

    def _ensure_conn_arrays(mut self, idx: Int):
        while len(self._tick_seen) <= idx:
            self._tick_seen.append(-1)
            self._urgent_flag.append(False)
            self._deadline_seq.append(1)
            self._armed_mark.append(NO_DEADLINE)

    def _push_urgent(mut self, idx: Int):
        if idx < 0 or idx >= len(self._urgent_flag):
            return
        if self._urgent_flag[idx]:
            return
        self._urgent_flag[idx] = True
        self._urgent.append(idx)

    def _next_deadline(self, idx: Int) -> Int:
        if not self._conns[idx].active:
            return NO_DEADLINE
        if self._conns[idx].state == STATE_DETACHED:
            return self._conns[idx].detach_at
        if self._conns[idx].state == STATE_READING:
            if self._conns[idx].buffered_len() > 0:
                var best = NO_DEADLINE
                if self._conns[idx].body_at != NO_DEADLINE:
                    best = self._conns[idx].body_at
                if self._conns[idx].header_at != NO_DEADLINE:
                    if best == NO_DEADLINE or self._conns[idx].header_at < best:
                        best = self._conns[idx].header_at
                return best
            return self._conns[idx].idle_at
        return self._conns[idx].write_at

    def _arm_deadline(mut self, idx: Int):
        if idx < 0 or idx >= len(self._conns):
            return
        self._ensure_conn_arrays(idx)
        if not self._conns[idx].active:
            self._armed_mark[idx] = NO_DEADLINE
            return
        var mark = self._next_deadline(idx)
        if mark == self._armed_mark[idx]:
            return
        var seq = self._deadline_seq[idx] + 1
        if seq == 0:
            seq = 1
        self._deadline_seq[idx] = seq
        self._armed_mark[idx] = mark
        if mark == NO_DEADLINE:
            return
        self._heap_push(mark, idx, seq)

    def _heap_push(mut self, deadline: Int, idx: Int, seq: UInt64):
        self._deadline_heap.append(
            _HeapEntry(deadline=deadline, idx=idx, seq=seq)
        )
        var pos = len(self._deadline_heap) - 1
        while pos > 0:
            var parent = (pos - 1) // 2
            if (
                self._deadline_heap[parent].deadline
                <= self._deadline_heap[pos].deadline
            ):
                break
            var tmp = self._deadline_heap[parent]
            self._deadline_heap[parent] = self._deadline_heap[pos]
            self._deadline_heap[pos] = tmp
            pos = parent

    def _heap_pop(mut self) -> _HeapEntry:
        var top = self._deadline_heap[0]
        var last = self._deadline_heap.pop()
        if len(self._deadline_heap) > 0:
            self._deadline_heap[0] = last^
            var pos = 0
            while True:
                var left = pos * 2 + 1
                var right = left + 1
                var smallest = pos
                if (
                    left < len(self._deadline_heap)
                    and self._deadline_heap[left].deadline
                    < self._deadline_heap[smallest].deadline
                ):
                    smallest = left
                if (
                    right < len(self._deadline_heap)
                    and self._deadline_heap[right].deadline
                    < self._deadline_heap[smallest].deadline
                ):
                    smallest = right
                if smallest == pos:
                    break
                var tmp = self._deadline_heap[pos]
                self._deadline_heap[pos] = self._deadline_heap[smallest]
                self._deadline_heap[smallest] = tmp
                pos = smallest
        return top^

    def _expire_deadlines(mut self, now: Int) raises NetError:
        if self._shutdown_at != NO_DEADLINE and now >= self._shutdown_at:
            # Shutdown expiry is global and runs once: close everything.
            # O(N) here is fine; it is not a per-tick hot path.
            for i in range(len(self._conns)):
                if self._conns[i].active:
                    self._close_conn(i)
            return
        while len(self._deadline_heap) > 0:
            var top = self._deadline_heap[0]
            if top.deadline > now:
                break
            _ = self._heap_pop()
            var idx = top.idx
            if idx < 0 or idx >= len(self._conns):
                continue
            if not self._conns[idx].active:
                continue
            if (
                idx >= len(self._deadline_seq)
                or self._deadline_seq[idx] != top.seq
            ):
                continue
            # Recompute: only phases that can fire for the current state
            # close. Stale timestamps from earlier phases must not kill a
            # connection (e.g. an old header deadline during a long send).
            var mark = self._next_deadline(idx)
            if mark == NO_DEADLINE or mark > now:
                continue
            if self._conns[idx].state == STATE_DETACHED:
                self._handle_detached_timeout(idx)
                continue
            self._close_conn(idx)

    def _note_shutdown(mut self, now: Int):
        if self.control.is_shutdown_requested():
            if self._shutdown_at == NO_DEADLINE:
                self._shutdown_at = now + Int(self.config.shutdown_grace._value)
                self._drop_listener()
                # Idle connections (nothing buffered, nothing queued)
                # stop waiting out their long keep-alive clock: give
                # them a short cushion instead. Anything with bytes in
                # flight keeps its body/write deadlines and drains
                # normally; the cushion only bounds how long a truly
                # idle connection lingers, so a request racing shutdown
                # by microseconds still gets its poll round.
                var quiet = now + _SHUTDOWN_QUIET_MS * 1_000_000
                for i in range(len(self._conns)):
                    if not self._conns[i].active:
                        continue
                    if (
                        self._conns[i].state == STATE_READING
                        and self._conns[i].buffered_len() == 0
                        and self._conns[i].pending_remaining() == 0
                        and self._conns[i].idle_at > quiet
                    ):
                        self._conns[i].idle_at = quiet
                        self._arm_deadline(i)

    def _drop_listener(mut self):
        if self._listener:
            _ = self._reactor.remove(self._listener_token)
            try:
                self._listener.value().close()
            except e:
                _ = e
            self._listener = None
            self._listener_token = ReactorToken(slot=-1, generation=0)
            self._listener_paused = False

    def _pause_listener(mut self):
        if self._listener and not self._listener_paused:
            _ = self._reactor.remove(self._listener_token)
            self._listener_paused = True

    def _resume_listener(mut self) raises NetError:
        if self._listener and self._listener_paused:
            var token = self._reactor.register(self._listener.value().raw_fd())
            self._listener_token = token.copy()
            self._listener_paused = False

    def _accept_pending(mut self, now: Int) raises NetError:
        var accepted = 0
        while accepted < self.config.max_accept_per_tick:
            if self._shutdown_at != NO_DEADLINE:
                break
            if not self._listener or self._listener_paused:
                break
            if self._active_conns >= self.config.max_connections:
                self._pause_listener()
                break
            try:
                var fresh = self._listener.value().try_accept()
                var token = self._reactor.register(fresh.raw_fd())
                self._ensure_slot_map(token.slot)
                var idle_at = deadline_from_now(self.config.idle_timeout)
                var entry = HttpConnection(token, fresh^, idle_at, NO_DEADLINE)
                var idx: Int
                if len(self._conn_free) > 0:
                    idx = self._conn_free.pop()
                    self._conns[idx] = entry^
                else:
                    idx = len(self._conns)
                    self._conns.append(entry^)
                self._slot_map[token.slot] = idx
                self._active_conns += 1
                accepted += 1
                self._ensure_conn_arrays(idx)
                self._tick_seen[idx] = self._tick_id
                self._urgent_flag[idx] = False
                self._arm_deadline(idx)
            except e:
                if e.kind == NetErrorKind.timeout():
                    break
                if e.kind == NetErrorKind.closed():
                    self._drop_listener()
                    break
                break

    def _close_conn(mut self, idx: Int) raises NetError:
        if idx < 0 or idx >= len(self._conns):
            return
        if not self._conns[idx].active:
            return
        if self._conns[idx].detach_state_addr != 0:
            self._mark_detached_cancelled(idx)
            self._cleanup_detached_state(idx)
            self._remove_detached_conn(idx)
        var token = self._conns[idx].token.copy()
        _ = self._reactor.remove(token)
        if token.slot >= 0 and token.slot < len(self._slot_map):
            if self._slot_map[token.slot] == idx:
                self._slot_map[token.slot] = -1
        if idx >= 0 and idx < len(self._urgent_flag):
            self._urgent_flag[idx] = False
        if idx >= 0 and idx < len(self._deadline_seq):
            var seq = self._deadline_seq[idx] + 1
            if seq == 0:
                seq = 1
            self._deadline_seq[idx] = seq
        if idx >= 0 and idx < len(self._armed_mark):
            self._armed_mark[idx] = NO_DEADLINE
        # Release the whole pending reservation, not just the unsent
        # suffix: bytes already written were charged when queued, and
        # leaving the sent prefix charged would leak budget on every
        # partial-send close until unrelated requests see 503s. Any
        # admission reservation still held is released the same way.
        self._budget.release(
            self._conns[idx].buffered_len() + len(self._conns[idx].pending)
        )
        self._budget.release(self._conns[idx].reserved)
        self._conns[idx].reserved = 0
        try:
            self._conns[idx].close()
        except e:
            _ = e
        self._conn_free.append(idx)
        self._active_conns -= 1
        if (
            self._listener_paused
            and self._shutdown_at == NO_DEADLINE
            and self._active_conns < self.config.max_connections
        ):
            try:
                self._resume_listener()
            except e:
                _ = e

    def _send_error(
        mut self, idx: Int, status: Int, is_head: Bool = False
    ) raises NetError:
        if self._conns[idx].detach_state_addr != 0:
            self._mark_detached_cancelled(idx)
            self._cleanup_detached_state(idx)
            self._remove_detached_conn(idx)
        var wire = encode_error(status, True, self._tick_date, is_head=is_head)
        # Error responses use a small fixed body: when even that does not
        # fit the remaining budget, close bare.
        if not self._budget.try_reserve(len(wire)):
            self._close_conn(idx)
            return
        self._conns[idx].set_pending(wire^)
        self._conns[idx].should_close = True
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        self._sync_interests(idx)

    def _sync_interests(mut self, idx: Int) raises NetError:
        _ = self._reactor.modify(
            self._conns[idx].token,
            self._conns[idx].wants_read(),
            self._conns[idx].pending_remaining() > 0,
        )

    def _drive_conn[
        H: Handler
    ](
        mut self,
        idx: Int,
        readable: Bool,
        writable: Bool,
        mut handler: H,
        now: Int,
    ) raises:
        if not self._conns[idx].active:
            return
        if (
            self._conns[idx].state == STATE_SENDING
            or self._conns[idx].state == STATE_SENDING_100
        ):
            self._pump_send(idx, writable)
            if not self._conns[idx].active:
                return
        if self._conns[idx].state == STATE_DETACHED:
            if readable:
                self._pump_read(idx, readable, now)
                if not self._conns[idx].active:
                    return
                if self._conns[idx].read_eof:
                    # Peer disconnected: cancel detached state and close socket immediately.
                    self._close_conn(idx)
                    return
                # Re-sync interests: the read above can fill the buffer, which flips
                # wants_read() to False and must drop reactor read interest.
                self._sync_interests(idx)
            return
        if self._conns[idx].state == STATE_READING:
            if (
                self._conns[idx].read_eof
                and self._conns[idx].buffered_len() == 0
                and self._conns[idx].pending_remaining() == 0
            ):
                # Drained everything the half-closed peer sent.
                self._close_conn(idx)
                return
            self._pump_read(idx, readable, now)
            if not self._conns[idx].active:
                return
            # Chain pipelined requests inside one drive: after an eager
            # flush lands back in READING with bytes buffered, parsing
            # the next request immediately avoids a ~100ms stall behind
            # the next tick's wait although no socket event is needed.
            while True:
                if self._conns[idx].state != STATE_READING:
                    break
                if self._conns[idx].buffered_len() == 0:
                    break
                if (
                    self._conns[idx].requests_this_tick
                    >= self.config.max_requests_per_tick
                ):
                    # Capped with work left behind: the next tick must
                    # not wait on the kernel for bytes already held.
                    # Flagged per connection so unrelated idle
                    # connections are not re-driven with it.
                    self._conns[idx].more_work = True
                    break
                # Only a response queued by the parse below earns an
                # optimistic first flush without a writable event.
                var queued_before = self._conns[idx].pending_remaining() > 0
                self._pump_parse(idx, handler, now)
                if not self._conns[idx].active:
                    return
                if self._conns[idx].state == STATE_READING:
                    break
                if not queued_before and (
                    self._conns[idx].pending_remaining() > 0
                ):
                    self._pump_send(idx, True)
                if not self._conns[idx].active:
                    return
        self._sync_interests(idx)

    def _pump_read(mut self, idx: Int, event: Bool, now: Int) raises NetError:
        if not event:
            return
        if self._conns[idx].read_eof:
            return
        while True:
            var room = (
                self.config.max_bytes_per_tick
                - self._conns[idx].bytes_this_tick
            )
            if room <= 0:
                break
            var limit = room if room < _READ_CHUNK else _READ_CHUNK
            try:
                var chunk = self._conns[idx].try_read_bytes(limit)
                if len(chunk) == 0:
                    self._conns[idx].read_eof = True
                    if (
                        self._conns[idx].state == STATE_READING
                        and self._conns[idx].buffered_len() == 0
                        and self._conns[idx].pending_remaining() == 0
                    ):
                        # Clean keep-alive EOF with nothing buffered.
                        self._close_conn(idx)
                        return
                    break
                if not self._charge_read(idx, len(chunk)):
                    self._admit_over_budget(idx)
                    return
                var first = self._conns[idx].buffered_len() == 0
                self._conns[idx].append_bytes(Span(chunk))
                self._conns[idx].bytes_this_tick += len(chunk)
                if first:
                    self._conns[idx].header_at = deadline_from_now(
                        self.config.header_deadline
                    )
                if len(chunk) < limit:
                    break
            except e:
                if e.kind == NetErrorKind.timeout():
                    break
                self._close_conn(idx)
                return

    def _charge_read(mut self, idx: Int, count: Int) -> Bool:
        # Bytes covered by an admission reservation reuse it; only the
        # remainder draws from the shared budget. The reservation is
        # decremented only after the extra draw succeeds: on failure the
        # chunk is discarded and the error path still releases the full
        # reservation, so decrementing first would leak the covered part
        # out of the budget forever.
        var covered = count
        if covered > self._conns[idx].reserved:
            covered = self._conns[idx].reserved
        var rest = count - covered
        if rest > 0 and not self._budget.try_reserve(rest):
            return False
        self._conns[idx].reserved -= covered
        return True

    def _admit_over_budget(mut self, idx: Int) raises NetError:
        # The kernel still holds the unread bytes; answer from what is
        # already buffered when possible, otherwise close bare.
        var head = parse_head(Span(self._conns[idx].buf), self.config)
        if head.is_complete():
            self._send_error(idx, 503)
        else:
            self._close_conn(idx)

    def _pump_parse[
        H: Handler
    ](mut self, idx: Int, mut handler: H, now: Int) raises:
        while (
            self._conns[idx].requests_this_tick
            < self.config.max_requests_per_tick
        ):
            if self._conns[idx].state != STATE_READING:
                break
            if self._conns[idx].buffered_len() == 0:
                break
            var head = parse_head(Span(self._conns[idx].buf), self.config)
            if head.is_need_more():
                if self._conns[idx].read_eof:
                    self._close_conn(idx)
                    return
                self._conns[idx].scanned_len = self._conns[idx].buffered_len()
                break
            if head.is_error():
                var head_status = head.take_error().status
                self._send_error(idx, head_status)
                return
            var content_length = head.head.content_length
            # Admit only the body bytes still missing: what is already
            # buffered is counted in the budget, so adding the full
            # declared length would charge it twice and 503 requests
            # that actually fit.
            var buffered_body = (
                self._conns[idx].buffered_len() - head.head.header_end
            )
            if buffered_body < 0:
                buffered_body = 0
            var outstanding = content_length - buffered_body
            if outstanding < 0:
                outstanding = 0
            # The live reservation is part of `used`: subtract it before
            # adding the outstanding remainder, or every re-parse while
            # the body is still arriving would charge the same bytes
            # twice and 503 admitted requests.
            var unreserved = self._budget.used - self._conns[idx].reserved
            if (
                content_length > 0
                and unreserved + outstanding > self._budget.total
            ):
                self._send_error(idx, 503)
                return
            # Reserve the missing bytes now so concurrent admissions
            # cannot promise the same capacity twice. Arrivals consume
            # the reservation via _charge_read; completion and close
            # release whatever remains. Guarded to reserve once per
            # request: re-parses while the body is still arriving must
            # not charge again.
            if outstanding > 0 and self._conns[idx].reserved == 0:
                if not self._budget.try_reserve(outstanding):
                    self._send_error(idx, 503)
                    return
                self._conns[idx].reserved += outstanding
            if head.head.expect_100 and not self._conns[idx].sent_100:
                if not self._send_100(idx):
                    return
            if self._conns[idx].body_at == NO_DEADLINE:
                self._conns[idx].body_at = deadline_from_now(
                    self.config.body_deadline
                )
                # The header phase is over once a validated head hands
                # off to body reading; leaving header_at armed would let
                # the short header deadline kill a slow but admitted
                # upload.
                self._conns[idx].header_at = NO_DEADLINE
            var result = parse_one(Span(self._conns[idx].buf), self.config)
            if result.is_need_more():
                if self._conns[idx].read_eof:
                    self._close_conn(idx)
                    return
                self._conns[idx].scanned_len = self._conns[idx].buffered_len()
                break
            if result.is_error():
                var body_status = result.take_error().status
                self._send_error(idx, body_status)
                return
            var req_close = result.should_close
            var consumed = result.consumed
            self._budget.release(consumed)
            self._conns[idx].drain_prefix(consumed)
            self._conns[idx].requests_this_tick += 1
            self._respond(idx, result^, req_close, handler)
            if not self._conns[idx].active:
                return
            if self._conns[idx].state != STATE_READING:
                break

    def _send_100(mut self, idx: Int) raises NetError -> Bool:
        var cont = encode_100_continue()
        # The interim send obeys the same per-tick allowance as every
        # other write: cap the slice and account for it, so a tiny
        # allowance cannot be overshot and later writes do not get a
        # second full share.
        var allowance = (
            self.config.max_bytes_per_tick - self._conns[idx].bytes_this_tick
        )
        if allowance < 0:
            allowance = 0
        var first = len(cont) if len(cont) < allowance else allowance
        try:
            var written = self._conns[idx].try_write_bytes(Span(cont)[0:first])
            self._conns[idx].bytes_this_tick += written
            if written < len(cont):
                var rest = List[Byte]()
                for i in range(written, len(cont)):
                    rest.append(cont[i])
                # Queued bytes join the budget like any pending send so
                # the later full-length release stays balanced.
                if not self._budget.try_reserve(len(rest)):
                    self._close_conn(idx)
                    return False
                self._conns[idx].set_pending(rest^)
                self._conns[idx].state = STATE_SENDING_100
                self._conns[idx].write_at = deadline_from_now(
                    self.config.write_deadline
                )
                self._sync_interests(idx)
                return False
        except e:
            if e.kind == NetErrorKind.timeout():
                if not self._budget.try_reserve(len(cont)):
                    self._close_conn(idx)
                    return False
                self._conns[idx].set_pending(cont^)
                self._conns[idx].state = STATE_SENDING_100
                self._conns[idx].write_at = deadline_from_now(
                    self.config.write_deadline
                )
                self._sync_interests(idx)
                return False
            self._close_conn(idx)
            return False
        self._conns[idx].sent_100 = True
        return True

    def _respond[
        H: Handler
    ](
        mut self,
        idx: Int,
        var result: ParseResult,
        req_close: Bool,
        mut handler: H,
    ) raises:
        var req = result.take_request()
        var is_head = req.method == "HEAD"
        self._conns[idx].is_head = is_head
        # The advertised body cap subtracts a fixed framing margin for
        # the status line, Date, Content-Length, and terminator (~130B
        # worst case, held at 256B), so a body within cap always fits
        # the wire: handlers are never promised bytes the encoder
        # cannot send. Subtracting the whole response-header allowance
        # instead would be dishonest in the other direction — e.g. a
        # 6KiB echo on an 8KiB budget with a 32KiB header allowance
        # would cap at zero and 500 everything — while per-header
        # count/byte caps still bound header-heavy responses above.
        var cap = self.config.max_response_body
        var room = self._budget.remaining() - 256
        if room < cap:
            cap = room
        if cap < 0:
            cap = 0
        var writer = ResponseWriter(
            cap,
            slot=idx,
            generation=self._conns[idx].token.generation,
            wakeup_fd=self._wakeup_channel.write_fd(),
        )
        # The wire must advertise close whenever the connection will not
        # persist, even when the handler leaves the writer untouched.
        if req_close or self._shutdown_at != NO_DEADLINE:
            writer.set_should_close(True)
        try:
            handler.handle(req^, writer)
        except e:
            _ = e
            if writer.is_detached():
                var addr = writer._detach_state_addr
                if addr != 0:
                    var ptr = Pointer[Byte, MutUntrackedOrigin](
                        unsafe_from_address=addr
                    )
                    var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
                    s_ptr[].mutex.lock()
                    s_ptr[].cancelled = True
                    s_ptr[].mutex.unlock()
                    _release_detach_state(addr, from_sender=False)
                    writer._detach_state_addr = 0
            self._send_error(idx, 500)
            return

        if writer.is_detached():
            var addr = writer._detach_state_addr
            if addr == 0:
                self._send_error(idx, 500)
                return
            self._conns[idx].state = STATE_DETACHED
            self._conns[idx].detach_state_addr = addr
            self._conns[idx].is_head = is_head
            self._conns[idx].req_close = (
                req_close
                or writer.should_close
                or self._shutdown_at != NO_DEADLINE
            )
            self._conns[idx].detach_at = deadline_from_now(
                self.config.detached_response_timeout
            )
            self._conns[idx].header_at = NO_DEADLINE
            self._conns[idx].body_at = NO_DEADLINE
            self._conns[idx].idle_at = NO_DEADLINE
            self._conns[idx].write_at = NO_DEADLINE
            self._detached_conns.append(idx)
            self._arm_deadline(idx)
            self._sync_interests(idx)
            return

        # Handlers may append to `writer.body` directly, bypassing the
        # per-call cap enforced by `write`; re-check the bound here so
        # an oversized body becomes a 500 either way.
        if len(writer.body) > cap:
            self._send_error(idx, 500)
            return
        # Header count/bytes are enforced inside the encoder, the single
        # authoritative site; its failure below becomes a 500 the same way.
        var wire: List[Byte]
        try:
            wire = encode_response(
                writer,
                is_head,
                self._tick_date,
                self.config.max_response_headers_count,
                self.config.max_response_headers_bytes,
            )
        except e:
            _ = e
            self._send_error(idx, 500)
            return
        if not self._budget.try_reserve(len(wire)):
            self._send_error(idx, 500)
            return
        self._conns[idx].set_pending(wire^)
        # A half-closed peer (read_eof) forces close only when nothing
        # is left to answer: pipelined requests already buffered must
        # still be served first. The EOF drain rule in _drive_conn
        # closes the connection once the buffer runs dry.
        self._conns[idx].should_close = (
            req_close
            or writer.should_close
            or (
                self._conns[idx].read_eof
                and self._conns[idx].buffered_len() == 0
            )
            or self._shutdown_at != NO_DEADLINE
        )
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )

    def _pump_send(mut self, idx: Int, event: Bool) raises NetError:
        if not self._conns[idx].active:
            return
        if self._conns[idx].pending_remaining() == 0:
            return
        if not event:
            return
        while self._conns[idx].pending_remaining() > 0:
            var allowance = (
                self.config.max_bytes_per_tick
                - self._conns[idx].bytes_this_tick
            )
            if allowance <= 0:
                break
            try:
                var n = self._conns[idx].try_write_pending_capped(allowance)
                self._conns[idx].bytes_this_tick += n
            except e:
                if e.kind == NetErrorKind.timeout():
                    break
                self._close_conn(idx)
                return
            if self._conns[idx].pending_remaining() > 0:
                break
        if not self._conns[idx].active:
            return
        if self._conns[idx].pending_remaining() > 0:
            return
        var sent = len(self._conns[idx].pending)
        self._budget.release(sent)
        var was_100 = self._conns[idx].state == STATE_SENDING_100
        self._conns[idx].clear_pending()
        if was_100:
            self._conns[idx].state = STATE_READING
            self._conns[idx].sent_100 = True
            return
        self._conns[idx].requests_served += 1
        if self._conns[idx].should_close or self._shutdown_at != NO_DEADLINE:
            self._close_conn(idx)
            return
        self._conns[idx].state = STATE_READING
        self._conns[idx].is_head = False
        self._conns[idx].sent_100 = False
        self._conns[idx].body_at = NO_DEADLINE
        self._conns[idx].write_at = NO_DEADLINE
        if self._conns[idx].buffered_len() > 0:
            # A pipelined next head is already waiting: arm its header
            # deadline now. Without this, clearing below would leave a
            # partial head with no deadline at all (idle only applies to
            # empty buffers), retaining the connection indefinitely.
            self._conns[idx].header_at = deadline_from_now(
                self.config.header_deadline
            )
            self._conns[idx].idle_at = deadline_from_now(
                self.config.idle_timeout
            )
            self._push_urgent(idx)
        else:
            self._conns[idx].header_at = NO_DEADLINE
            self._conns[idx].idle_at = deadline_from_now(
                self.config.idle_timeout
            )

    def _mark_detached_cancelled(mut self, idx: Int):
        if idx < 0 or idx >= len(self._conns):
            return
        var addr = self._conns[idx].detach_state_addr
        if addr != 0:
            var ptr = Pointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=addr
            )
            var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
            s_ptr[].mutex.lock()
            s_ptr[].cancelled = True
            s_ptr[].mutex.unlock()

    def _cleanup_detached_state(mut self, idx: Int):
        if idx < 0 or idx >= len(self._conns):
            return
        var addr = self._conns[idx].detach_state_addr
        if addr != 0:
            self._conns[idx].detach_state_addr = 0
            self._conns[idx].detach_at = NO_DEADLINE
            _release_detach_state(addr, from_sender=False)

    def _remove_detached_conn(mut self, idx: Int):
        for i in range(len(self._detached_conns)):
            if self._detached_conns[i] == idx:
                _ = self._detached_conns.pop(i)
                break

    def _handle_detached_timeout(mut self, idx: Int) raises NetError:
        var is_head = self._conns[idx].is_head
        self._mark_detached_cancelled(idx)
        self._cleanup_detached_state(idx)
        self._remove_detached_conn(idx)
        self._send_error(idx, 503, is_head=is_head)
        self._arm_deadline(idx)

    def _process_detached_messages(mut self, now: Int) raises NetError:
        if len(self._detached_conns) == 0:
            return
        var i = 0
        while i < len(self._detached_conns):
            var idx = self._detached_conns[i]
            if (
                idx < 0
                or idx >= len(self._conns)
                or not self._conns[idx].active
                or self._conns[idx].state != STATE_DETACHED
            ):
                if (
                    idx >= 0
                    and idx < len(self._conns)
                    and self._conns[idx].detach_state_addr != 0
                ):
                    self._mark_detached_cancelled(idx)
                    self._cleanup_detached_state(idx)
                _ = self._detached_conns.pop(i)
                continue

            if (
                self._conns[idx].detach_at != NO_DEADLINE
                and now >= self._conns[idx].detach_at
            ):
                self._handle_detached_timeout(idx)
                if (
                    i < len(self._detached_conns)
                    and self._detached_conns[i] == idx
                ):
                    _ = self._detached_conns.pop(i)
                continue

            var addr = self._conns[idx].detach_state_addr
            if addr == 0:
                _ = self._detached_conns.pop(i)
                continue

            var ptr = Pointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=addr
            )
            var s_ptr = ptr.unsafe_bitcast[_SharedDetachState]()
            s_ptr[].mutex.lock()
            if len(s_ptr[].messages) == 0:
                s_ptr[].mutex.unlock()
                i += 1
                continue
            var msgs = List[DetachMessage]()
            while len(s_ptr[].messages) > 0:
                msgs.append(s_ptr[].messages.pop(0))
            s_ptr[].mutex.unlock()

            # Phase B processes exactly one terminal message (MSG_KIND_RESPOND or MSG_KIND_ABORT).
            # Streaming chunk messages will be processed iteratively in Phase C.
            var handled = False
            while len(msgs) > 0:
                var msg = msgs.pop(0)
                if msg.kind == MSG_KIND_RESPOND:
                    if self._conns[idx].token.generation == s_ptr[].generation:
                        self._handle_detached_respond(idx, msg)
                    else:
                        self._mark_detached_cancelled(idx)
                        self._cleanup_detached_state(idx)
                        self._close_conn(idx)
                    handled = True
                    break
                elif msg.kind == MSG_KIND_ABORT:
                    self._handle_detached_abort(idx)
                    handled = True
                    break
                else:
                    self._handle_detached_abort(idx)
                    handled = True
                    break

            if handled:
                if (
                    i < len(self._detached_conns)
                    and self._detached_conns[i] == idx
                ):
                    _ = self._detached_conns.pop(i)
            else:
                i += 1

    def _handle_detached_respond(
        mut self, idx: Int, mut msg: DetachMessage
    ) raises NetError:
        var is_head = self._conns[idx].is_head
        var req_close = self._conns[idx].req_close or msg.should_close
        var rw = ResponseWriter(self.config.max_response_body)
        rw.status = msg.status
        var h = msg.headers^
        msg.headers = Headers()
        rw.headers = h^
        var b = msg.body^
        msg.body = List[Byte]()
        rw.body = b^
        rw.set_should_close(req_close or (self._shutdown_at != NO_DEADLINE))

        if len(rw.body) > self.config.max_response_body:
            self._mark_detached_cancelled(idx)
            self._cleanup_detached_state(idx)
            self._send_error(idx, 500, is_head=is_head)
            self._arm_deadline(idx)
            return

        var wire: List[Byte]
        try:
            wire = encode_response(
                rw,
                is_head,
                self._tick_date,
                self.config.max_response_headers_count,
                self.config.max_response_headers_bytes,
            )
        except e:
            _ = e
            self._mark_detached_cancelled(idx)
            self._cleanup_detached_state(idx)
            self._send_error(idx, 500, is_head=is_head)
            self._arm_deadline(idx)
            return

        if not self._budget.try_reserve(len(wire)):
            self._mark_detached_cancelled(idx)
            self._cleanup_detached_state(idx)
            self._send_error(idx, 500, is_head=is_head)
            self._arm_deadline(idx)
            return

        self._cleanup_detached_state(idx)
        self._conns[idx].set_pending(wire^)
        self._conns[idx].should_close = (
            rw.should_close
            or (
                self._conns[idx].read_eof
                and self._conns[idx].buffered_len() == 0
            )
            or (self._shutdown_at != NO_DEADLINE)
        )
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        self._sync_interests(idx)
        self._pump_send(idx, True)
        if self._conns[idx].active:
            self._sync_interests(idx)
            self._arm_deadline(idx)
            if (
                self._conns[idx].state == STATE_READING
                and self._conns[idx].buffered_len() > 0
            ):
                self._push_urgent(idx)

    def _handle_detached_abort(mut self, idx: Int) raises NetError:
        self._cleanup_detached_state(idx)
        self._send_error(idx, 500)
        self._arm_deadline(idx)

    def _compute_timeout(
        mut self, now: Int, timeout: Optional[Timeout]
    ) raises NetError -> Optional[Timeout]:
        var explicit = _Deadline_from_optional_ms(timeout)
        var best = _TICK_POLL_CAP_MS
        if explicit < best:
            best = explicit
        if self._shutdown_at != NO_DEADLINE:
            var left_ms = (self._shutdown_at - now) // 1_000_000
            if left_ms < 0:
                left_ms = 0
            if left_ms < best:
                best = Int(left_ms)
        # Heap peek only: no scan over idle connections. Stale entries are
        # skipped without popping so a burst of invalidations never costs
        # more than the live minimum.
        while len(self._deadline_heap) > 0:
            var top = self._deadline_heap[0]
            var idx = top.idx
            if (
                idx < 0
                or idx >= len(self._conns)
                or not self._conns[idx].active
            ):
                _ = self._heap_pop()
                continue
            if (
                idx >= len(self._deadline_seq)
                or self._deadline_seq[idx] != top.seq
            ):
                _ = self._heap_pop()
                continue
            var mark = self._next_deadline(idx)
            if mark == NO_DEADLINE or mark != top.deadline:
                _ = self._heap_pop()
                continue
            best = _sooner(best, mark, now)
            break
        if best < 0:
            best = 0
        return Timeout.milliseconds(UInt64(best))


def _sooner(best: Int, mark: Int, now: Int) -> Int:
    if mark == NO_DEADLINE:
        return best
    var left_ms = (mark - now) // 1_000_000
    if left_ms < 0:
        left_ms = 0
    if Int(left_ms) < best:
        return Int(left_ms)
    return best


def _Deadline_from_optional_ms(timeout: Optional[Timeout]) -> Int:
    if not timeout:
        return Int.MAX
    var value = timeout.value()._value
    var ms = value // 1_000_000
    if value % 1_000_000 != 0:
        ms += 1
    if ms > UInt64(Int.MAX):
        return Int.MAX
    return Int(ms)


def listen_and_serve[
    H: Handler
](address: StringSlice, var config: ServerConfig, mut handler: H) raises:
    """Binds `address` and serves until shutdown completes."""
    var server = Server(config^)
    var listener = listen_tcp(address)
    server.serve(listener^, handler)


def listen_and_serve_with_control[
    H: Handler
](
    address: StringSlice,
    var config: ServerConfig,
    mut handler: H,
    mut control: ServerControl,
) raises:
    """Binds `address` and serves like `listen_and_serve`, but through a
    caller-held shutdown handle. See `serve_with_control` for the
    polling (not yet cross-thread-safe) contract."""
    var server = Server(config^)
    var listener = listen_tcp(address)
    server.serve_with_control(listener^, handler, control)
