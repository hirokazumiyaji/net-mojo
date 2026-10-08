"""Single event-loop HTTP/1.1 origin server (epoll/kqueue).

The loop owns one listener and a table of connections. Handler code runs
synchronously on the loop thread: blocking I/O or long CPU work inside a
handler stalls every connection, so handlers must stay small and fast.
Heavy-handler offload and multi-loop workers are later designs.

Ownership and resources:

- `serve` takes listener ownership and runs until shutdown completes or
  the listener and every connection are gone. Connections live in the
  internal table; only raw fd numbers are ever handed to the reactor.
- One global `SharedBufferBudget` charges receive and adopted pending capacity,
  including growth peaks and owned synchronous HTTP/1 writer bodies.
  Decoded HTTP/1 body copies reserve capacity before materialization and hold
  that reservation until the borrowed request is dropped after its handler.
  Buffered HTTP/1 wire is reserved before encoding. HTTP/1 error wire is
  prepaid at connection admission and transferred into the same pending owner;
  other encoding remains separate.
  Read scratch uses a caller-owned stack array; TLS retains its charged
  retry buffer until connection close.
  Request admission and the `ResponseWriter` cap derive from the remaining
  budget; a request that
  cannot be admitted gets 503 and close, a handler overrun becomes 500.
- Deadlines are absolute monotonic timestamps fixed at phase entry:
  the header clock starts on the first byte, never per byte. Expired
  connections close without a response.
- `ServerControl.request_shutdown` only records the request; the loop
  owner performs every socket operation. Shutdown stops accepting,
  closes idle connections at once, drains in-flight requests within the
  grace period, then marks the shared control exited. A shutdown request
  wakes the reactor immediately; copied handles may outlive the server.
- Fairness: each connection moves at most `max_bytes_per_tick` bytes
  and completes at most `max_requests_per_tick` requests per tick, and
  each tick accepts at most `max_accept_per_tick` connections.
- While a response is unsent, further request bytes stay in the kernel
  (reads are paused) so one slow reader cannot grow user buffers.
"""

from net import SocketAddress, TCPConn, TCPListener, Timeout, listen_tcp
from net._actor import WakeupChannel
from net._reactor import Reactor, ReactorToken
from net.error import NetError, NetErrorKind
from net.quic import QuicUDPEndpoint

from ._buffer import SharedBufferBudget, _reserve_capacity
from ._control import ServerControl
from ._connection import (
    HttpConnection,
    PROTOCOL_HTTP2,
    STATE_DETACHED,
    STATE_HANDSHAKING,
    STATE_READING,
    STATE_SENDING,
    STATE_SENDING_HTTP2_CONTROL,
    STATE_SENDING_100,
    STATE_STREAMING,
    STATE_TLS_SHUTDOWN,
    READ_BUFFER_SIZE,
    H1_ERROR_CAPACITY,
)
from ._deadline import NO_DEADLINE, deadline_from_now, now_ns
from ._detach import (
    MSG_KIND_ABORT,
    MSG_KIND_CHUNK,
    MSG_KIND_FINISH,
    MSG_KIND_NONE,
    MSG_KIND_RESPOND,
    MSG_KIND_START,
    _cancel_detach_state,
    _detach_state,
    _release_detach_state,
    _take_batch,
    DetachMessage,
)
from ._encoder import (
    current_http_date,
    _encode_chunk_budgeted,
    _encode_chunk_end_budgeted,
    _encode_chunked_start_budgeted,
    _render_error,
    _measure_error,
    _encode_response_budgeted,
)
from ._parser import (
    ParseResult,
    _RequestScan,
    _scan_chunked,
    _scan_head,
    parse_body,
    parse_head,
)
from .config import ServerConfig
from .handler import Handler
from .headers import Headers, _check_value_bytes
from .response import (
    ResponseWriter,
    has_body_for_status,
    maybe_inject_alt_svc,
)
from .request import HttpVersion, Request, split_path_query
from net.tls import TLSConnection, TLSContext
from net.http._http2.hpack import Http2HpackDeflater
from net.http._http2.request_session import (
    Http2RequestSession,
    Http2RequestSessionResult,
)
from net.http._http2.response_headers import _content_length_matches
from net.http._http2.response_encoder import (
    encode_http2_response_header_frames,
    http2_response_end_on_headers,
)
from net.http._http2.control_frames import encode_rst_stream_frame


comptime _TICK_POLL_CAP_MS: Int = 100
comptime _SHUTDOWN_QUIET_MS: Int = 10
comptime _QUIC_GOAWAY_DELAY_NS: Int = 1_000_000_000
comptime _QUIC_CLOSE_DRAIN_NS: Int = 3_000_000_000
comptime _HPACK_DEFLATER_TABLE_CAP: Int = 4096


def _bounded_hpack_table_size(peer_value: UInt32) -> Int:
    var value = Int(peer_value)
    if value > _HPACK_DEFLATER_TABLE_CAP:
        return _HPACK_DEFLATER_TABLE_CAP
    return value


@fieldwise_init
struct _HeapEntry(Copyable, ImplicitlyCopyable, Movable):
    var deadline: Int
    var idx: Int


struct Server(Movable):
    var config: ServerConfig
    var control: ServerControl
    var _control_token: ReactorToken
    var _reactor: Reactor
    var _listener: Optional[TCPListener]
    var _tls_context: Optional[TLSContext]
    var _listener_token: ReactorToken
    var _listener_paused: Bool
    var _quic_endpoint: Optional[QuicUDPEndpoint]
    var _quic_token: ReactorToken
    var _conns: List[HttpConnection]
    var _conn_free: List[Int]
    var _slot_map: List[Int]
    var _active_conns: Int
    var _budget: SharedBufferBudget
    var _shutdown_at: Int
    var _quic_finish_at: Int
    var _quic_close_at: Int
    var _tick_date: String
    # Phase 4: no per-tick full-table scans. Fairness counters reset lazily
    # via _tick_seen, capped pipelines re-drive via _urgent, and deadlines
    # expire via _deadline_heap. Ready events drive only touched conns.
    var _tick_id: Int
    var _tick_seen: List[Int]
    var _urgent: List[Int]
    var _urgent_flag: List[Bool]
    var _deadline_heap: List[_HeapEntry]
    var _deadline_pos: List[Int]
    var _wakeup_channel: WakeupChannel
    var _wakeup_token: ReactorToken
    var _detached_conns: List[Int]

    def __init__(out self, var config: ServerConfig) raises:
        var budget_total = config.total_buffer_budget
        self.config = config^
        self.control = ServerControl()
        self._reactor = Reactor()
        self._control_token = self._reactor.register(self.control._read_fd())
        self._listener = None
        self._tls_context = None
        self._listener_token = ReactorToken(slot=-1, generation=0)
        self._listener_paused = False
        self._quic_endpoint = None
        self._quic_token = ReactorToken(slot=-1, generation=0)
        self._conns = List[HttpConnection]()
        self._conn_free = List[Int]()
        self._slot_map = List[Int]()
        self._active_conns = 0
        self._budget = SharedBufferBudget(budget_total)
        self._shutdown_at = NO_DEADLINE
        self._quic_finish_at = NO_DEADLINE
        self._quic_close_at = NO_DEADLINE
        self._tick_date = String("")
        self._tick_id = 0
        self._tick_seen = List[Int]()
        self._urgent = List[Int]()
        self._urgent_flag = List[Bool]()
        self._deadline_heap = List[_HeapEntry]()
        self._deadline_pos = List[Int]()
        self._wakeup_channel = WakeupChannel()
        var wtoken = self._reactor.register(self._wakeup_channel.read_fd())
        self._wakeup_token = wtoken.copy()
        self._detached_conns = List[Int]()
        while len(self._slot_map) <= wtoken.slot:
            self._slot_map.append(-1)

    def __deinit__(deinit self):
        self._finish_control()
        for idx in range(len(self._conns)):
            var addr = self._conns[idx].detach_state_addr
            if addr != 0:
                self._conns[idx].detach_state_addr = 0
                _cancel_detach_state(addr)
            var wire_capacity = (
                self._conns[idx].buf.capacity()
                + self._conns[idx].pending.capacity()
            )
            self._conns[idx].buf = List[Byte]()
            self._conns[idx].pending = List[Byte]()
            self._budget.release(wire_capacity)

    def is_shutdown_requested(self) -> Bool:
        return self.control.is_shutdown_requested()

    def request_shutdown(mut self):
        self.control.request_shutdown()

    def active_connections(self) -> Int:
        return self._active_conns

    def _inject_alt_svc_for_tls(
        mut self, idx: Int, mut writer: ResponseWriter
    ) raises:
        # Opt-in HTTPS advertisement only: plaintext and empty alt_svc skip.
        if not self._conns[idx].is_tls():
            return
        maybe_inject_alt_svc(writer, self.config.alt_svc)

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

    def add_tls_listener(
        mut self, var listener: TCPListener, var tls_context: TLSContext
    ) raises:
        self.add_listener(listener^)
        self._tls_context = Optional[TLSContext](tls_context^)

    def add_quic_endpoint(mut self, var endpoint: QuicUDPEndpoint) raises:
        if self._quic_endpoint:
            raise NetError(
                NetErrorKind.invalid_state(),
                "add QUIC endpoint",
                None,
                "server already has a QUIC endpoint",
            )
        endpoint.set_connection_limit(self.config.max_connections)
        endpoint.set_transport_memory_limit(
            self.config.quic_max_transport_memory_bytes
        )
        endpoint.set_receive_limits(
            self.config.quic_receive_request_bytes,
            self.config.quic_receive_request_slots,
            self.config.quic_receive_control_bytes,
            self.config.quic_receive_control_slots,
            self.config.quic_receive_crypto_bytes,
            self.config.quic_receive_crypto_slots,
        )
        endpoint.set_send_limits(
            self.config.quic_send_request_bytes,
            self.config.quic_send_request_slots,
            self.config.quic_send_control_bytes,
            self.config.quic_send_control_slots,
            self.config.quic_send_crypto_bytes,
            self.config.quic_send_crypto_slots,
        )
        endpoint.set_request_limits(
            self.config.max_body_bytes,
            self.config.max_headers_bytes,
            self.config.max_headers_count,
            self.config.max_trailer_bytes,
            self.config.max_trailer_count,
        )
        endpoint.set_response_limits(
            self.config.max_response_body,
            self.config.max_response_headers_bytes,
            self.config.max_response_headers_count,
        )
        endpoint.set_stream_deadlines(
            self.config.header_deadline,
            self.config.body_deadline,
            self.config.idle_timeout,
            self.config.write_deadline,
        )
        var token = self._reactor.register(endpoint.raw_fd())
        self._quic_token = token.copy()
        self._quic_endpoint = Optional[QuicUDPEndpoint](endpoint^)

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
        if (
            not self._listener
            and not self._quic_endpoint
            and self._active_conns == 0
        ):
            self._finish_control()
            return False
        self._tick_id += 1
        var wait_timeout = self._compute_timeout(now, timeout)
        self._process_detached_messages(now)
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
        self._urgent.clear()
        if len(urgent) > 0:
            wait_timeout = Timeout.nanoseconds(0)
        var events = self._reactor.wait(wait_timeout)
        now = now_ns()
        self._note_shutdown(now)
        for i in range(len(events)):
            if events[i].token == self._control_token:
                self.control._drain()
                break
        self._drive_quic()
        self._dispatch_quic_requests(handler)
        self._finish_quic_shutdown_if_due(now)
        self._flush_quic()
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
        if (
            not self._listener
            and not self._quic_endpoint
            and self._active_conns == 0
        ):
            self._finish_control()
            return False
        return True

    def serve[
        H: Handler
    ](mut self, var listener: TCPListener, mut handler: H) raises:
        """Runs the event loop until shutdown completes. Takes listener
        ownership."""
        try:
            self.add_listener(listener^)
            self._run(handler)
        except error:
            self._finish_control()
            raise error

    def serve_tls[
        H: Handler
    ](
        mut self,
        var listener: TCPListener,
        var tls_context: TLSContext,
        mut handler: H,
    ) raises:
        """Serves HTTP/1.1 over TLS and takes ownership of listener and context.
        """
        try:
            self.add_tls_listener(listener^, tls_context^)
            self._run(handler)
            self._tls_context = None
        except error:
            self._finish_control()
            raise error

    def _run[H: Handler](mut self, mut handler: H) raises:
        while True:
            if not self.tick(handler, None):
                break

    def _finish_control(mut self):
        _ = self._reactor.remove(self._control_token)
        self.control.mark_exited()

    def serve_with_control[
        H: Handler
    ](
        mut self,
        var listener: TCPListener,
        mut handler: H,
        control: ServerControl,
    ) raises:
        """Serves with a shared handle; callers may keep a copy on another thread.
        """
        try:
            if self.control._addr != control._addr:
                self._finish_control()
                self.control = control.copy()
                self._control_token = self._reactor.register(
                    self.control._read_fd()
                )
            self.add_listener(listener^)
            self._run(handler)
        except error:
            self._finish_control()
            raise error

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
            self._deadline_pos.append(-1)

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
        if self._conns[idx].state == STATE_HANDSHAKING:
            return self._conns[idx].tls_handshake_at
        if self._conns[idx].state == STATE_TLS_SHUTDOWN:
            return self._conns[idx].tls_shutdown_at
        if self._conns[idx].state == STATE_DETACHED:
            return self._conns[idx].detach_at
        if self._conns[idx].state == STATE_STREAMING:
            if self._conns[idx].write_at != NO_DEADLINE:
                return self._conns[idx].write_at
            return self._conns[idx].detach_at
        if self._conns[idx].protocol == PROTOCOL_HTTP2:
            var best = NO_DEADLINE
            if self._conns[idx].write_at != NO_DEADLINE:
                best = self._conns[idx].write_at
            if self._conns[idx].http2_session:
                var stream_deadline = (
                    self._conns[idx].http2_session.value().next_deadline()
                )
                if stream_deadline != NO_DEADLINE:
                    if best == NO_DEADLINE or stream_deadline < best:
                        best = stream_deadline
            if (
                self._conns[idx].state == STATE_READING
                and self._conns[idx].pending_remaining() == 0
                and self._conns[idx].http2_responses.queued_count() == 0
            ):
                if best == NO_DEADLINE or self._conns[idx].idle_at < best:
                    best = self._conns[idx].idle_at
            return best
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
        var mark = self._next_deadline(idx)
        var pos = self._deadline_pos[idx]
        if mark == NO_DEADLINE:
            if pos != -1:
                self._heap_remove(pos)
            return
        if pos == -1:
            self._deadline_pos[idx] = len(self._deadline_heap)
            self._deadline_heap.append(_HeapEntry(deadline=mark, idx=idx))
            self._heap_repair(len(self._deadline_heap) - 1)
        elif self._deadline_heap[pos].deadline != mark:
            self._deadline_heap[pos].deadline = mark
            self._heap_repair(pos)

    def _heap_swap(mut self, left: Int, right: Int):
        var tmp = self._deadline_heap[left]
        self._deadline_heap[left] = self._deadline_heap[right]
        self._deadline_heap[right] = tmp
        self._deadline_pos[self._deadline_heap[left].idx] = left
        self._deadline_pos[self._deadline_heap[right].idx] = right

    def _heap_repair(mut self, pos: Int):
        var current = pos
        while current > 0:
            var parent = (current - 1) // 2
            if (
                self._deadline_heap[parent].deadline
                <= self._deadline_heap[current].deadline
            ):
                break
            self._heap_swap(parent, current)
            current = parent
        while True:
            var left = current * 2 + 1
            var right = left + 1
            var smallest = current
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
            if smallest == current:
                break
            self._heap_swap(current, smallest)
            current = smallest

    def _heap_remove(mut self, pos: Int):
        var idx = self._deadline_heap[pos].idx
        var last = self._deadline_heap.pop()
        self._deadline_pos[idx] = -1
        if pos < len(self._deadline_heap):
            self._deadline_heap[pos] = last^
            self._deadline_pos[self._deadline_heap[pos].idx] = pos
            self._heap_repair(pos)

    def _heap_pop(mut self) -> _HeapEntry:
        var top = self._deadline_heap[0]
        self._heap_remove(0)
        return top^

    def _expire_deadlines(mut self, now: Int) raises NetError:
        if self._quic_close_at != NO_DEADLINE:
            if (
                not self._quic_endpoint
                or self._quic_endpoint.value().shutdown_complete()
                or now >= self._quic_close_at
            ):
                self._drop_quic_endpoint()
                self._quic_close_at = NO_DEADLINE
            return
        if self._shutdown_at != NO_DEADLINE and now >= self._shutdown_at:
            # Shutdown expiry is global and runs once: close everything.
            # O(N) here is fine; it is not a per-tick hot path.
            for i in range(len(self._conns)):
                if self._conns[i].active:
                    self._close_conn(i)
            self._finish_quic_shutdown()
            if self._quic_endpoint:
                self._quic_endpoint.value().close_connections()
                self._flush_quic()
                self._quic_close_at = now + _QUIC_CLOSE_DRAIN_NS
            else:
                self._drop_quic_endpoint()
            return
        while len(self._deadline_heap) > 0:
            var top = self._deadline_heap[0]
            if top.deadline > now:
                break
            _ = self._heap_pop()
            var idx = top.idx
            var mark = self._next_deadline(idx)
            if mark == NO_DEADLINE or mark > now:
                self._arm_deadline(idx)
                continue
            if self._conns[idx].state == STATE_DETACHED:
                self._handle_detached_timeout(idx)
                continue
            if self._conns[idx].state == STATE_STREAMING:
                self._handle_detached_timeout(idx)
                continue
            if (
                self._conns[idx].protocol == PROTOCOL_HTTP2
                and self._conns[idx].http2_session
            ):
                if (
                    self._conns[idx].write_at != NO_DEADLINE
                    and now >= self._conns[idx].write_at
                ):
                    self._close_conn(idx)
                    continue
                var expired = self._conns[idx].http2_session.value().expire(now)
                if len(expired) > 0:
                    if not self._conns[idx].append_pending(
                        expired^, self._budget
                    ):
                        self._close_conn(idx)
                        continue
                    self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
                    self._conns[idx].write_at = deadline_from_now(
                        self.config.write_deadline
                    )
                    self._arm_deadline(idx)
                    self._sync_interests(idx)
                    continue
                if (
                    self._conns[idx].http2_failed()
                    and self._conns[idx].pending_remaining() == 0
                ):
                    self._close_conn(idx)
                    continue
                self._arm_deadline(idx)
                continue
            self._close_conn(idx)

    def _note_shutdown(mut self, now: Int) raises NetError:
        if self.control.is_shutdown_requested():
            if self._shutdown_at == NO_DEADLINE:
                self._shutdown_at = now + Int(self.config.shutdown_grace._value)
                self._drop_listener()
                if self._quic_endpoint:
                    self._quic_endpoint.value().begin_shutdown()
                    var delay = _QUIC_GOAWAY_DELAY_NS
                    var half_grace = Int(self.config.shutdown_grace._value) // 2
                    if half_grace < delay:
                        delay = half_grace
                    self._quic_finish_at = now + delay
                for i in range(len(self._conns)):
                    if (
                        not self._conns[i].active
                        or self._conns[i].protocol != PROTOCOL_HTTP2
                        or not self._conns[i].http2_session
                    ):
                        continue
                    var goaway = (
                        self._conns[i].http2_session.value().begin_shutdown()
                    )
                    if not self._conns[i].append_pending(goaway^, self._budget):
                        self._close_conn(i)
                        continue
                    self._conns[i].state = STATE_SENDING_HTTP2_CONTROL
                    self._conns[i].write_at = deadline_from_now(
                        self.config.write_deadline
                    )
                    # Wake the write path: without this, GOAWAY sits in pending
                    # until an unrelated read event arrives.
                    self._sync_interests(i)
                    self._push_urgent(i)
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

    def _finish_quic_shutdown_if_due(mut self, now: Int) raises NetError:
        if self._quic_finish_at != NO_DEADLINE and now >= self._quic_finish_at:
            self._finish_quic_shutdown()

    def _finish_quic_shutdown(mut self) raises NetError:
        if self._quic_finish_at == NO_DEADLINE:
            return
        if self._quic_endpoint:
            self._quic_endpoint.value().finish_shutdown()
            self._flush_quic()
        self._quic_finish_at = NO_DEADLINE

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

    def _drop_quic_endpoint(mut self):
        if self._quic_endpoint:
            _ = self._reactor.remove(self._quic_token)
            self._quic_endpoint = None
            self._quic_token = ReactorToken(slot=-1, generation=0)

    def _drive_quic(mut self) raises NetError:
        if not self._quic_endpoint:
            return
        # The QUIC descriptor is handled separately from HTTP connection slots.
        var received = 0
        while received < 16:
            if not self._quic_endpoint.value().try_receive():
                break
            received += 1
        var remaining = self._quic_endpoint.value().transport_timeout_micros()
        if remaining == 0:
            self._quic_endpoint.value().on_timeout()
        self._flush_quic()

    def _flush_quic(mut self) raises NetError:
        if not self._quic_endpoint:
            return
        var sent = 0
        while sent < 16:
            if not self._quic_endpoint.value().try_send():
                break
            sent += 1
        var want_write = self._quic_endpoint.value().wants_write()
        _ = self._reactor.modify(self._quic_token, True, want_write)

    def _dispatch_quic_requests[
        H: Handler
    ](mut self, mut handler: H) raises NetError:
        if not self._quic_endpoint:
            return
        var processed = 0
        while processed < self.config.max_requests_per_tick:
            var quic_request = self._quic_endpoint.value().try_next_request()
            if quic_request.id == 0:
                break
            var request_id = quic_request.id
            var is_head = quic_request.method == "HEAD"
            var target = quic_request.target.copy()
            var path, query = split_path_query(target)
            var request = Request(
                quic_request.method.copy(),
                target^,
                path^,
                query^,
                HttpVersion.http3(),
            )
            request.scheme = quic_request.scheme.copy()
            request.authority = quic_request.authority.copy()
            var response = ResponseWriter(self.config.max_response_body)
            var body_size = len(quic_request.body)
            if body_size > self.config.max_body_bytes:
                response.status = 413
            elif not self._budget.try_reserve(body_size):
                response.status = 503
            else:
                try:
                    for i in range(len(quic_request.headers)):
                        var name = quic_request.headers[i].name.copy()
                        request.headers.add_bytes(
                            name^, Span(quic_request.headers[i].value)
                        )
                    for i in range(len(quic_request.trailers)):
                        var name = quic_request.trailers[i].name.copy()
                        request.trailers.add_bytes(
                            name^, Span(quic_request.trailers[i].value)
                        )
                    request.body = quic_request.take_body()
                    try:
                        handler.handle(request^, response)
                    except e:
                        _ = e
                        response.status = 500
                        response.body.clear()
                except e:
                    _ = e
                    response.status = 400
                    response.body.clear()
                self._budget.release(body_size)
            if response.is_detached():
                response._cancel_detach()
                response.status = 500
                response.body.clear()
            if response.status < 100 or response.status > 599:
                response.status = 500
                response.body.clear()
            var response_header_bytes = 0
            for i in range(len(response.headers)):
                response_header_bytes += (
                    response.headers.name_at(i).byte_length()
                    + response.headers.value_byte_length(i)
                    + 4
                )
            if (
                len(response.headers) > self.config.max_response_headers_count
                or response_header_bytes
                > self.config.max_response_headers_bytes
            ):
                response.status = 500
                response.headers.clear()
                response.body.clear()
            var wire_length = -1
            if has_body_for_status(response.status, False):
                wire_length = len(response.body)
            if wire_length >= 0:
                var declared_lengths = response.headers.get_all(
                    "content-length"
                )
                for i in range(len(declared_lengths)):
                    if not _content_length_matches(
                        declared_lengths[i], wire_length
                    ):
                        response.status = 500
                        response.headers.clear()
                        response.body.clear()
                        wire_length = -1
                        break
            var headers = List[Byte]()
            var header_count = len(response.headers) - response.headers.count(
                "content-length"
            )
            if wire_length >= 0:
                header_count += 1
            _append_quic_u32(headers, UInt32(header_count))
            for i in range(len(response.headers)):
                if response.headers._lower_names[i] == "content-length":
                    continue
                _append_quic_field(
                    headers, response.headers._names[i].as_bytes()
                )
                _append_quic_field(
                    headers, response.headers._value_bytes_span(i)
                )
            if wire_length >= 0:
                var length = String(wire_length)
                _append_quic_field(headers, String("content-length").as_bytes())
                _append_quic_field(headers, length.as_bytes())
            var response_body = response.body^
            response.body = List[Byte]()
            if not has_body_for_status(response.status, is_head):
                response_body.clear()
            if (
                len(response_body) > self.config.max_response_body
                or len(headers) > self.config.max_response_headers_bytes
                or header_count > self.config.max_response_headers_count
            ):
                response.status = 500
                headers.clear()
                _append_quic_u32(headers, UInt32(0))
                response_body.clear()
            try:
                self._quic_endpoint.value().respond(
                    request_id,
                    response.status,
                    Span(headers),
                    Span(response_body),
                )
            except e:
                _ = e
            processed += 1

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
                var idle_at = deadline_from_now(self.config.idle_timeout)
                var entry: HttpConnection
                if self._tls_context:
                    if not self._budget.try_reserve(READ_BUFFER_SIZE):
                        _ = self._reactor.remove(token)
                        fresh.close()
                        accepted += 1
                        continue
                    try:
                        var secure = self._tls_context.value().accept(fresh^)
                        entry = HttpConnection(
                            token,
                            None,
                            Optional[TLSConnection](secure^),
                            idle_at,
                            NO_DEADLINE,
                            deadline_from_now(
                                self.config.tls_handshake_timeout
                            ),
                        )
                    except e:
                        _ = e
                        _ = self._reactor.remove(token)
                        self._budget.release(READ_BUFFER_SIZE)
                        accepted += 1
                        continue
                else:
                    entry = HttpConnection(
                        token,
                        Optional[TCPConn](fresh^),
                        None,
                        idle_at,
                        NO_DEADLINE,
                        NO_DEADLINE,
                    )
                var error_capacity = H1_ERROR_CAPACITY
                if entry.is_tls() and self.config.alt_svc.byte_length() > 0:
                    error_capacity += 11 + self.config.alt_svc.byte_length()
                if not entry._reserve_error_wire(
                    self._budget.copy(), error_capacity
                ):
                    var tls_capacity = entry.tls_read_buffer.capacity()
                    try:
                        entry.close()
                    except e:
                        _ = e
                    self._budget.release(tls_capacity)
                    _ = self._reactor.remove(token)
                    accepted += 1
                    continue
                self._ensure_slot_map(token.slot)
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
        self._discard_detached(idx)
        var token = self._conns[idx].token.copy()
        _ = self._reactor.remove(token)
        if token.slot >= 0 and token.slot < len(self._slot_map):
            if self._slot_map[token.slot] == idx:
                self._slot_map[token.slot] = -1
        if idx >= 0 and idx < len(self._urgent_flag):
            self._urgent_flag[idx] = False
        if idx < len(self._deadline_pos):
            var pos = self._deadline_pos[idx]
            if pos != -1:
                self._heap_remove(pos)
        # Release the whole pending reservation, not just the unsent
        # suffix: bytes already written were charged when queued, and
        # leaving the sent prefix charged would leak budget on every
        # partial-send close until unrelated requests see 503s. Any
        # admission reservation still held is released the same way.
        var wire_capacity = (
            self._conns[idx].buf.capacity()
            + self._conns[idx].pending.capacity()
            + self._conns[idx].tls_read_buffer.capacity()
        )
        self._budget.release(self._conns[idx].reserved)
        self._conns[idx].reserved = 0
        self._release_http1_body(idx)
        self._budget.release(self._conns[idx].http2_body_reserved)
        self._conns[idx].http2_body_reserved = 0
        self._budget.release(self._conns[idx].http2_response_bytes_reserved)
        self._conns[idx].http2_response_bytes_reserved = 0
        try:
            self._conns[idx].close()
        except e:
            _ = e
        self._budget.release(wire_capacity)
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
        self._release_http1_body(idx)
        self._discard_detached(idx)
        # TLS error responses also advertise Alt-Svc when configured,
        # matching the handler path (_inject_alt_svc_for_tls).
        var alt_svc = String("")
        if self._conns[idx].is_tls() and self.config.alt_svc.byte_length() > 0:
            try:
                _check_value_bytes(
                    self.config.alt_svc.as_bytes(), "encode error Alt-Svc"
                )
            except e:
                _ = e
                self._close_conn(idx)
                return
            alt_svc = self.config.alt_svc.copy()
        var capacity = _measure_error(
            status, True, self._tick_date, is_head, alt_svc
        )
        if capacity > self._conns[idx]._error_wire.capacity():
            self._close_conn(idx)
            return
        var wire = self._conns[idx]._take_error_wire()
        var byte_count = 0
        _render_error[False](
            status, True, self._tick_date, is_head, alt_svc, wire, byte_count
        )
        self._conns[idx]._set_reserved_pending(wire^, self._budget)
        self._conns[idx]._error_ticket.amount = 0
        self._conns[idx].should_close = True
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        self._sync_interests(idx)

    def _sync_interests(mut self, idx: Int) raises NetError:
        var want_read = self._conns[idx].wants_read()
        if (
            self._conns[idx].protocol == PROTOCOL_HTTP2
            and self._conns[idx].http2_failed()
            and self._conns[idx].pending_remaining() > 0
        ):
            # A failed HTTP/2 session is draining its GOAWAY: it never
            # consumes another byte, so only the flush is left. Ordinary
            # read interest stays true for STATE_SENDING_HTTP2_CONTROL, and
            # a level-triggered reactor would keep waking this connection on
            # attacker-controlled readability while the write is stuck. A
            # TLS write blocked on WANT_READ still needs a read event to
            # retry, and wants_write() drops write interest in that case.
            want_read = (
                self._conns[idx].tls_write_would_block
                and self._conns[idx].tls_write_wants_read
            )
        _ = self._reactor.modify(
            self._conns[idx].token,
            want_read,
            self._conns[idx].wants_write(),
        )

    def _drive_tls_handshake(mut self, idx: Int) raises NetError:
        try:
            var progress = self._conns[idx].tls.value().handshake()
            if progress.is_complete():
                var protocol = self._conns[idx].tls.value().selected_alpn()
                if protocol == "h2":
                    self._conns[idx]._drop_error_wire()
                    self._conns[idx].protocol = PROTOCOL_HTTP2
                    self._conns[idx].http2_session = Optional(
                        Http2RequestSession(
                            String(self.config.hpack_library_path),
                            self.config.max_http2_streams_per_connection,
                            self.config.max_body_bytes,
                            self.config.max_headers_bytes,
                            self.config.max_headers_count,
                            self.config.max_trailer_bytes,
                            self.config.max_trailer_count,
                            self.config.header_deadline,
                            self.config.body_deadline,
                            self.config.http2_max_control_frames_per_second,
                            self.config.http2_max_resets_per_second,
                            self.config.http2_max_new_streams_per_second,
                        )
                    )
                elif protocol != "http/1.1":
                    self._close_conn(idx)
                    return
                self._conns[idx].state = STATE_READING
                self._conns[idx].tls_handshake_at = NO_DEADLINE
                self._conns[idx].idle_at = deadline_from_now(
                    self.config.idle_timeout
                )
                if self._conns[idx].tls_pending() > 0:
                    self._conns[idx].more_work = True
                self._sync_interests(idx)
                return
            self._conns[idx].tls_handshake_wants_read = progress.is_wants_read()
            self._conns[
                idx
            ].tls_handshake_wants_write = progress.is_wants_write()
            self._sync_interests(idx)
        except e:
            _ = e
            self._close_conn(idx)

    def _drive_tls_shutdown(mut self, idx: Int) raises NetError:
        try:
            var progress = self._conns[idx].tls.value().shutdown()
            if progress.is_complete() or progress.is_sent_close_notify():
                self._close_conn(idx)
                return
            self._conns[
                idx
            ].tls_shutdown_wants_write = progress.is_wants_write()
            self._sync_interests(idx)
        except e:
            _ = e
            self._close_conn(idx)

    def _finish_connection(mut self, idx: Int) raises NetError:
        if not self._conns[idx].is_tls():
            self._close_conn(idx)
            return
        self._conns[idx].state = STATE_TLS_SHUTDOWN
        self._conns[idx].tls_shutdown_at = deadline_from_now(
            self.config.write_deadline
        )
        self._conns[idx].tls_shutdown_wants_write = False
        self._drive_tls_shutdown(idx)

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
        if self._conns[idx].state == STATE_HANDSHAKING:
            if (self._conns[idx].tls_handshake_wants_read and readable) or (
                self._conns[idx].tls_handshake_wants_write and writable
            ):
                self._drive_tls_handshake(idx)
            return
        if self._conns[idx].state == STATE_TLS_SHUTDOWN:
            if (self._conns[idx].tls_shutdown_wants_write and writable) or (
                not self._conns[idx].tls_shutdown_wants_write and readable
            ):
                self._drive_tls_shutdown(idx)
            return
        if self._conns[idx].protocol == PROTOCOL_HTTP2:
            if self._conns[idx].http2_session:
                var expired = self._conns[idx].http2_session.value().expire(now)
                if len(expired) > 0:
                    if not self._conns[idx].append_pending(
                        expired^, self._budget
                    ):
                        self._close_conn(idx)
                        return
                    self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
                    self._conns[idx].write_at = deadline_from_now(
                        self.config.write_deadline
                    )
            if (
                self._conns[idx].state == STATE_SENDING_HTTP2_CONTROL
                or self._conns[idx].pending_remaining() > 0
            ):
                self._pump_send(
                    idx, self._conns[idx].write_ready(readable, writable)
                )
                if not self._conns[idx].active:
                    return
            if (
                self._conns[idx].http2_failed()
                and self._conns[idx].pending_remaining() == 0
            ):
                self._close_conn(idx)
                return
            if self._conns[idx].http2_failed():
                # Failed session draining GOAWAY: flush pending output only.
                # Do not read or parse further bytes; the failed session can
                # never drain them and they would consume shared budget.
                # _sync_interests drops ordinary read interest here and keeps
                # only the readiness the flush needs, including the read
                # event a TLS write blocked on WANT_READ requires.
                self._sync_interests(idx)
                return
            if self._http2_drained(idx):
                self._close_conn(idx)
                return
            var read_event = (
                self._conns[idx].read_ready(readable, writable)
                or self._conns[idx].tls_pending() > 0
            )
            self._pump_read(idx, read_event, now)
            if not self._conns[idx].active:
                return
            var http2_activity = read_event
            while (
                self._conns[idx].active and self._conns[idx].buffered_len() > 0
            ):
                if (
                    self._conns[idx].requests_this_tick
                    >= self.config.max_requests_per_tick
                ):
                    self._conns[idx].more_work = True
                    break
                var buffered_before = self._conns[idx].buffered_len()
                self._pump_http2_input(idx, handler)
                http2_activity = True
                if not self._conns[idx].active:
                    return
                if self._conns[idx].state == STATE_SENDING_HTTP2_CONTROL:
                    self._pump_send(idx, True)
                    if not self._conns[idx].active:
                        return
                if (
                    self._conns[idx].http2_failed()
                    and self._conns[idx].pending_remaining() == 0
                ):
                    self._close_conn(idx)
                    return
                if self._conns[idx].buffered_len() >= buffered_before:
                    break
            if (
                self._conns[idx].read_eof
                and self._conns[idx].buffered_len() == 0
                and self._conns[idx].pending_remaining() == 0
                and self._conns[idx].http2_responses.queued_count() == 0
            ):
                self._close_conn(idx)
                return
            if (
                self._conns[idx].active
                and self._conns[idx].state == STATE_READING
                and self._conns[idx].pending_remaining() == 0
                and self._conns[idx].http2_responses.queued_count() == 0
                and http2_activity
            ):
                self._conns[idx].idle_at = deadline_from_now(
                    self.config.idle_timeout
                )
            self._sync_interests(idx)
            return
        if (
            self._conns[idx].state == STATE_SENDING
            or self._conns[idx].state == STATE_SENDING_100
            or self._conns[idx].state == STATE_STREAMING
        ):
            self._pump_send(
                idx, self._conns[idx].write_ready(readable, writable)
            )
            if not self._conns[idx].active:
                return
        if (
            self._conns[idx].state == STATE_DETACHED
            or self._conns[idx].state == STATE_STREAMING
        ):
            var read_event = self._conns[idx].read_ready(readable, writable)
            if read_event:
                self._pump_read(idx, read_event, now)
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
            var read_event = (
                self._conns[idx].read_ready(readable, writable)
                or self._conns[idx].tls_pending() > 0
            )
            self._pump_read(idx, read_event, now)
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

    def _pump_http2_input[
        H: Handler
    ](mut self, idx: Int, mut handler: H) raises NetError:
        while self._conns[idx].active and self._conns[idx].buffered_len() > 0:
            var result: Http2RequestSessionResult
            try:
                result = (
                    self._conns[idx]
                    .http2_session.value()
                    .consume(Span(self._conns[idx].buf))
                )
            except e:
                _ = e
                self._close_conn(idx)
                return
            if result.is_error():
                if self._conns[idx].pending_remaining() > 0:
                    self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
                    self._conns[idx].write_at = deadline_from_now(
                        self.config.write_deadline
                    )
                    self._pump_send(idx, True)
                    return
                self._close_conn(idx)
                return
            if result.consumed > 0:
                self._consume_receive(idx, result.consumed)
            if result.reset_stream_id != UInt32(0):
                var reset_result = self._conns[
                    idx
                ].http2_responses.on_peer_reset(result.reset_stream_id)
                self._budget.release(reset_result.released_bytes)
                self._conns[
                    idx
                ].http2_response_bytes_reserved -= reset_result.released_bytes
            var request_body_bytes = 0
            if result.is_request():
                request_body_bytes = len(result.request.body)
            var target_body_reservation = (
                self._conns[idx].http2_session.value().buffered_request_bytes()
                + request_body_bytes
            )
            if target_body_reservation > self._conns[idx].http2_body_reserved:
                var additional = (
                    target_body_reservation
                    - self._conns[idx].http2_body_reserved
                )
                if not self._budget.try_reserve(additional):
                    self._close_conn(idx)
                    return
            elif target_body_reservation < self._conns[idx].http2_body_reserved:
                self._budget.release(
                    self._conns[idx].http2_body_reserved
                    - target_body_reservation
                )
            self._conns[idx].http2_body_reserved = target_body_reservation
            if result.is_request():
                self._respond_http2(idx, result^, request_body_bytes, handler)
                return
            if len(result.output) > 0:
                var output = result.output^
                result.output = List[Byte]()
                if not self._conns[idx].append_pending(output^, self._budget):
                    self._close_conn(idx)
                    return
                self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
                self._conns[idx].write_at = deadline_from_now(
                    self.config.write_deadline
                )
                self._pump_send(idx, True)
                return
            if result.is_pending():
                self._drain_http2_responses(idx)
                return

    def _respond_http2[
        H: Handler
    ](
        mut self,
        idx: Int,
        var result: Http2RequestSessionResult,
        request_body_bytes: Int,
        mut handler: H,
    ) raises NetError:
        var stream_id = result.stream_id
        var control_output = result.output^
        result.output = List[Byte]()
        var request = result^.take_request()
        var is_head = request.method == "HEAD"
        var cap = self.config.max_response_body
        var room = (
            self._budget.remaining()
            - len(control_output)
            - self.config.max_response_headers_bytes
            - 16384
            - 256
        )
        if room < cap:
            cap = room
        if cap < 0:
            cap = 0
        var writer = ResponseWriter(cap)
        self._conns[idx].requests_this_tick += 1
        self._conns[idx].requests_served += 1
        try:
            handler.handle(request^, writer)
        except e:
            _ = e
            writer.set_status(500)
            writer.headers.clear()
            writer.body.clear()

        self._budget.release(request_body_bytes)
        self._conns[idx].http2_body_reserved -= request_body_bytes

        if writer.is_detached():
            # Streaming/SSE on HTTP/2 would need per-stream credit tracking
            # that the shared H1 writer cannot express; keep siblings alive by
            # falling back to a stream-level 500 instead of closing.
            writer._cancel_detach()
            writer.set_status(500)
            writer.headers.clear()
            writer.body.clear()
        if len(writer.body) > cap:
            writer.set_status(500)
            writer.headers.clear()
            writer.body.clear()

        try:
            self._inject_alt_svc_for_tls(idx, writer)
        except e:
            _ = e
            self._close_conn(idx)
            return

        if not self._conns[idx].http2_deflater:
            try:
                var table_size = _bounded_hpack_table_size(
                    self._conns[idx]
                    .http2_session.value()
                    .peer_settings()
                    .header_table_size
                )
                self._conns[idx].http2_deflater = Optional(
                    Http2HpackDeflater(
                        String(self.config.hpack_library_path), table_size
                    )
                )
            except e:
                _ = e
                self._close_conn(idx)
                return
        else:
            var table_size = _bounded_hpack_table_size(
                self._conns[idx]
                .http2_session.value()
                .peer_settings()
                .header_table_size
            )
            if (
                not self._conns[idx]
                .http2_deflater.value()
                .set_max_table_size(table_size)
            ):
                self._close_conn(idx)
                return

        var available = self._budget.remaining() - len(control_output)
        var max_response_header_bytes = self.config.max_response_headers_bytes
        var peer_header_list_size = Int(
            self._conns[idx]
            .http2_session.value()
            .peer_settings()
            .max_header_list_size
        )
        if peer_header_list_size < max_response_header_bytes:
            max_response_header_bytes = peer_header_list_size
        var compressed_capacity = max_response_header_bytes
        if compressed_capacity < 256:
            compressed_capacity = 256
        var compressed = List[Byte](length=compressed_capacity, fill=0)
        var encoded = encode_http2_response_header_frames(
            self._conns[idx].http2_deflater.value(),
            writer,
            is_head,
            self._tick_date,
            stream_id,
            max_response_header_bytes,
            self.config.max_response_headers_count,
            16384,
            available,
            Span(compressed),
        )
        if not encoded.is_complete():
            if self._conns[idx].http2_deflater.value().is_failed():
                # Deflater state is poisoned; the whole connection must close.
                self._close_conn(idx)
                return
            # Headers failed before HPACK ran (bad field or over the peer's
            # SETTINGS_MAX_HEADER_LIST_SIZE); retry a minimal 500 so sibling
            # streams on the same connection stay alive.
            writer.set_status(500)
            writer.headers.clear()
            writer.body.clear()
            encoded = encode_http2_response_header_frames(
                self._conns[idx].http2_deflater.value(),
                writer,
                is_head,
                self._tick_date,
                stream_id,
                max_response_header_bytes,
                self.config.max_response_headers_count,
                16384,
                available,
                Span(compressed),
            )
            if not encoded.is_complete():
                if self._conns[idx].http2_deflater.value().is_failed():
                    self._close_conn(idx)
                    return
                self._refuse_http2_stream(idx, stream_id, UInt32(2))
                return

        var end_on_headers = http2_response_end_on_headers(writer, is_head)
        var response_body = writer.body^
        writer.body = List[Byte]()
        if not has_body_for_status(writer.status, is_head):
            response_body.clear()
        var headers_wire = encoded.wire^
        encoded.wire = List[Byte]()
        var response_reservation = len(headers_wire) + len(response_body)
        if not self._budget.try_reserve(response_reservation):
            self._refuse_http2_stream(idx, stream_id, UInt32(7))
            return
        if not self._conns[idx].http2_responses.enqueue(
            stream_id, headers_wire^, response_body^, end_on_headers
        ):
            self._budget.release(response_reservation)
            self._refuse_http2_stream(idx, stream_id, UInt32(7))
            return
        self._conns[idx].http2_response_bytes_reserved += response_reservation
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        if len(control_output) > 0:
            if not self._conns[idx].append_pending(
                control_output^, self._budget
            ):
                self._close_conn(idx)
                return
            self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
        self._drain_http2_responses(idx)

    def _http2_drained(self, idx: Int) -> Bool:
        if not self._conns[idx].http2_session:
            return False
        if not self._conns[idx].http2_session.value().is_draining():
            return False
        return (
            self._conns[idx].pending_remaining() == 0
            and self._conns[idx].http2_responses.queued_count() == 0
            and not self._conns[idx].http2_session.value().has_active_streams()
        )

    def _refuse_http2_stream(
        mut self, idx: Int, stream_id: UInt32, error_code: UInt32
    ) raises NetError:
        var frame = (
            self._conns[idx]
            .http2_session.value()
            .refuse_stream(stream_id, error_code)
        )
        if len(frame) == 0:
            return
        if not self._conns[idx].append_pending(frame^, self._budget):
            self._close_conn(idx)
            return
        self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )

    def _drain_http2_responses(mut self, idx: Int) raises NetError:
        if (
            not self._conns[idx].active
            or self._conns[idx].pending_remaining() > 0
        ):
            return
        var batch = self._conns[idx].http2_responses.drain(
            self._conns[idx].http2_session.value(), 16384, 65536
        )
        if batch.released_bytes > 0:
            self._budget.release(batch.released_bytes)
            self._conns[
                idx
            ].http2_response_bytes_reserved -= batch.released_bytes
        if len(batch.wire) == 0:
            if self._conns[idx].http2_responses.queued_count() > 0:
                # Still waiting for WINDOW_UPDATE credit; keep the write
                # deadline so stalled responses cannot pin budget forever.
                if self._conns[idx].write_at == NO_DEADLINE:
                    self._conns[idx].write_at = deadline_from_now(
                        self.config.write_deadline
                    )
                self._conns[idx].state = STATE_READING
                return
            self._conns[idx].state = STATE_READING
            self._conns[idx].write_at = NO_DEADLINE
            self._conns[idx].idle_at = deadline_from_now(
                self.config.idle_timeout
            )
            return
        var output = batch.wire^
        batch.wire = List[Byte]()
        if not self._conns[idx].append_pending(output^, self._budget):
            self._close_conn(idx)
            return
        self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
        # Preserve the deadline armed when the response was enqueued so a
        # peer cannot extend it forever by dribbling credit between batches.
        if self._conns[idx].write_at == NO_DEADLINE:
            self._conns[idx].write_at = deadline_from_now(
                self.config.write_deadline
            )

    def _pump_read(mut self, idx: Int, event: Bool, now: Int) raises NetError:
        if not event:
            return
        if self._conns[idx].read_eof:
            return
        var scratch = Array[Byte, READ_BUFFER_SIZE](fill=0)
        while True:
            var room = (
                self.config.max_bytes_per_tick
                - self._conns[idx].bytes_this_tick
            )
            if room <= 0:
                break
            var limit = room if room < READ_BUFFER_SIZE else READ_BUFFER_SIZE
            if self._conns[idx].tls_read_retry_length > limit:
                self._conns[idx].more_work = True
                break
            try:
                var count = self._conns[idx].try_read_into(
                    Span(scratch)[0:limit]
                )
                if count == 0:
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
                if not self._charge_read(idx, count):
                    self._admit_over_budget(idx)
                    return
                var first = self._conns[idx].buffered_len() == 0
                self._conns[idx].append_bytes(Span(scratch)[0:count])
                self._conns[idx].bytes_this_tick += count
                if first:
                    self._conns[idx].header_at = deadline_from_now(
                        self.config.header_deadline
                    )
                if count < limit:
                    break
            except e:
                if e.kind == NetErrorKind.timeout():
                    break
                self._close_conn(idx)
                return

    def _charge_read(mut self, idx: Int, count: Int) -> Bool:
        return _reserve_capacity(
            self._conns[idx].buf,
            self._budget,
            self._conns[idx].buffered_len() + count,
            self._conns[idx].reserved,
        )

    def _consume_receive(mut self, idx: Int, count: Int):
        var old_capacity = self._conns[idx].buf.capacity()
        self._conns[idx].drain_prefix(count)
        self._budget.release(old_capacity - self._conns[idx].buf.capacity())

    def _advance_head(mut self, idx: Int) -> Int:
        """Resumes the head scan and caches the parsed head once complete.
        Returns the error status for a rejected head, else 0."""
        var progress = self._conns[idx].request_scan
        var scan = _scan_head(
            Span(self._conns[idx].buf),
            self.config,
            progress.head_wire,
            progress.head_bytes,
            progress.head_lines,
            progress.in_headers,
        )
        if scan.is_error():
            return scan.status
        if scan.is_complete():
            var head = parse_head(Span(self._conns[idx].buf), self.config)
            if head.is_error():
                return head.take_error().status
            if head.is_complete():
                progress.body_wire = head.head.header_end
                self._conns[idx].request_head = head^
        self._conns[idx].request_scan = progress
        return 0

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
            if not self._conns[idx].request_head:
                var head_status = self._advance_head(idx)
                if head_status != 0:
                    self._send_error(idx, head_status)
                    return
                if not self._conns[idx].request_head:
                    if self._conns[idx].read_eof:
                        self._close_conn(idx)
                        return
                    break
            var header_end = (
                self._conns[idx].request_head.value().head.header_end
            )
            var content_length = (
                self._conns[idx].request_head.value().head.content_length
            )
            if content_length > 0 and self._conns[idx].http1_body_reserved == 0:
                if not self._budget.try_reserve(content_length):
                    self._send_error(idx, 503)
                    return
                self._conns[idx].http1_body_reserved = content_length
            var outstanding = max(
                0,
                header_end + content_length - self._conns[idx].buf.capacity(),
            )
            var unreserved = self._budget.used() - self._conns[idx].reserved
            if (
                content_length > 0
                and unreserved + outstanding > self._budget.total()
            ):
                self._send_error(idx, 503)
                return
            # Preserve capacity for admitted bodies before other connections compete.
            if outstanding > 0 and self._conns[idx].reserved == 0:
                if not self._budget.try_reserve(outstanding):
                    self._send_error(idx, 503)
                    return
                self._conns[idx].reserved += outstanding
            if (
                self._conns[idx].request_head.value().head.expect_100
                and not self._conns[idx].sent_100
            ):
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
            if self._conns[idx].request_head.value().head.chunked:
                var progress = self._conns[idx].request_scan
                var scan = _scan_chunked(
                    Span(self._conns[idx].buf),
                    self.config,
                    progress.body_wire,
                    progress.body_meta,
                    progress.body_decoded,
                )
                self._conns[idx].request_scan = progress
                if scan.is_error():
                    self._send_error(idx, scan.error.status)
                    return
                if scan.is_need_more():
                    if self._conns[idx].read_eof:
                        self._close_conn(idx)
                        return
                    break
                if not self._budget.try_reserve(scan.decoded):
                    self._send_error(idx, 503)
                    return
                self._conns[idx].http1_body_reserved = scan.decoded
            elif (
                header_end + max(content_length, 0)
                > self._conns[idx].buffered_len()
            ):
                if self._conns[idx].read_eof:
                    self._close_conn(idx)
                    return
                break
            var head = self._conns[idx].request_head.take()
            self._conns[idx].request_scan = _RequestScan.start()
            var result = parse_body(
                head^, Span(self._conns[idx].buf), self.config
            )
            if result.is_need_more():
                if self._conns[idx].read_eof:
                    self._close_conn(idx)
                    return
                break
            if result.is_error():
                var body_status = result.take_error().status
                self._send_error(idx, body_status)
                return
            var req_close = result.should_close
            var consumed = result.consumed
            self._consume_receive(idx, consumed)
            self._conns[idx].requests_this_tick += 1
            self._respond(idx, result^, req_close, handler)
            if not self._conns[idx].active:
                return
            if self._conns[idx].state != STATE_READING:
                break

    def _send_100(mut self, idx: Int) raises NetError -> Bool:
        comptime CONTINUE: StaticString = "HTTP/1.1 100 Continue\r\n\r\n"
        var cont = CONTINUE.as_bytes()
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
            var written = 0
            try:
                written = self._conns[idx].try_write_bytes(cont[0:first])
            except e:
                if e.kind != NetErrorKind.timeout():
                    raise e^
            if self._conns[idx].tls_write_closed:
                self._close_conn(idx)
                return False
            self._conns[idx].bytes_this_tick += written
            if written < len(cont):
                var capacity = len(cont) - written
                if not self._budget.try_reserve(capacity):
                    self._close_conn(idx)
                    return False
                var rest = List[Byte](capacity=capacity)
                rest.extend(cont[written:])
                self._conns[idx]._set_reserved_pending(rest^, self._budget)
                self._conns[idx].state = STATE_SENDING_100
                self._conns[idx].write_at = deadline_from_now(
                    self.config.write_deadline
                )
                self._sync_interests(idx)
                return False
        except e:
            _ = e
            self._close_conn(idx)
            return False
        self._conns[idx].sent_100 = True
        return True

    def _release_http1_body(mut self, idx: Int):
        self._budget.release(self._conns[idx].http1_body_reserved)
        self._conns[idx].http1_body_reserved = 0

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
        if self._conns[idx].is_tls():
            req.scheme = String("https")
        var is_head = req.method == "HEAD"
        self._conns[idx].is_head = is_head
        # Keep a framing margin when advertising the body limit.
        var workspace = self._budget.remaining()
        var cap = self.config.max_response_body
        var room = workspace - 256
        if room < cap:
            cap = room
        if cap < 0:
            cap = 0
        var writer = ResponseWriter(
            cap,
            slot=idx,
            generation=self._conns[idx].token.generation,
            wakeup_fd=self._wakeup_channel.write_fd(),
            queue_limit=self.config.stream_queue_limit,
        )
        writer._set_body_budget(self._budget.copy())
        # The wire must advertise close whenever the connection will not
        # persist, even when the handler leaves the writer untouched.
        if req_close or self._shutdown_at != NO_DEADLINE:
            writer.set_should_close(True)
        try:
            handler.handle(req, writer)
        except e:
            _ = e
            _ = req^
            self._release_http1_body(idx)
            if writer.is_detached():
                writer._cancel_detach()
            writer._drop_body()
            writer._drop_headers()
            self._send_error(idx, 500, is_head=is_head)
            return

        _ = req^
        self._release_http1_body(idx)
        if writer.is_detached():
            writer._drop_body()
            writer._drop_headers()
            var addr = writer._detach_state_addr
            if addr == 0:
                self._send_error(idx, 500, is_head=is_head)
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

        if (
            len(writer.body) > cap
            or not writer._reconcile_body_budget()
            or not writer.headers._adopt_capacity_budget(
                writer._body_budget.copy()
            )
        ):
            writer._drop_body()
            writer._drop_headers()
            self._send_error(idx, 500, is_head=is_head)
            return
        # Header count/bytes are enforced inside the encoder, the single
        # authoritative site; its failure below becomes a 500 the same way.
        try:
            self._inject_alt_svc_for_tls(idx, writer)
        except e:
            _ = e
            writer._drop_body()
            writer._drop_headers()
            self._send_error(idx, 500, is_head=is_head)
            return
        var wire: List[Byte]
        try:
            wire = _encode_response_budgeted(
                writer,
                is_head,
                self._tick_date,
                self.config.max_response_headers_count,
                self.config.max_response_headers_bytes,
                self._budget,
            )
        except e:
            _ = e
            writer._drop_body()
            writer._drop_headers()
            self._send_error(idx, 500, is_head=is_head)
            return
        writer._drop_body()
        self._conns[idx]._set_reserved_pending(wire^, self._budget)
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

    def _complete_stream(mut self, idx: Int) raises NetError:
        self._cleanup_detached_state(idx)
        self._remove_detached_conn(idx)
        self._conns[idx].stream_finished = False
        self._conns[idx].stream_has_body = False
        self._conns[idx].detach_at = NO_DEADLINE
        self._conns[idx].requests_served += 1
        if self._conns[idx].should_close or self._shutdown_at != NO_DEADLINE:
            self._finish_connection(idx)
            return
        self._conns[idx].state = STATE_READING
        self._conns[idx].is_head = False
        self._conns[idx].sent_100 = False
        self._conns[idx].body_at = NO_DEADLINE
        self._conns[idx].write_at = NO_DEADLINE
        if self._conns[idx].buffered_len() > 0:
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

    def _pump_send(mut self, idx: Int, event: Bool) raises NetError:
        if not self._conns[idx].active:
            return
        if self._conns[idx].pending_remaining() == 0:
            if (
                self._conns[idx].state == STATE_STREAMING
                and self._conns[idx].stream_finished
            ):
                self._complete_stream(idx)
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
                if self._conns[idx].tls_write_closed:
                    self._close_conn(idx)
                    return
                if self._conns[idx].tls_write_would_block:
                    break
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
        var sent_capacity = self._conns[idx].pending.capacity()
        var was_http2_control = (
            self._conns[idx].state == STATE_SENDING_HTTP2_CONTROL
        )
        var was_100 = self._conns[idx].state == STATE_SENDING_100
        var was_streaming = self._conns[idx].state == STATE_STREAMING
        self._conns[idx].clear_pending()
        self._budget.release(sent_capacity)
        if was_http2_control:
            self._conns[idx].state = STATE_READING
            if self._conns[idx].http2_responses.queued_count() == 0:
                self._conns[idx].write_at = NO_DEADLINE
                self._conns[idx].idle_at = deadline_from_now(
                    self.config.idle_timeout
                )
            if self._conns[idx].http2_failed():
                # Flooded session: the control flush (ACK + ENHANCE_YOUR_CALM
                # GOAWAY) is all the peer will get. Do not schedule more
                # application responses; the connection closes once pending
                # output reaches zero.
                return
            self._drain_http2_responses(idx)
            return
        if was_100:
            self._conns[idx].state = STATE_READING
            self._conns[idx].sent_100 = True
            return
        if was_streaming:
            if not self._conns[idx].stream_finished:
                self._conns[idx].write_at = NO_DEADLINE
                self._conns[idx].detach_at = deadline_from_now(
                    self.config.stream_idle_timeout
                )
                return
            self._complete_stream(idx)
            return
        self._conns[idx].requests_served += 1
        if self._conns[idx].should_close or self._shutdown_at != NO_DEADLINE:
            self._finish_connection(idx)
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
            var s_ptr = _detach_state(addr)
            s_ptr[].mutex.lock()
            s_ptr[].cancelled = True
            s_ptr[].finished = True
            s_ptr[].messages = List[DetachMessage]()
            s_ptr[].array_ticket.release()
            s_ptr[].queued_bytes = 0
            s_ptr[].terminal_kind = MSG_KIND_NONE
            s_ptr[].mutex.unlock()

    def _cleanup_detached_state(mut self, idx: Int):
        if idx < 0 or idx >= len(self._conns):
            return
        var addr = self._conns[idx].detach_state_addr
        if addr != 0:
            self._conns[idx].detach_state_addr = 0
            self._conns[idx].detach_at = NO_DEADLINE
            _release_detach_state(addr, from_sender=False)

    def _discard_detached(mut self, idx: Int):
        if self._conns[idx].detach_state_addr != 0:
            self._mark_detached_cancelled(idx)
            self._cleanup_detached_state(idx)
            self._remove_detached_conn(idx)

    def _fail_detached(
        mut self, idx: Int, is_head: Bool, mut rw: ResponseWriter
    ) raises NetError:
        rw._drop_headers()
        self._send_error(idx, 500, is_head=is_head)
        self._arm_deadline(idx)

    def _remove_detached_conn(mut self, idx: Int):
        for i in range(len(self._detached_conns)):
            if self._detached_conns[i] == idx:
                _ = self._detached_conns.pop(i)
                break

    def _handle_detached_timeout(mut self, idx: Int) raises NetError:
        if self._conns[idx].state == STATE_STREAMING:
            self._close_conn(idx)
            return
        self._send_error(idx, 503, is_head=self._conns[idx].is_head)
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
                or (
                    self._conns[idx].state != STATE_DETACHED
                    and self._conns[idx].state != STATE_STREAMING
                )
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

            var batch = _take_batch(_detach_state(addr))
            if (
                len(batch.messages) == 0
                and batch.terminal_kind == MSG_KIND_NONE
            ):
                i += 1
                continue

            batch.messages.reverse()
            while len(batch.messages) > 0:
                var msg = batch.messages.pop()
                if not self._conns[idx].active:
                    break
                if self._conns[idx].detach_state_addr != addr:
                    break
                if self._conns[idx].token.generation != batch.generation:
                    self._mark_detached_cancelled(idx)
                    if self._conns[idx].detach_state_addr == addr:
                        self._cleanup_detached_state(idx)
                    break
                if msg.kind == MSG_KIND_RESPOND:
                    self._handle_detached_respond(idx, msg)
                    break
                elif msg.kind == MSG_KIND_START:
                    self._handle_detached_start(idx, msg)
                elif msg.kind == MSG_KIND_CHUNK:
                    self._handle_detached_chunk(idx, msg)
                else:
                    self._handle_detached_abort(idx)
                    break

            if (
                batch.terminal_kind != MSG_KIND_NONE
                and self._conns[idx].active
                and self._conns[idx].detach_state_addr == addr
                and self._conns[idx].token.generation == batch.generation
            ):
                if batch.terminal_kind == MSG_KIND_FINISH:
                    self._handle_detached_finish(idx)
                else:
                    self._handle_detached_abort(idx)

            if not self._conns[idx].active:
                if (
                    i < len(self._detached_conns)
                    and self._detached_conns[i] == idx
                ):
                    _ = self._detached_conns.pop(i)
                continue

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

            if i < len(self._detached_conns) and self._detached_conns[i] == idx:
                if (
                    not self._conns[idx].active
                    or self._conns[idx].detach_state_addr == 0
                    or self._conns[idx].state == STATE_READING
                    or self._conns[idx].state == STATE_SENDING
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
            self._fail_detached(idx, is_head, rw)
            return

        try:
            self._inject_alt_svc_for_tls(idx, rw)
        except e:
            _ = e
            self._fail_detached(idx, is_head, rw)
            return

        var wire: List[Byte]
        try:
            wire = _encode_response_budgeted(
                rw,
                is_head,
                self._tick_date,
                self.config.max_response_headers_count,
                self.config.max_response_headers_bytes,
                self._budget,
            )
        except e:
            _ = e
            self._fail_detached(idx, is_head, rw)
            return

        self._conns[idx]._set_reserved_pending(wire^, self._budget)

        self._cleanup_detached_state(idx)
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

    def _handle_detached_start(
        mut self, idx: Int, mut msg: DetachMessage
    ) raises NetError:
        var is_head = self._conns[idx].is_head
        var req_close = self._conns[idx].req_close or msg.should_close
        var rw = ResponseWriter(self.config.max_response_body)
        rw.status = msg.status
        var h = msg.headers^
        msg.headers = Headers()
        rw.headers = h^
        rw.set_should_close(req_close or (self._shutdown_at != NO_DEADLINE))

        try:
            self._inject_alt_svc_for_tls(idx, rw)
        except e:
            _ = e
            self._fail_detached(idx, is_head, rw)
            return

        var wire: List[Byte]
        try:
            wire = _encode_chunked_start_budgeted(
                rw,
                is_head,
                self._tick_date,
                self.config.max_response_headers_count,
                self.config.max_response_headers_bytes,
                self._budget,
            )
        except e:
            _ = e
            self._fail_detached(idx, is_head, rw)
            return

        if not self._conns[idx]._append_reserved_pending(wire^, self._budget):
            self._fail_detached(idx, is_head, rw)
            return

        self._conns[idx].state = STATE_STREAMING
        self._conns[idx].stream_finished = False
        self._conns[idx].stream_has_body = (
            not is_head
        ) and has_body_for_status(msg.status, False)
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
        self._conns[idx].detach_at = deadline_from_now(
            self.config.stream_idle_timeout
        )

    def _handle_detached_chunk(
        mut self, idx: Int, mut msg: DetachMessage
    ) raises NetError:
        if not self._conns[idx].active:
            return
        if self._conns[idx].state != STATE_STREAMING:
            return
        if self._conns[idx].stream_finished:
            return
        if len(msg.body) == 0:
            return
        if not self._conns[idx].stream_has_body:
            return

        var wire: List[Byte]
        try:
            wire = _encode_chunk_budgeted(Span(msg.body), self._budget)
        except e:
            _ = e
            self._handle_detached_abort(idx)
            return
        if not self._conns[idx]._append_reserved_pending(wire^, self._budget):
            self._close_conn(idx)
            return

        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        self._conns[idx].detach_at = deadline_from_now(
            self.config.stream_idle_timeout
        )

    def _handle_detached_finish(mut self, idx: Int) raises NetError:
        if not self._conns[idx].active:
            return
        if self._conns[idx].state != STATE_STREAMING:
            return
        if self._conns[idx].stream_finished:
            return
        self._conns[idx].stream_finished = True
        if not self._conns[idx].stream_has_body:
            return

        var wire: List[Byte]
        try:
            wire = _encode_chunk_end_budgeted(self._budget)
        except e:
            _ = e
            self._handle_detached_abort(idx)
            return
        if not self._conns[idx]._append_reserved_pending(wire^, self._budget):
            self._close_conn(idx)
            return

        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        self._conns[idx].detach_at = deadline_from_now(
            self.config.stream_idle_timeout
        )

    def _handle_detached_abort(mut self, idx: Int) raises NetError:
        if self._conns[idx].state == STATE_STREAMING:
            self._close_conn(idx)
            return
        self._cleanup_detached_state(idx)
        self._remove_detached_conn(idx)
        self._send_error(idx, 500, is_head=self._conns[idx].is_head)
        self._arm_deadline(idx)

    def _compute_timeout(
        mut self, now: Int, timeout: Optional[Timeout]
    ) raises NetError -> Optional[Timeout]:
        var explicit = _Deadline_from_optional_ms(timeout)
        var best = _TICK_POLL_CAP_MS
        if explicit < best:
            best = explicit
        if self._quic_endpoint:
            var quic_timeout = self._quic_endpoint.value().timeout_micros()
            if quic_timeout != UInt64.MAX:
                var quic_ms = Int((quic_timeout + 999) // 1000)
                if quic_ms < best:
                    best = quic_ms
        if (
            self._shutdown_at != NO_DEADLINE
            and self._quic_close_at == NO_DEADLINE
        ):
            var left_ms = (self._shutdown_at - now) // 1_000_000
            if left_ms < 0:
                left_ms = 0
            if left_ms < best:
                best = Int(left_ms)
        if self._quic_close_at != NO_DEADLINE:
            best = _sooner(best, self._quic_close_at, now)
        while len(self._deadline_heap) > 0:
            var top = self._deadline_heap[0]
            var mark = self._next_deadline(top.idx)
            if mark != top.deadline:
                self._arm_deadline(top.idx)
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


def _append_quic_u32(mut output: List[Byte], value: UInt32):
    output.append(Byte((value >> 24) & UInt32(0xFF)))
    output.append(Byte((value >> 16) & UInt32(0xFF)))
    output.append(Byte((value >> 8) & UInt32(0xFF)))
    output.append(Byte(value & UInt32(0xFF)))


def _append_quic_field[
    origin: Origin
](mut output: List[Byte], value: Span[Byte, origin]):
    _append_quic_u32(output, UInt32(len(value)))
    output.extend(value)


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
    control: ServerControl,
) raises:
    """Binds `address` and serves using a shared shutdown handle."""
    try:
        var server = Server(config^)
        var listener = listen_tcp(address)
        server.serve_with_control(listener^, handler, control)
    except error:
        control.mark_exited()
        raise error
