"""Single event-loop HTTP/1.1 origin server (epoll/kqueue).

The loop owns one listener and a table of connections. Handler code runs
synchronously on the loop thread: blocking I/O or long CPU work inside a
handler stalls every connection, so handlers must stay small and fast.
ServerPool composes independent Server instances for multiple CPU cores.
Heavy-handler offload is a later design.

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

from std.sys import size_of

from net import SocketAddress, TCPConn, TCPListener, Timeout, listen_tcp
from net._actor import WakeupChannel
from net._reactor import Reactor, ReactorToken
from net.error import NetError, NetErrorKind
from net.quic import QuicUDPEndpoint, QuicBodyReadState

from ._buffer import SharedBufferBudget, _CapacityTicket, _reserve_capacity
from ._body_decoder import _BodyDecoder
from ._body_pipe import _BodyPipe
from ._control import ServerControl
from ._hijack import (
    _hijack_state,
    _cancel_hijack_state,
    _complete_hijack_state,
    _release_hijack_state,
)
from ._connection import (
    HttpConnection,
    PROTOCOL_HTTP2,
    STATE_DETACHED,
    STATE_HANDSHAKING,
    STATE_HIJACKING_FLUSH,
    STATE_HIJACKED,
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
    _mark_detach_cancelled,
    _consume_detach_bytes,
    _detach_state,
    _DetachTarget,
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
    _split_comma_tokens,
    parse_body,
    parse_head,
    _split_comma_tokens,
)
from .config import ServerConfig
from .handler import Handler
from .headers import (
    Headers,
    _check_value_bytes,
    _trailer_forbidden,
    _declared_content_length,
)
from .response import (
    ResponseWriter,
    _HijackContext,
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
from net.http._http2.response_headers import (
    _content_length_matches,
    encode_http2_response_headers,
    _append_field,
    encode_http2_minimal_500_fields,
    encode_http2_response_trailers,
)
from net.http._http2.control_frames import encode_rst_stream_frame
from net.http._http2.frame_encoder import encode_frame


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


@fieldwise_init
struct _Http2DetachedStream(Movable):
    var target: _DetachTarget
    var addr: Int
    var deadline: Int
    var is_head: Bool
    var status: Int
    var allows_body: Bool
    var initial_field_count: Int
    var initial_field_bytes: Int
    var headers: Headers

    def __deinit__(deinit self):
        if self.addr != 0:
            _cancel_detach_state(self.addr)


@fieldwise_init
struct _Http3RequestInput(Movable):
    var request_id: UInt64
    var pipe: _BodyPipe
    var wire_eof: Bool
    var eof_published: Bool
    var eof_admission_at: Int
    var trailers: Headers

    def __deinit__(deinit self):
        if not self.pipe.is_eof():
            self.pipe.cancel()
        self.pipe._stop_loop_wakeup()


struct _Http3DetachedStream(Movable):
    var target: _DetachTarget
    var addr: Int
    var deadline: Int
    var is_head: Bool
    var started: Bool
    var allows_body: Bool
    var initial_field_count: Int
    var initial_field_bytes: Int
    var chunks: List[DetachMessage]
    var chunk_head: Int
    var body_offset: Int
    var chunks_ticket: _CapacityTicket
    var finished: Bool
    var finish_sent: Bool
    var trailers: Headers

    def __init__(
        out self,
        request_id: UInt64,
        addr: Int,
        deadline: Int,
        is_head: Bool,
        var budget: SharedBufferBudget,
    ):
        self.target = _DetachTarget.http3(request_id)
        self.addr = addr
        self.deadline = deadline
        self.is_head = is_head
        self.started = False
        self.allows_body = True
        self.initial_field_count = 0
        self.initial_field_bytes = 0
        self.chunks = List[DetachMessage]()
        self.chunk_head = 0
        self.body_offset = 0
        self.chunks_ticket = _CapacityTicket(budget^)
        self.finished = False
        self.finish_sent = False
        self.trailers = Headers()

    def __deinit__(deinit self):
        if self.addr != 0:
            _cancel_detach_state(self.addr)
        _ = self.chunks^
        self.chunks_ticket.release()

    def push(
        mut self, mut msg: DetachMessage, mut budget: SharedBufferBudget
    ) -> Bool:
        if self.chunk_head > 0 and self.chunk_head * 2 >= len(self.chunks):
            var remaining = len(self.chunks) - self.chunk_head
            for i in range(remaining):
                var source = Pointer(to=self.chunks[self.chunk_head + i])
                var item = source.unsafe_take_pointee()
                source.unsafe_write(DetachMessage.chunk(List[Byte]()))
                self.chunks[i] = item^
            while len(self.chunks) > remaining:
                _ = self.chunks.pop()
            self.chunk_head = 0
        var reservation = 0
        if not _reserve_capacity(
            self.chunks, budget, len(self.chunks) + 1, reservation
        ):
            return False
        self.chunks_ticket.amount = (
            self.chunks.capacity() * size_of[DetachMessage]()
        )
        var body = msg.body^
        msg.body = List[Byte]()
        var ticket = msg.body_ticket^
        msg.body_ticket = _CapacityTicket()
        self.chunks.append(DetachMessage.chunk(body^, ticket^))
        return True


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
    # Per-connection stamp/position for O(E+U) ready/urgent dedup in tick.
    # Stamps equal _tick_id only for connections touched this tick; idle
    # slots keep stale stamps so idle ticks never scan or re-init arrays.
    var _touch_stamp: List[Int]
    var _touch_pos: List[Int]
    var _urgent: List[Int]
    var _urgent_flag: List[Bool]
    var _deadline_heap: List[_HeapEntry]
    var _deadline_pos: List[Int]
    var _wakeup_channel: WakeupChannel
    var _wakeup_token: ReactorToken
    var _detached_conns: List[Int]
    var _hijacking_conns: List[Int]
    var _http2_detached: List[_Http2DetachedStream]
    var _http2_detached_ticket: _CapacityTicket
    var _http3_detached: List[_Http3DetachedStream]
    var _http3_detached_ticket: _CapacityTicket
    var _http3_inputs: List[_Http3RequestInput]
    var _http3_inputs_ticket: _CapacityTicket
    var _request_body_conns: List[Int]

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
        self._touch_stamp = List[Int]()
        self._touch_pos = List[Int]()
        self._urgent = List[Int]()
        self._urgent_flag = List[Bool]()
        self._deadline_heap = List[_HeapEntry]()
        self._deadline_pos = List[Int]()
        self._wakeup_channel = WakeupChannel()
        var wtoken = self._reactor.register(self._wakeup_channel.read_fd())
        self._wakeup_token = wtoken.copy()
        self._detached_conns = List[Int]()
        self._hijacking_conns = List[Int]()
        self._http2_detached = List[_Http2DetachedStream]()
        self._http2_detached_ticket = _CapacityTicket(self._budget.copy())
        self._http3_detached = List[_Http3DetachedStream]()
        self._http3_detached_ticket = _CapacityTicket(self._budget.copy())
        self._http3_inputs = List[_Http3RequestInput]()
        self._http3_inputs_ticket = _CapacityTicket(self._budget.copy())
        self._request_body_conns = List[Int]()
        while len(self._slot_map) <= wtoken.slot:
            self._slot_map.append(-1)

    def __deinit__(deinit self):
        self._http3_inputs = List[_Http3RequestInput]()
        self._http3_inputs_ticket.release()
        self._http3_detached = List[_Http3DetachedStream]()
        self._http3_detached_ticket.release()
        self._finish_control()
        for idx in range(len(self._conns)):
            self._discard_http2_detached(idx)
            if self._conns[idx].body_pipe:
                self._conns[idx].body_pipe.value().cancel()
            self._discard_hijack(idx)
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
        var token = self._reactor._register_listener(listener.raw_fd())
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
        endpoint.set_request_streaming(
            self.config.enable_request_body_streaming
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
        self._retry_request_body_budget()
        var wait_timeout = self._compute_timeout(now, timeout)
        self._process_hijacks()
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
        self._process_http3_inputs()
        self._dispatch_quic_requests(handler)
        self._process_http3_inputs()
        self._process_http3_detached(now)
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
                self._process_hijacks()
                self._process_detached_messages(now)
                var body_conns = self._request_body_conns.copy()
                for idx in body_conns:
                    if self._conns[idx].protocol == PROTOCOL_HTTP2:
                        self._flush_http2_body_credit(idx)
                        self._push_urgent(idx)
                        continue
                    if (
                        self._conns[idx].body_pipe.value().take_consumed() > 0
                        or self._conns[idx].body_pipe.value().is_discarded()
                    ):
                        self._conns[idx].body_blocked_budget = -1
                    self._push_urgent(idx)
                break
        # Fold the ready batch into per-connection masks via the slot map.
        # Token equality pins the generation, so a reused reactor slot can
        # never steer an event at the wrong connection. Only touched conns
        # plus urgent pipelines are driven; idle conns cost nothing.
        # Dedup is O(E+U) via per-conn tick stamp/position (not O(E²) scan).
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
            if events[k].has_hangup:
                self._conns[idx].peer_hangup = True
                if self._conns[idx].state == STATE_HIJACKING_FLUSH:
                    self._close_conn(idx)
                    continue
            var mask: UInt8 = 0
            if events[k].readable:
                mask |= 1
            if events[k].writable:
                mask |= 2
            if self._touch_stamp[idx] == self._tick_id:
                var found = self._touch_pos[idx]
                masks[found] |= mask
            else:
                self._touch_stamp[idx] = self._tick_id
                self._touch_pos[idx] = len(touched)
                touched.append(idx)
                masks.append(mask)
        for u in range(len(urgent)):
            var idx = urgent[u]
            if self._touch_stamp[idx] == self._tick_id:
                continue
            self._touch_stamp[idx] = self._tick_id
            self._touch_pos[idx] = len(touched)
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
        self._process_hijacks()
        self._process_detached_messages(now_ns())
        self._retry_request_body_budget()
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

    def _set_control(mut self, control: ServerControl) raises:
        if self.control._addr != control._addr:
            self._finish_control()
            self.control = control._fork()
            self._control_token = self._reactor.register(
                self.control._read_fd()
            )

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
            self._set_control(control)
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
            self._touch_stamp.append(-1)
            self._touch_pos.append(-1)
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
        var deadline = self._next_response_deadline(idx)
        if self._conns[idx].active and self._conns[idx].body_decoder:
            var body_deadline = self._conns[idx].body_at
            if body_deadline != NO_DEADLINE and (
                deadline == NO_DEADLINE or body_deadline < deadline
            ):
                deadline = body_deadline
        return deadline

    def _next_response_deadline(self, idx: Int) -> Int:
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
                and not self._has_http2_detached(idx)
                and not (
                    self.config.enable_request_body_streaming
                    and self._conns[idx].http2_session.value().next_deadline()
                    != NO_DEADLINE
                )
            ):
                if best == NO_DEADLINE or self._conns[idx].idle_at < best:
                    best = self._conns[idx].idle_at
            for i in range(len(self._http2_detached)):
                if self._http2_detached[i].target.slot == idx:
                    best = min(best, self._http2_detached[i].deadline)
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
                self._http3_detached = List[_Http3DetachedStream]()
                self._http3_detached_ticket.release()
                self._http3_inputs = List[_Http3RequestInput]()
                self._http3_inputs_ticket.release()
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
            if self._conns[idx].state == STATE_TLS_SHUTDOWN or (
                self._conns[idx].body_decoder
                and self._conns[idx].body_at != NO_DEADLINE
                and now >= self._conns[idx].body_at
            ):
                self._close_conn(idx)
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
                self._expire_http2_detached(idx, now)
                if not self._conns[idx].active:
                    continue
                if (
                    self._conns[idx].write_at != NO_DEADLINE
                    and now >= self._conns[idx].write_at
                ):
                    self._close_conn(idx)
                    continue
                var expired_stream_ids = List[UInt32]()
                var expired = (
                    self._conns[idx]
                    .http2_session.value()
                    .expire(now, expired_stream_ids)
                )
                for stream_id in expired_stream_ids:
                    self._reset_http2_response(idx, stream_id)
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
                        and not self._conns[i].body_decoder
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
        self._http3_inputs = List[_Http3RequestInput]()
        self._http3_inputs_ticket.release()
        self._http3_detached = List[_Http3DetachedStream]()
        self._http3_detached_ticket.release()
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
            var quic_request = (
                self._quic_endpoint.value()
                .try_next_request_head() if self.config.enable_request_body_streaming else self._quic_endpoint.value()
                .try_next_request()
            )
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
            var response = ResponseWriter(
                self.config.max_response_body,
                wakeup_fd=self._wakeup_channel.write_fd(),
                queue_limit=self.config.stream_queue_limit,
                is_head=is_head,
            )
            response._set_mailbox_budget(self._budget.copy())
            response._set_detach_target(_DetachTarget.http3(request_id))
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
                    var dispatch = True
                    var expectations = request.headers.get_all("Expect")
                    for expectation in expectations:
                        var tokens = _split_comma_tokens(expectation)
                        if len(tokens) == 0:
                            dispatch = False
                        for token in tokens:
                            if token.lower() != "100-continue":
                                dispatch = False
                    if not dispatch:
                        response.status = 417
                    if dispatch and self.config.enable_request_body_streaming:
                        try:
                            var pipe = _BodyPipe(
                                self.config.max_body_bytes,
                                self._budget.copy(),
                                self._wakeup_channel.write_fd(),
                                reserve_capacity=True,
                            )
                            if not self._register_http3_input(request_id, pipe):
                                dispatch = False
                            else:
                                request._body_pipe = pipe.copy()
                                response._set_request_body_pipe(
                                    Optional(pipe.copy())
                                )
                                self._process_http3_inputs()
                                var input_position = self._find_http3_input(
                                    request_id
                                )
                                if (
                                    len(expectations) > 0
                                    and input_position >= 0
                                    and not self._http3_inputs[
                                        input_position
                                    ].wire_eof
                                ):
                                    dispatch = self._quic_endpoint.value().send_continue(
                                        request_id
                                    )
                        except:
                            dispatch = False
                        if not dispatch:
                            response.status = 503
                    try:
                        if dispatch:
                            handler.handle(request^, response)
                    except e:
                        _ = e
                        response._cancel_detach()
                        response.status = 500
                        response.body.clear()
                        response.trailers.clear()
                except e:
                    _ = e
                    response.status = 400
                    response.body.clear()
                    response.trailers.clear()
                self._budget.release(body_size)
            if self.config.enable_request_body_streaming:
                var position = self._find_http3_input(request_id)
                if (
                    position < 0
                    or not self._http3_inputs[
                        position
                    ].pipe.has_detached_reader()
                ):
                    _ = self._quic_endpoint.value().release_body(request_id)
                    if position >= 0:
                        self._remove_http3_input(position)
            if response.is_detached() and response._detach_state_addr != 0:
                var addr = response._detach_state_addr
                response._detach_state_addr = 0
                if self._register_http3_detached(request_id, addr, is_head):
                    processed += 1
                    continue
                _cancel_detach_state(addr)
                response.status = 500
                response.body.clear()
                response.trailers.clear()
            # 1xx is intermediate only; a completed handler has no follow-up
            # final response API, so reject informational as a final status.
            if response.status < 200 or response.status > 599:
                response.status = 500
                response.body.clear()
                response.trailers.clear()
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
                response.trailers.clear()
                response.body.clear()
            var wire_length = -1
            if has_body_for_status(response.status, False):
                wire_length = response._representation_length(is_head)
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
                        response.trailers.clear()
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
                response.trailers.clear()
            if (
                len(response_body) > self.config.max_response_body
                or len(headers) > self.config.max_response_headers_bytes
                or header_count > self.config.max_response_headers_count
            ):
                response.status = 500
                headers.clear()
                _append_quic_u32(headers, UInt32(0))
                response_body.clear()
                response.trailers.clear()
            var trailers = List[Byte]()
            if len(response.trailers) > 0:
                var trailer_bytes = 4
                for i in range(len(response.trailers)):
                    trailer_bytes += (
                        response.trailers.name_at(i).byte_length()
                        + response.trailers.value_byte_length(i)
                        + 8
                    )
                # Response headers and trailers share the local response
                # header budget; a shared enforcement keeps a handler
                # that fills the full budget with each from bypassing
                # the configured limits even when both pass on their own.
                var combined_count = header_count + len(response.trailers)
                var combined_bytes = len(headers) + trailer_bytes
                if (
                    len(response.trailers)
                    > self.config.max_response_headers_count
                    or trailer_bytes > self.config.max_response_headers_bytes
                    or combined_count > self.config.max_response_headers_count
                    or combined_bytes > self.config.max_response_headers_bytes
                ):
                    response.trailers.clear()
            if len(response.trailers) > 0:
                for i in range(len(response.trailers)):
                    if _trailer_forbidden(response.trailers._lower_names[i]):
                        response.trailers.clear()
                        break
            if len(response.trailers) > 0:
                _append_quic_u32(trailers, UInt32(len(response.trailers)))
                for i in range(len(response.trailers)):
                    _append_quic_field(
                        trailers, response.trailers._names[i].as_bytes()
                    )
                    _append_quic_field(
                        trailers, response.trailers._value_bytes_span(i)
                    )
            try:
                self._quic_endpoint.value().respond(
                    request_id,
                    response.status,
                    Span(headers),
                    Span(response_body),
                    Span(trailers),
                )
            except e:
                _ = e
            processed += 1

    def _find_http3_input(self, request_id: UInt64) -> Int:
        for i in range(len(self._http3_inputs)):
            if self._http3_inputs[i].request_id == request_id:
                return i
        return -1

    def _register_http3_input(
        mut self, request_id: UInt64, pipe: _BodyPipe
    ) -> Bool:
        var reservation = 0
        if not _reserve_capacity(
            self._http3_inputs,
            self._budget,
            len(self._http3_inputs) + 1,
            reservation,
        ):
            return False
        self._http3_inputs_ticket.amount = (
            self._http3_inputs.capacity() * size_of[_Http3RequestInput]()
        )
        self._http3_inputs.append(
            _Http3RequestInput(
                request_id, pipe.copy(), False, False, NO_DEADLINE, Headers()
            )
        )
        return True

    def _remove_http3_input(mut self, position: Int):
        var last = self._http3_inputs.pop()
        if position < len(self._http3_inputs):
            self._http3_inputs[position] = last^
        if len(self._http3_inputs) == 0:
            self._http3_inputs = List[_Http3RequestInput]()
            self._http3_inputs_ticket.release()

    def _process_http3_inputs(mut self) raises NetError:
        if not self._quic_endpoint:
            return
        var scratch = Array[Byte, 4096](fill=0)
        var now = now_ns()
        var index = 0
        while index < len(self._http3_inputs):
            var id = self._http3_inputs[index].request_id
            var pipe = self._http3_inputs[index].pipe.copy()
            var consumed = pipe.take_consumed()
            if consumed > 0:
                if not self._quic_endpoint.value().consume_body(id, consumed):
                    pipe.cancel()
                elif (
                    self._http3_inputs[index].wire_eof
                    and not self._http3_inputs[index].eof_published
                ):
                    self._http3_inputs[
                        index
                    ].eof_admission_at = deadline_from_now(
                        self.config.body_deadline
                    )
            if pipe.is_cancelled() or (
                self._http3_inputs[index].wire_eof
                and not self._http3_inputs[index].eof_published
                and now >= self._http3_inputs[index].eof_admission_at
            ):
                pipe.cancel()
                _ = self._quic_endpoint.value().release_body(id, True)
                self._cancel_http3_detached(id, UInt64(0x10C))
                self._remove_http3_input(index)
                continue
            if self._http3_inputs[index].wire_eof:
                var probe = self._quic_endpoint.value().read_body(
                    id, Span[mut=True](scratch)[:0]
                )
                if probe.state == QuicBodyReadState.cancelled():
                    pipe.cancel()
                    self._cancel_http3_detached(id, UInt64(0x10C))
                    self._remove_http3_input(index)
                    continue
            if not self._http3_inputs[index].wire_eof:
                var capacity = min(len(scratch), pipe.writable_bytes())
                var result = self._quic_endpoint.value().read_body(
                    id, Span[mut=True](scratch)[:capacity]
                )
                if result.state == QuicBodyReadState.cancelled():
                    pipe.cancel()
                    self._cancel_http3_detached(id, UInt64(0x10C))
                    self._remove_http3_input(index)
                    continue
                if result.state == QuicBodyReadState.data():
                    if not pipe.push(Span(scratch)[: result.count]):
                        pipe.cancel()
                    var discarded = pipe.take_consumed()
                    if discarded > 0:
                        _ = self._quic_endpoint.value().consume_body(
                            id, discarded
                        )
                elif result.state == QuicBodyReadState.eof():
                    var fields = self._quic_endpoint.value().body_trailers(id)
                    for i in range(len(fields)):
                        self._http3_inputs[index].trailers.add_bytes(
                            fields[i].name.copy(), Span(fields[i].value)
                        )
                    self._http3_inputs[index].wire_eof = True
                    self._http3_inputs[
                        index
                    ].eof_admission_at = deadline_from_now(
                        self.config.body_deadline
                    )
            if (
                self._http3_inputs[index].wire_eof
                and not self._http3_inputs[index].eof_published
            ):
                try:
                    self._http3_inputs[
                        index
                    ].eof_published = pipe._try_push_eof(
                        self._http3_inputs[index].trailers
                    )
                except:
                    pipe.cancel()
                    _ = self._quic_endpoint.value().release_body(id, True)
                    self._cancel_http3_detached(id, UInt64(0x102))
                    self._remove_http3_input(index)
                    continue
            if pipe.is_eof():
                consumed = pipe.take_consumed()
                if consumed > 0:
                    _ = self._quic_endpoint.value().consume_body(id, consumed)
                _ = self._quic_endpoint.value().release_body(id)
                self._remove_http3_input(index)
                continue
            index += 1

    def _find_http3_detached(self, request_id: UInt64) -> Int:
        for i in range(len(self._http3_detached)):
            if self._http3_detached[i].target.stream_id == request_id:
                return i
        return -1

    def _register_http3_detached(
        mut self, request_id: UInt64, addr: Int, is_head: Bool
    ) -> Bool:
        var reservation = 0
        if not _reserve_capacity(
            self._http3_detached,
            self._budget,
            len(self._http3_detached) + 1,
            reservation,
        ):
            return False
        self._http3_detached_ticket.amount = (
            self._http3_detached.capacity() * size_of[_Http3DetachedStream]()
        )
        self._http3_detached.append(
            _Http3DetachedStream(
                request_id,
                addr,
                deadline_from_now(self.config.detached_response_timeout),
                is_head,
                self._budget.copy(),
            )
        )
        return True

    def _remove_http3_detached(mut self, position: Int):
        var last = self._http3_detached.pop()
        if position < len(self._http3_detached):
            self._http3_detached[position] = last^
        if len(self._http3_detached) == 0:
            self._http3_detached = List[_Http3DetachedStream]()
            self._http3_detached_ticket.release()

    def _cancel_http3_detached(
        mut self, request_id: UInt64, error_code: UInt64
    ):
        var position = self._find_http3_detached(request_id)
        if position >= 0:
            self._remove_http3_detached(position)
        if self._quic_endpoint:
            _ = self._quic_endpoint.value().cancel_response(
                request_id, error_code
            )

    def _fail_http3_detached(mut self, request_id: UInt64):
        var position = self._find_http3_detached(request_id)
        var started = self._http3_detached[position].started
        self._remove_http3_detached(position)
        if not started:
            var fields = List[Byte]()
            var ticket = _CapacityTicket(self._budget.copy())
            var reservation = 0
            if not _reserve_capacity(fields, self._budget, 4, reservation):
                _ = self._quic_endpoint.value().cancel_response(
                    request_id, UInt64(0x102)
                )
                return
            ticket.amount = fields.capacity()
            _append_quic_u32(fields, UInt32(0))
            var empty = List[Byte]()
            var trailers = List[Byte]()
            try:
                self._quic_endpoint.value().respond(
                    request_id, 500, Span(fields), Span(empty), Span(trailers)
                )
                _ = fields^
                ticket.release()
                return
            except:
                _ = fields^
                ticket.release()
        _ = self._quic_endpoint.value().cancel_response(
            request_id, UInt64(0x102)
        )

    def _begin_http3_detached(
        mut self, request_id: UInt64, mut msg: DetachMessage, streaming: Bool
    ):
        var position = self._find_http3_detached(request_id)
        var status = msg.status
        var wire_length = -1
        if not streaming and has_body_for_status(status, False):
            wire_length = len(msg.body)
            if self._http3_detached[position].is_head and len(msg.body) == 0:
                var declared = _declared_content_length(msg.headers)
                if declared >= 0:
                    wire_length = declared
        elif streaming:
            wire_length = _declared_content_length(msg.headers)
        var valid = status >= 200 and status <= 599 and wire_length != -2
        if not streaming:
            valid = valid and len(msg.body) <= self.config.max_response_body
        var count = len(msg.headers) - msg.headers.count("content-length")
        if wire_length >= 0:
            count += 1
        var bytes = 4
        for i in range(len(msg.headers)):
            var name = msg.headers._lower_names[i]
            if (
                name == "connection"
                or name == "proxy-connection"
                or name == "keep-alive"
                or name == "transfer-encoding"
                or name == "upgrade"
                or name == "te"
            ):
                valid = False
            if msg.headers._lower_names[i] == "content-length":
                if wire_length >= 0 and not _content_length_matches(
                    msg.headers.value_at(i), wire_length
                ):
                    valid = False
                continue
            bytes += (
                msg.headers.name_at(i).byte_length()
                + msg.headers.value_byte_length(i)
                + 8
            )
        var length = String(wire_length)
        if wire_length >= 0:
            bytes += 22 + length.byte_length()
        if (
            not valid
            or count > self.config.max_response_headers_count
            or bytes > self.config.max_response_headers_bytes
        ):
            self._fail_http3_detached(request_id)
            return
        var fields = List[Byte]()
        var ticket = _CapacityTicket(self._budget.copy())
        var reservation = 0
        if not _reserve_capacity(fields, self._budget, bytes, reservation):
            self._fail_http3_detached(request_id)
            return
        ticket.amount = fields.capacity()
        _append_quic_u32(fields, UInt32(count))
        for i in range(len(msg.headers)):
            if msg.headers._lower_names[i] == "content-length":
                continue
            _append_quic_field(fields, msg.headers._names[i].as_bytes())
            _append_quic_field(fields, msg.headers._value_bytes_span(i))
        if wire_length >= 0:
            _append_quic_field(fields, String("content-length").as_bytes())
            _append_quic_field(fields, length.as_bytes())
        try:
            self._quic_endpoint.value().start_response(
                request_id, status, Span(fields)
            )
        except:
            _ = fields^
            ticket.release()
            self._fail_http3_detached(request_id)
            return
        _ = fields^
        ticket.release()
        self._http3_detached[position].started = True
        self._http3_detached[position].allows_body = has_body_for_status(
            status, self._http3_detached[position].is_head
        )
        self._http3_detached[position].initial_field_count = count
        self._http3_detached[position].initial_field_bytes = bytes
        if not streaming:
            self._http3_detached[position].finished = True
            if self._http3_detached[position].allows_body:
                if not self._http3_detached[position].push(msg, self._budget):
                    self._cancel_http3_detached(request_id, UInt64(0x102))

    def _finish_http3_detached(
        mut self, request_id: UInt64, var trailers: Headers
    ):
        var position = self._find_http3_detached(request_id)
        if not self._http3_detached[position].allows_body:
            trailers.clear()
        if len(trailers) == 0:
            self._http3_detached[position].finished = True
            return
        var bytes = 4
        for i in range(len(trailers)):
            if _trailer_forbidden(trailers._lower_names[i]):
                self._cancel_http3_detached(request_id, UInt64(0x102))
                return
            bytes += (
                trailers.name_at(i).byte_length()
                + trailers.value_byte_length(i)
                + 8
            )
        if (
            len(trailers) + self._http3_detached[position].initial_field_count
            > self.config.max_response_headers_count
            or bytes + self._http3_detached[position].initial_field_bytes
            > self.config.max_response_headers_bytes
        ):
            self._cancel_http3_detached(request_id, UInt64(0x102))
            return
        self._http3_detached[position].trailers = trailers^
        self._http3_detached[position].finished = True

    def _pump_http3_detached(mut self, request_id: UInt64):
        var position = self._find_http3_detached(request_id)
        if not self._http3_detached[position].started:
            return
        var moved = 0
        while self._http3_detached[position].chunk_head < len(
            self._http3_detached[position].chunks
        ):
            var head = self._http3_detached[position].chunk_head
            var offset = self._http3_detached[position].body_offset
            var bytes = Span(self._http3_detached[position].chunks[head].body)
            var room = min(
                len(bytes) - offset, self.config.max_bytes_per_tick - moved
            )
            if room <= 0 and len(bytes) > offset:
                return
            var accepted = self._quic_endpoint.value().send_stream_body(
                request_id, bytes[offset : offset + room]
            )
            if accepted < 0:
                self._cancel_http3_detached(request_id, UInt64(0x102))
                return
            if accepted == 0 and len(bytes) > offset:
                return
            _consume_detach_bytes(self._http3_detached[position].addr, accepted)
            self._http3_detached[position].body_offset += accepted
            moved += accepted
            if accepted > 0:
                self._http3_detached[position].deadline = deadline_from_now(
                    self.config.detached_response_timeout
                )
            if self._http3_detached[position].body_offset < len(bytes):
                return
            self._http3_detached[position].chunks[head] = DetachMessage.chunk(
                List[Byte]()
            )
            self._http3_detached[position].chunk_head += 1
            self._http3_detached[position].body_offset = 0
        self._http3_detached[position].chunks = List[DetachMessage]()
        self._http3_detached[position].chunk_head = 0
        self._http3_detached[position].chunks_ticket.release()
        if (
            not self._http3_detached[position].finished
            or self._http3_detached[position].finish_sent
        ):
            return
        var count = len(self._http3_detached[position].trailers)
        if count == 0:
            var empty = List[Byte]()
            if (
                self._quic_endpoint.value().send_stream_body(
                    request_id, Span(empty), True
                )
                < 0
            ):
                self._cancel_http3_detached(request_id, UInt64(0x102))
                return
        else:
            var bytes = 4
            for i in range(count):
                bytes += (
                    self._http3_detached[position]
                    .trailers.name_at(i)
                    .byte_length()
                    + self._http3_detached[position].trailers.value_byte_length(
                        i
                    )
                    + 8
                )
            var fields = List[Byte]()
            var ticket = _CapacityTicket(self._budget.copy())
            var reservation = 0
            if not _reserve_capacity(fields, self._budget, bytes, reservation):
                self._cancel_http3_detached(request_id, UInt64(0x102))
                return
            ticket.amount = fields.capacity()
            _append_quic_u32(fields, UInt32(count))
            for i in range(count):
                _append_quic_field(
                    fields,
                    self._http3_detached[position]
                    .trailers._names[i]
                    .as_bytes(),
                )
                _append_quic_field(
                    fields,
                    self._http3_detached[position].trailers._value_bytes_span(
                        i
                    ),
                )
            try:
                self._quic_endpoint.value().add_stream_trailers(
                    request_id, Span(fields)
                )
            except:
                _ = fields^
                ticket.release()
                self._cancel_http3_detached(request_id, UInt64(0x102))
                return
            _ = fields^
            ticket.release()
        self._http3_detached[position].finish_sent = True
        self._http3_detached[position].trailers = Headers()

    def _process_http3_detached(mut self, now: Int):
        if not self._quic_endpoint:
            return
        try:
            var events = self._quic_endpoint.value().poll_stream_events()
            for i in range(len(events)):
                var position = self._find_http3_detached(events[i].request_id)
                if position < 0 or events[i].kind == 0:
                    continue
                if events[i].kind == 1:
                    var addr = self._http3_detached[position].addr
                    self._http3_detached[position].addr = 0
                    _release_detach_state(addr, False)
                self._remove_http3_detached(position)
        except:
            self._http3_detached = List[_Http3DetachedStream]()
            self._http3_detached_ticket.release()
            return
        var index = 0
        while index < len(self._http3_detached):
            var target = self._http3_detached[index].target.copy()
            var request_id = target.stream_id
            var addr = self._http3_detached[index].addr
            if (
                not self._http3_detached[index].finish_sent
                and self._quic_endpoint.value().stream_capacity(request_id) < 0
            ):
                self._remove_http3_detached(index)
                continue
            if now >= self._http3_detached[index].deadline:
                self._cancel_http3_detached(request_id, UInt64(0x10C))
                continue
            var batch = _take_batch(_detach_state(addr))
            if batch.target != target:
                self._cancel_http3_detached(request_id, UInt64(0x10C))
                continue
            if len(batch.messages) > 0 or batch.terminal_kind != MSG_KIND_NONE:
                self._http3_detached[index].deadline = deadline_from_now(
                    self.config.detached_response_timeout
                )
            batch.messages.reverse()
            while len(batch.messages) > 0:
                var msg = batch.messages.pop()
                var position = self._find_http3_detached(request_id)
                if position < 0:
                    break
                if msg.kind == MSG_KIND_RESPOND or msg.kind == MSG_KIND_START:
                    self._begin_http3_detached(
                        request_id, msg, msg.kind == MSG_KIND_START
                    )
                elif msg.kind == MSG_KIND_CHUNK:
                    if not self._http3_detached[position].allows_body:
                        _consume_detach_bytes(addr, len(msg.body))
                    elif not self._http3_detached[position].push(
                        msg, self._budget
                    ):
                        self._cancel_http3_detached(request_id, UInt64(0x102))
            var position = self._find_http3_detached(request_id)
            if position >= 0 and batch.terminal_kind != MSG_KIND_NONE:
                if batch.terminal_kind == MSG_KIND_FINISH:
                    var trailers = batch.trailers^
                    batch.trailers = Headers()
                    self._finish_http3_detached(request_id, trailers^)
                else:
                    var state = _detach_state(addr)
                    state[].mutex.lock()
                    var failed = state[].cancelled
                    state[].mutex.unlock()
                    self._cancel_http3_detached(
                        request_id, UInt64(0x102) if failed else UInt64(0x10C)
                    )
            position = self._find_http3_detached(request_id)
            if position >= 0:
                self._pump_http3_detached(request_id)
            position = self._find_http3_detached(request_id)
            if position >= 0:
                index = position + 1

    def _pause_listener(mut self):
        if self._listener and not self._listener_paused:
            _ = self._reactor.remove(self._listener_token)
            self._listener_paused = True

    def _resume_listener(mut self) raises NetError:
        if self._listener and self._listener_paused:
            var token = self._reactor._register_listener(
                self._listener.value().raw_fd()
            )
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
        self._discard_hijack(idx)
        self._discard_detached(idx)
        self._discard_http2_detached(idx)
        self._cancel_request_body(idx)
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
        self._cancel_request_body(idx)
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
            self._conns[idx].body_decoder
            and self._conns[idx].body_blocked_budget < 0
            and not self._conns[idx].body_decoder.value().wants_input()
        ):
            self._conns[idx].body_blocked_budget = self._budget.remaining()
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
            watch_hangup=self._conns[idx].state == STATE_HIJACKING_FLUSH,
        )

    def _drive_tls_handshake(mut self, idx: Int) raises NetError:
        try:
            var progress = self._conns[idx].tls.value().handshake()
            if progress.is_complete():
                var protocol = self._conns[idx].tls.value().selected_alpn()
                if protocol == "h2":
                    self._conns[idx]._drop_error_wire()
                    self._conns[idx].protocol = PROTOCOL_HTTP2
                    var body_budget: Optional[SharedBufferBudget] = None
                    if self.config.enable_request_body_streaming:
                        body_budget = self._budget.copy()
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
                            request_body_budget=body_budget^,
                            body_wakeup_fd=self._wakeup_channel.write_fd(),
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
        self._cancel_request_body(idx)
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
        if self._conns[idx].state == STATE_HIJACKING_FLUSH:
            if self._conns[idx].write_ready(readable, writable):
                self._pump_hijack(idx)
            if self._conns[idx].active:
                self._sync_interests(idx)
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
                var expired_stream_ids = List[UInt32]()
                var expired = (
                    self._conns[idx]
                    .http2_session.value()
                    .expire(now, expired_stream_ids)
                )
                for stream_id in expired_stream_ids:
                    self._reset_http2_response(idx, stream_id)
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
                self._finish_connection(idx)
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
                self._finish_connection(idx)
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
                    self._finish_connection(idx)
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
            if self._http2_drained(idx):
                # Input/output processing can turn an idle session into a
                # draining one (e.g. after acknowledging a peer GOAWAY).
                # Re-check here or the connection would wait for a tick
                # trigger that no further input will supply.
                self._finish_connection(idx)
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
        if self._conns[idx].body_decoder:
            self._drive_request_body(idx, readable, writable, now)
            if not self._conns[idx].active:
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
            if read_event and not self._conns[idx].body_decoder:
                self._pump_read(idx, read_event, now)
                if not self._conns[idx].active:
                    return
                # Write half-close (read EOF) is not a full disconnect: stop
                # reading and finish any accepted detached/streaming response.
                # Write failure, reset, and deadlines still cancel via their
                # existing paths. wants_read() is already False on read_eof.
            self._sync_interests(idx)
            return
        if self._conns[idx].state == STATE_READING:
            if self._conns[idx].body_decoder:
                self._sync_interests(idx)
                return
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
                if len(result.output) > 0:
                    var output = result.output^
                    result.output = List[Byte]()
                    if not self._conns[idx].append_pending(
                        output^, self._budget
                    ):
                        self._close_conn(idx)
                        return
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
                self._reset_http2_response(idx, result.reset_stream_id)
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
            if self.config.enable_request_body_streaming:
                if self._conns[idx].http2_session.value().has_request_inputs():
                    self._register_http2_body_input(idx)
                var credit = (
                    self._conns[idx].http2_session.value().flush_body_credit()
                )
                result.output.extend(Span(credit))
                if (
                    not self._conns[idx]
                    .http2_session.value()
                    .has_request_inputs()
                ):
                    self._remove_request_body(idx)
            if result.is_request() or result.is_head():
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

        var reject_expectation = False
        if self.config.enable_request_body_streaming:
            var expectations = request.headers.get_all("expect")
            for expectation in expectations:
                var tokens = _split_comma_tokens(expectation)
                if len(tokens) == 0:
                    reject_expectation = True
                for token in tokens:
                    if token.lower() != "100-continue":
                        reject_expectation = True
            if reject_expectation:
                request._body_pipe.value().discard()
            elif (
                len(expectations) > 0
                and not request._body_pipe.value().is_eof()
            ):
                var fields = List[Byte]()
                _ = _append_field(fields, ":status", "100".as_bytes())
                var bound = (
                    self._conns[idx]
                    .http2_deflater.value()
                    .deflate_bound(Span(fields))
                )
                if bound < 0:
                    self._close_conn(idx)
                    return
                var block = List[Byte](length=bound, fill=0)
                var encoded = (
                    self._conns[idx]
                    .http2_deflater.value()
                    .encode(
                        Span(fields),
                        min(
                            self.config.max_response_headers_bytes,
                            Int(
                                self._conns[idx]
                                .http2_session.value()
                                .peer_settings()
                                .max_header_list_size
                            ),
                        ),
                        self.config.max_response_headers_count,
                        Span(block),
                    )
                )
                if not encoded.is_success():
                    self._close_conn(idx)
                    return
                var informational = encode_frame(
                    UInt8(1),
                    UInt8(4),
                    stream_id,
                    Span(block)[: encoded.output_length],
                )
                control_output.extend(Span(informational.wire))
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
        var writer = ResponseWriter(
            cap,
            slot=idx,
            generation=self._conns[idx].token.generation,
            wakeup_fd=self._wakeup_channel.write_fd(),
            queue_limit=self.config.stream_queue_limit,
            is_head=is_head,
        )
        writer._set_detach_target(
            _DetachTarget.http2(
                idx, self._conns[idx].token.generation, stream_id
            )
        )
        writer._set_mailbox_budget(self._budget.copy())
        var request_pipe = request._body_pipe.copy()
        writer._set_request_body_pipe(request_pipe.copy())
        self._conns[idx].requests_this_tick += 1
        self._conns[idx].requests_served += 1
        try:
            if reject_expectation:
                writer.set_status(417)
            else:
                handler.handle(request^, writer)
        except e:
            _ = e
            writer._cancel_detach()
            writer.set_status(500)
            writer.headers.clear()
            writer.trailers.clear()
            writer.body.clear()

        if (
            self.config.enable_request_body_streaming
            and not request_pipe.value().has_detached_reader()
        ):
            request_pipe.value().discard()

        self._budget.release(request_body_bytes)
        self._conns[idx].http2_body_reserved -= request_body_bytes

        if len(writer.body) > cap:
            writer.set_status(500)
            writer.headers.clear()
            writer.trailers.clear()
            writer.body.clear()

        if writer.is_detached() and writer._detach_state_addr != 0:
            var addr = writer._detach_state_addr
            writer._detach_state_addr = 0
            if self._register_http2_detached(idx, stream_id, addr, is_head):
                writer._drop_body()
                writer._drop_headers()
                if not self._flush_http2_control_output(idx, control_output^):
                    return
                self._arm_deadline(idx)
                self._sync_interests(idx)
                return
            _cancel_detach_state(addr)
            writer.set_status(500)
            writer._drop_body()
            writer._drop_headers()

        try:
            self._inject_alt_svc_for_tls(idx, writer)
        except e:
            _ = e
            self._close_conn(idx)
            return

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
        var fields_result = encode_http2_response_headers(
            writer,
            is_head,
            self._tick_date,
            max_response_header_bytes,
            self.config.max_response_headers_count,
        )
        if not fields_result.is_valid():
            # Headers failed before HPACK ran (bad field or over the peer's
            # SETTINGS_MAX_HEADER_LIST_SIZE); retry a minimal 500 so sibling
            # streams on the same connection stay alive.
            writer.set_status(500)
            writer.headers.clear()
            writer.trailers.clear()
            writer.body.clear()
            fields_result = encode_http2_response_headers(
                writer,
                is_head,
                self._tick_date,
                max_response_header_bytes,
                self.config.max_response_headers_count,
            )
            if not fields_result.is_valid():
                if not self._flush_http2_control_output(idx, control_output^):
                    return
                self._refuse_http2_stream(idx, stream_id, UInt32(2))
                return

        var response_body = writer.body^
        writer.body = List[Byte]()
        if not has_body_for_status(writer.status, is_head):
            response_body.clear()
            writer.trailers.clear()
        var field_bytes = fields_result.fields^
        fields_result.fields = List[Byte]()
        var field_count = fields_result.field_count

        var trailer_wire = List[Byte]()
        var trailer_field_count = 0
        if len(writer.trailers) > 0:
            # Local caps (configured) are shared across response HEADERS
            # and the trailer block so a handler cannot fill the full
            # allowance with each section. The peer's
            # SETTINGS_MAX_HEADER_LIST_SIZE is a per-section limit
            # (RFC 9113 §6.5.2) and is applied independently to each.
            # `field_bytes` carries 8 bytes of prefix per field; the
            # header-list size that both the local cap and
            # `_field_size` charge is `name + value + 32` per field. The
            # consumed header-list size is therefore
            # `len(field_bytes) + 24 * field_count`.
            var consumed_header_list = len(field_bytes) + 24 * field_count
            var combined_local_bytes = (
                self.config.max_response_headers_bytes - consumed_header_list
            )
            if combined_local_bytes < 0:
                combined_local_bytes = 0
            var trailer_byte_room = combined_local_bytes
            if peer_header_list_size < trailer_byte_room:
                trailer_byte_room = peer_header_list_size
            var trailer_field_room = (
                self.config.max_response_headers_count - field_count
            )
            if trailer_field_room < 0:
                trailer_field_room = 0
            if trailer_field_room > 0 and trailer_byte_room > 0:
                var trailer_encoded = encode_http2_response_trailers(
                    writer,
                    is_head,
                    trailer_byte_room,
                    trailer_field_room,
                )
                if trailer_encoded.is_valid():
                    trailer_wire = trailer_encoded.fields^
                    trailer_encoded.fields = List[Byte]()
                    trailer_field_count = trailer_encoded.field_count

        var response_reservation = (
            len(field_bytes) + len(response_body) + len(trailer_wire)
        )
        if not self._budget.try_reserve(response_reservation):
            if not self._flush_http2_control_output(idx, control_output^):
                return
            self._refuse_http2_stream(idx, stream_id, UInt32(2))
            return
        if not self._conns[idx].http2_responses.enqueue(
            stream_id,
            field_bytes^,
            field_count,
            max_response_header_bytes,
            self.config.max_response_headers_count,
            compressed_capacity,
            response_body^,
            trailer_wire^,
            trailer_field_count,
        ):
            self._budget.release(response_reservation)
            if not self._flush_http2_control_output(idx, control_output^):
                return
            self._refuse_http2_stream(idx, stream_id, UInt32(2))
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

    def _has_http2_detached(self, idx: Int) -> Bool:
        for i in range(len(self._http2_detached)):
            if self._http2_detached[i].target.slot == idx:
                return True
        return False

    def _find_http2_detached(self, idx: Int, stream_id: UInt32) -> Int:
        for i in range(len(self._http2_detached)):
            if self._http2_detached[
                i
            ].target.slot == idx and self._http2_detached[
                i
            ].target.stream_id == UInt64(
                stream_id
            ):
                return i
        return -1

    def _register_http2_detached(
        mut self, idx: Int, stream_id: UInt32, addr: Int, is_head: Bool
    ) -> Bool:
        var reservation = 0
        if not _reserve_capacity(
            self._http2_detached,
            self._budget,
            len(self._http2_detached) + 1,
            reservation,
        ):
            return False
        self._http2_detached_ticket.amount = (
            self._http2_detached.capacity() * size_of[_Http2DetachedStream]()
        )
        # Detached streams use their own deadline to bound admission occupancy.
        self._http2_detached.append(
            _Http2DetachedStream(
                target=_DetachTarget.http2(
                    idx, self._conns[idx].token.generation, stream_id
                ),
                addr=addr,
                deadline=deadline_from_now(
                    self.config.detached_response_timeout
                ),
                is_head=is_head,
                status=200,
                allows_body=True,
                initial_field_count=0,
                initial_field_bytes=0,
                headers=Headers(),
            )
        )
        self._conns[idx].idle_at = NO_DEADLINE
        return True

    def _remove_http2_detached(mut self, position: Int):
        var last = self._http2_detached.pop()
        if position < len(self._http2_detached):
            self._http2_detached[position] = last^
        if len(self._http2_detached) == 0:
            self._http2_detached = List[_Http2DetachedStream]()
            self._http2_detached_ticket.release()

    def _drop_http2_detached(mut self, idx: Int, stream_id: UInt32):
        var position = self._find_http2_detached(idx, stream_id)
        if position >= 0:
            self._remove_http2_detached(position)

    def _discard_http2_detached(mut self, idx: Int):
        var position = 0
        while position < len(self._http2_detached):
            if self._http2_detached[position].target.slot != idx:
                position += 1
                continue
            var stream_id = UInt32(
                self._http2_detached[position].target.stream_id
            )
            var released = self._conns[idx].http2_responses.cancel(stream_id)
            self._budget.release(released)
            self._conns[idx].http2_response_bytes_reserved -= released
            self._remove_http2_detached(position)

    def _cancel_http2_detached(
        mut self, idx: Int, stream_id: UInt32, error_code: UInt32
    ) raises NetError:
        var released = self._conns[idx].http2_responses.cancel(stream_id)
        self._budget.release(released)
        self._conns[idx].http2_response_bytes_reserved -= released
        self._drop_http2_detached(idx, stream_id)
        self._refuse_http2_stream(idx, stream_id, error_code)
        if self._conns[idx].active:
            self._arm_deadline(idx)
            self._sync_interests(idx)

    def _expire_http2_detached(mut self, idx: Int, now: Int) raises NetError:
        var position = 0
        while position < len(self._http2_detached):
            if (
                self._http2_detached[position].target.slot == idx
                and now >= self._http2_detached[position].deadline
            ):
                var stream_id = UInt32(
                    self._http2_detached[position].target.stream_id
                )
                self._cancel_http2_detached(idx, stream_id, UInt32(8))
            else:
                position += 1

    def _http2_response_header_room(self, idx: Int) -> Int:
        return min(
            self.config.max_response_headers_bytes,
            Int(
                self._conns[idx]
                .http2_session.value()
                .peer_settings()
                .max_header_list_size
            ),
        )

    def _fail_http2_detached(
        mut self, idx: Int, stream_id: UInt32
    ) raises NetError:
        var released = self._conns[idx].http2_responses.cancel(stream_id)
        self._budget.release(released)
        self._conns[idx].http2_response_bytes_reserved -= released
        self._drop_http2_detached(idx, stream_id)
        var limit = self._http2_response_header_room(idx)
        var fields = encode_http2_minimal_500_fields(
            self._tick_date, limit, self.config.max_response_headers_count
        )
        if not fields.is_valid():
            self._refuse_http2_stream(idx, stream_id, UInt32(2))
            return
        var charge = len(fields.fields)
        if not self._budget.try_reserve(charge):
            self._refuse_http2_stream(idx, stream_id, UInt32(2))
            return
        var raw = fields.fields^
        fields.fields = List[Byte]()
        if not self._conns[idx].http2_responses.enqueue(
            stream_id,
            raw^,
            fields.field_count,
            limit,
            self.config.max_response_headers_count,
            max(1, limit),
            List[Byte](),
        ):
            self._budget.release(charge)
            self._refuse_http2_stream(idx, stream_id, UInt32(2))
            return
        self._conns[idx].http2_response_bytes_reserved += charge

    def _begin_http2_detached(
        mut self,
        idx: Int,
        stream_id: UInt32,
        mut msg: DetachMessage,
        streaming: Bool,
    ) raises NetError:
        var position = self._find_http2_detached(idx, stream_id)
        var is_head = self._http2_detached[position].is_head
        var writer = ResponseWriter(self.config.max_response_body)
        writer.status = msg.status
        writer.headers = msg.headers^
        msg.headers = Headers()
        if not streaming:
            writer.body = msg.body^
            msg.body = List[Byte]()
        var ticket = msg.body_ticket^
        msg.body_ticket = _CapacityTicket()
        var valid = len(writer.body) <= self.config.max_response_body
        try:
            self._inject_alt_svc_for_tls(idx, writer)
        except:
            valid = False
        var limit = self._http2_response_header_room(idx)
        var fields = encode_http2_response_headers(
            writer,
            is_head,
            self._tick_date,
            limit,
            self.config.max_response_headers_count,
            streaming=streaming,
        )
        if not valid or not fields.is_valid():
            writer._drop_body()
            writer._drop_headers()
            ticket.release()
            self._fail_http2_detached(idx, stream_id)
            return
        var charge = len(fields.fields)
        if not self._budget.try_reserve(charge):
            writer._drop_body()
            writer._drop_headers()
            ticket.release()
            self._fail_http2_detached(idx, stream_id)
            return
        self._http2_detached[position].status = writer.status
        self._http2_detached[position].allows_body = fields.send_body
        self._http2_detached[position].initial_field_count = fields.field_count
        self._http2_detached[position].initial_field_bytes = (
            charge + 24 * fields.field_count
        )
        self._http2_detached[position].headers = writer.headers^
        writer.headers = Headers()
        var raw = fields.fields^
        fields.fields = List[Byte]()
        if not self._conns[idx].http2_responses.enqueue_streaming(
            stream_id,
            raw^,
            fields.field_count,
            limit,
            self.config.max_response_headers_count,
            max(1, limit),
            budget=self._budget.copy(),
        ):
            self._budget.release(charge)
            writer._drop_body()
            ticket.release()
            self._fail_http2_detached(idx, stream_id)
            return
        self._conns[idx].http2_response_bytes_reserved += charge
        if not fields.send_body:
            writer._drop_body()
            ticket.release()
            if not streaming:
                _ = self._conns[idx].http2_responses.finish(stream_id)
            return
        if not streaming:
            var body = writer.body^
            writer.body = List[Byte]()
            if not self._conns[idx].http2_responses.push_body(
                stream_id, body^, ticket^
            ):
                self._cancel_http2_detached(idx, stream_id, UInt32(2))
                return
            _ = self._conns[idx].http2_responses.finish(stream_id)

    def _finish_http2_detached(
        mut self, idx: Int, stream_id: UInt32, var trailers: Headers
    ) raises NetError:
        var position = self._find_http2_detached(idx, stream_id)
        if not self._http2_detached[position].allows_body:
            _ = self._conns[idx].http2_responses.finish(stream_id)
            return
        if len(trailers) == 0:
            _ = self._conns[idx].http2_responses.finish(stream_id)
            return
        var writer = ResponseWriter(0)
        writer.status = self._http2_detached[position].status
        var headers_ptr = Pointer(to=self._http2_detached[position].headers)
        writer.headers = headers_ptr.unsafe_take_pointee()
        headers_ptr.unsafe_write(Headers())
        writer.trailers = trailers^
        var local_bytes = (
            self.config.max_response_headers_bytes
            - self._http2_detached[position].initial_field_bytes
        )
        var field_room = (
            self.config.max_response_headers_count
            - self._http2_detached[position].initial_field_count
        )
        var byte_room = min(
            local_bytes,
            Int(
                self._conns[idx]
                .http2_session.value()
                .peer_settings()
                .max_header_list_size
            ),
        )
        var fields = encode_http2_response_trailers(
            writer,
            self._http2_detached[position].is_head,
            byte_room,
            field_room,
        )
        if not fields.is_valid():
            writer._drop_headers()
            self._cancel_http2_detached(idx, stream_id, UInt32(2))
            return
        var charge = len(fields.fields)
        if not self._budget.try_reserve(charge):
            writer._drop_headers()
            self._cancel_http2_detached(idx, stream_id, UInt32(2))
            return
        var raw = fields.fields^
        fields.fields = List[Byte]()
        if not self._conns[idx].http2_responses.finish(
            stream_id, raw^, fields.field_count, byte_room, field_room
        ):
            self._budget.release(charge)
            self._cancel_http2_detached(idx, stream_id, UInt32(2))
            return
        self._conns[idx].http2_response_bytes_reserved += charge

    def _process_http2_detached(mut self, now: Int) raises NetError:
        var index = 0
        while index < len(self._http2_detached):
            var target = self._http2_detached[index].target.copy()
            var idx = target.slot
            var stream_id = UInt32(target.stream_id)
            var addr = self._http2_detached[index].addr
            if not self._conns[idx].active or target != _DetachTarget.http2(
                idx, self._conns[idx].token.generation, stream_id
            ):
                self._remove_http2_detached(index)
                continue
            if now >= self._http2_detached[index].deadline:
                self._cancel_http2_detached(idx, stream_id, UInt32(8))
                if self._conns[idx].active:
                    self._pump_send(idx, True)
                continue
            var batch = _take_batch(_detach_state(addr))
            if batch.target != target:
                self._cancel_http2_detached(idx, stream_id, UInt32(8))
                continue
            if (
                len(batch.messages) == 0
                and batch.terminal_kind == MSG_KIND_NONE
            ):
                index += 1
                continue
            self._http2_detached[index].deadline = deadline_from_now(
                self.config.detached_response_timeout
            )
            batch.messages.reverse()
            while len(batch.messages) > 0:
                var msg = batch.messages.pop()
                var position = self._find_http2_detached(idx, stream_id)
                if position < 0 or not self._conns[idx].active:
                    break
                if msg.kind == MSG_KIND_RESPOND:
                    self._begin_http2_detached(idx, stream_id, msg, False)
                elif msg.kind == MSG_KIND_START:
                    self._begin_http2_detached(idx, stream_id, msg, True)
                elif msg.kind == MSG_KIND_CHUNK:
                    if not self._http2_detached[position].allows_body:
                        _consume_detach_bytes(addr, len(msg.body))
                        continue
                    var body = msg.body^
                    msg.body = List[Byte]()
                    var ticket = msg.body_ticket^
                    msg.body_ticket = _CapacityTicket()
                    if not self._conns[idx].http2_responses.push_body(
                        stream_id, body^, ticket^
                    ):
                        self._cancel_http2_detached(idx, stream_id, UInt32(2))
            var position = self._find_http2_detached(idx, stream_id)
            if position >= 0 and batch.terminal_kind != MSG_KIND_NONE:
                if batch.terminal_kind == MSG_KIND_FINISH:
                    var trailers = batch.trailers^
                    batch.trailers = Headers()
                    self._finish_http2_detached(idx, stream_id, trailers^)
                else:
                    var state = _detach_state(addr)
                    state[].mutex.lock()
                    var failed = state[].cancelled
                    state[].mutex.unlock()
                    self._cancel_http2_detached(
                        idx, stream_id, UInt32(2) if failed else UInt32(8)
                    )
            if self._conns[idx].active:
                self._drain_http2_responses(idx)
                self._pump_send(idx, True)
                if self._conns[idx].active:
                    self._sync_interests(idx)
                    self._arm_deadline(idx)
            position = self._find_http2_detached(idx, stream_id)
            if position >= 0:
                index = position + 1

    def _flush_http2_control_output(
        mut self, idx: Int, var control_output: List[Byte]
    ) raises NetError -> Bool:
        if len(control_output) == 0:
            return True
        if not self._conns[idx].append_pending(control_output^, self._budget):
            self._close_conn(idx)
            return False
        self._conns[idx].state = STATE_SENDING_HTTP2_CONTROL
        if self._conns[idx].write_at == NO_DEADLINE:
            self._conns[idx].write_at = deadline_from_now(
                self.config.write_deadline
            )
        return True

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
        if not self._conns[idx].http2_deflater:
            return
        # the scheduler encodes any deferred HEADERS or trailer blocks
        # (RFC 7541 §4.2). If the peer shrunk the table while a response
        # was flow-blocked, the next encoded block must prefix the
        # dynamic-table-size update or a compliant inflater rejects it.
        var current_table_size = Int(
            self._conns[idx]
            .http2_session.value()
            .peer_settings()
            .header_table_size
        )
        if (
            not self._conns[idx]
            .http2_deflater.value()
            .set_max_table_size(current_table_size)
        ):
            self._close_conn(idx)
            return
        var batch = self._conns[idx].http2_responses.drain(
            self._conns[idx].http2_session.value(),
            self._conns[idx].http2_deflater.value(),
            self._tick_date,
            16384,
            65536,
        )
        for item in batch.consumed_bytes:
            var position = self._find_http2_detached(idx, item.stream_id)
            if position >= 0:
                _consume_detach_bytes(
                    self._http2_detached[position].addr, item.amount
                )
                self._http2_detached[position].deadline = deadline_from_now(
                    self.config.detached_response_timeout
                )
        for stream_id in batch.failed_streams:
            var position = self._find_http2_detached(idx, stream_id)
            if position >= 0:
                _mark_detach_cancelled(self._http2_detached[position].addr)
        for stream_id in batch.completed_streams:
            var position = self._find_http2_detached(idx, stream_id)
            if position >= 0:
                var addr = self._http2_detached[position].addr
                if not self._http2_detached[position].allows_body:
                    _mark_detach_cancelled(addr)
                self._http2_detached[position].addr = 0
                _release_detach_state(addr, from_sender=False)
                self._remove_http2_detached(position)
        if batch.released_bytes > 0:
            self._budget.release(batch.released_bytes)
            self._conns[
                idx
            ].http2_response_bytes_reserved -= batch.released_bytes
        if batch.deflater_failed:
            self._close_conn(idx)
            return
        if (
            self._conns[idx].http2_session.value().is_failed()
            and not self._conns[idx].http2_session.value().is_draining()
        ):
            var goaway = (
                self._conns[idx]
                .http2_session.value()
                .begin_shutdown(UInt32(11))
            )
            batch.wire.extend(Span(goaway))
        if len(batch.wire) == 0:
            if self._conns[idx].http2_responses.has_buffered_responses():
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
            self._conns[idx].idle_at = NO_DEADLINE
            if not self._has_http2_detached(idx):
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
            if self._conns[idx].body_decoder:
                limit = (
                    self._conns[idx].body_decoder.value().read_allowance(limit)
                )
                var wire_free = (
                    self._conns[idx].buf.capacity()
                    - self._conns[idx].buffered_len()
                )
                if limit > wire_free:
                    limit = min(
                        limit,
                        max(
                            0,
                            self._budget.remaining()
                            - self._conns[idx].buffered_len(),
                        ),
                    )
                if limit == 0:
                    self._conns[
                        idx
                    ].body_blocked_budget = self._budget.remaining()
                    break
            if self._conns[idx].tls_read_retry_length > limit:
                if self._conns[idx].body_decoder and (
                    self._conns[idx].tls_read_retry_length
                    <= min(room, READ_BUFFER_SIZE)
                ):
                    self._conns[
                        idx
                    ].body_blocked_budget = self._budget.remaining()
                else:
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
                if first and not self._conns[idx].body_decoder:
                    self._conns[idx].header_at = deadline_from_now(
                        self.config.header_deadline
                    )
                if count < limit or self.config.enable_request_body_streaming:
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

    def _reset_http2_response(mut self, idx: Int, stream_id: UInt32):
        self._drop_http2_detached(idx, stream_id)
        var result = self._conns[idx].http2_responses.on_peer_reset(stream_id)
        self._budget.release(result.released_bytes)
        self._conns[idx].http2_response_bytes_reserved -= result.released_bytes

    def _consume_receive(mut self, idx: Int, count: Int):
        var old_capacity = self._conns[idx].buf.capacity()
        self._conns[idx].drain_prefix(count)
        self._budget.release(old_capacity - self._conns[idx].buf.capacity())

    def _register_http2_body_input(mut self, idx: Int):
        for existing in self._request_body_conns:
            if existing == idx:
                return
        self._request_body_conns.append(idx)

    def _flush_http2_body_credit(mut self, idx: Int) raises NetError:
        var output = self._conns[idx].http2_session.value().flush_body_credit()
        if not self._conns[idx].http2_session.value().has_request_inputs():
            self._remove_request_body(idx)
        _ = self._flush_http2_control_output(idx, output^)
        if self._conns[idx].active:
            self._arm_deadline(idx)
            self._sync_interests(idx)

    def _retry_request_body_budget(mut self) raises NetError:
        var available = self._budget.remaining()
        for idx in self._request_body_conns:
            if self._conns[idx].protocol == PROTOCOL_HTTP2:
                continue
            var blocked_at = self._conns[idx].body_blocked_budget
            if blocked_at >= 0 and available > blocked_at:
                self._conns[idx].body_blocked_budget = -1
                self._push_urgent(idx)
                self._sync_interests(idx)

    def _remove_request_body(mut self, idx: Int):
        for i in range(len(self._request_body_conns)):
            if self._request_body_conns[i] == idx:
                _ = self._request_body_conns.pop(i)
                return

    def _cancel_request_body(mut self, idx: Int):
        if self._conns[idx].body_pipe:
            self._conns[idx].body_pipe.value().cancel()
        self._conns[idx].body_pipe = None
        self._conns[idx].body_decoder = None
        self._conns[idx].body_receiver_after_response = False
        self._conns[idx].body_blocked_budget = -1
        self._conns[idx].body_at = NO_DEADLINE
        self._remove_request_body(idx)

    def _feed_request_body(
        mut self, idx: Int, initial: Bool = False
    ) raises NetError:
        var result = (
            self._conns[idx]
            .body_decoder.value()
            .feed(Span(self._conns[idx].buf), self.config)
        )
        var blocked_budget = self._budget.remaining()
        self._consume_receive(idx, result.consumed)
        if result.blocked:
            self._conns[idx].body_blocked_budget = blocked_budget
        elif result.consumed > 0 or result.complete:
            self._conns[idx].body_blocked_budget = -1
        if result.error:
            var status = result.error.value().status
            self._cancel_request_body(idx)
            if initial:
                self._send_error(idx, status)
            else:
                self._close_conn(idx)
            return
        if result.consumed > 0:
            self._conns[idx].body_at = deadline_from_now(
                self.config.body_deadline
            )
        if result.complete:
            self._conns[idx].body_decoder = None
            self._conns[idx].body_pipe.value()._stop_loop_wakeup()
            self._conns[idx].body_at = NO_DEADLINE
            self._remove_request_body(idx)
            if self._conns[idx].state == STATE_READING:
                if self._conns[idx].body_receiver_after_response and (
                    self._conns[idx].should_close
                    or self._shutdown_at != NO_DEADLINE
                ):
                    self._conns[idx].body_pipe = None
                    self._conns[idx].body_receiver_after_response = False
                    self._finish_connection(idx)
                else:
                    self._resume_http1_reading(idx)
        elif self._conns[idx].read_eof:
            self._close_conn(idx)

    def _drive_request_body(
        mut self, idx: Int, readable: Bool, writable: Bool, now: Int
    ) raises NetError:
        self._feed_request_body(idx)
        if not self._conns[idx].active or not self._conns[idx].body_decoder:
            return
        var event = (
            self._conns[idx].read_ready(readable, writable)
            or self._conns[idx].tls_pending() > 0
        )
        self._pump_read(idx, event, now)
        if self._conns[idx].active:
            self._feed_request_body(idx)

    def _dispatch_streaming_request[
        H: Handler
    ](mut self, idx: Int, mut handler: H) raises:
        if (
            self._conns[idx].request_head.value().head.expect_100
            and not self._conns[idx].sent_100
        ):
            if not self._send_100(idx):
                return
        var head = self._conns[idx].request_head.take()
        var close = head.head.should_close
        var pipe = _BodyPipe(
            self.config.max_body_bytes,
            self._budget.copy(),
            self._wakeup_channel.write_fd(),
        )
        self._conns[idx].body_pipe = pipe.copy()
        self._conns[idx].body_decoder = _BodyDecoder(
            pipe.copy(), head.head.chunked, head.head.content_length
        )
        self._request_body_conns.append(idx)
        self._conns[idx].header_at = NO_DEADLINE
        self._conns[idx].idle_at = NO_DEADLINE
        self._conns[idx].body_at = deadline_from_now(self.config.body_deadline)
        self._consume_receive(idx, head.head.header_end)
        self._conns[idx].request_scan = _RequestScan.start()
        var req = Request(
            String(head.head.method),
            String(head.head.target),
            String(head.head.path),
            String(head.head.query),
            head.head.version.copy(),
        )
        req.scheme = String(head.head.scheme)
        req.authority = String(head.head.authority)
        req.headers = head.take_headers()
        req._body_pipe = pipe^
        self._feed_request_body(idx, initial=True)
        if (
            not self._conns[idx].active
            or self._conns[idx].state != STATE_READING
        ):
            return
        self._conns[idx].requests_this_tick += 1
        self._respond(
            idx, ParseResult.complete(req^, 0, False, close), close, handler
        )

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
            if self._conns[idx].body_decoder:
                self._feed_request_body(idx)
                if not self._conns[idx].active or self._conns[idx].body_decoder:
                    return
            self._conns[idx].body_pipe = None
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
            if self.config.enable_request_body_streaming:
                self._dispatch_streaming_request(idx, handler)
                return
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
            is_head=is_head,
        )
        writer._set_body_budget(self._budget.copy())
        writer._set_request_body_pipe(req._body_pipe.copy())
        var is_connect = req.method == "CONNECT"
        self._conns[idx].is_connect = is_connect
        writer._set_hijack_context(
            _HijackContext(
                is_connect,
                req.version == HttpVersion.http11(),
                self.control.copy(),
                String(self._tick_date),
                self.config.max_response_headers_count,
                self.config.max_response_headers_bytes,
            )
        )
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
            writer._cancel_hijack()
            writer._drop_body()
            writer._drop_headers()
            self._send_error(idx, 500, is_head=is_head)
            return

        self._conns[idx].body_receiver_after_response = (
            self._conns[idx].body_pipe
            and self._conns[idx].body_pipe.value().has_detached_reader()
            and not writer.is_detached()
        )
        if (
            self._conns[idx].body_decoder
            and not writer.is_detached()
            and not self._conns[idx].body_pipe.value().is_discarded()
            and not self._conns[idx].body_receiver_after_response
        ):
            writer.set_should_close(True)
        _ = req^
        self._release_http1_body(idx)
        if writer.is_hijacked():
            if (
                writer._request_body_pipe
                and not writer._request_body_pipe.value()._can_hijack()
            ):
                writer._cancel_hijack()
                writer._drop_body()
                writer._drop_headers()
                self._send_error(idx, 500, is_head=is_head)
                return
            writer._drop_body()
            writer._drop_headers()
            self._conns[idx].hijack_state_addr = writer._take_hijack_state()
            self._conns[idx].state = STATE_HIJACKING_FLUSH
            self._conns[idx].header_at = NO_DEADLINE
            self._conns[idx].body_at = NO_DEADLINE
            self._conns[idx].idle_at = NO_DEADLINE
            self._conns[idx].write_at = deadline_from_now(
                self.config.write_deadline
            )
            self._hijacking_conns.append(idx)
            self._pump_hijack(idx)
            if self._conns[idx].active:
                self._arm_deadline(idx)
                self._sync_interests(idx)
            return
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
            if not self._conns[idx].body_decoder:
                self._conns[idx].body_at = NO_DEADLINE
            self._conns[idx].idle_at = NO_DEADLINE
            self._conns[idx].write_at = NO_DEADLINE
            self._detached_conns.append(idx)
            self._arm_deadline(idx)
            self._sync_interests(idx)
            return

        if is_connect and 200 <= writer.status < 300:
            writer._cancel_detach()
            writer._drop_body()
            writer._drop_headers()
            self._send_error(idx, 500, is_head=is_head)
            return
        if (
            len(writer.body) > cap
            or not writer._reconcile_body_budget()
            or not writer.headers._adopt_capacity_budget(
                writer._body_budget.copy()
            )
            or not writer.trailers._adopt_capacity_budget(
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
        self._conns[idx].stream_known_length = -1
        self._conns[idx].stream_pending_body = 0
        self._conns[idx].stream_has_body = False
        self._conns[idx].detach_at = NO_DEADLINE
        self._conns[idx].requests_served += 1
        if (
            self._conns[idx].body_decoder
            and not self._conns[idx].body_pipe.value().is_discarded()
        ):
            self._conns[idx].should_close = True
        if self._conns[idx].should_close or self._shutdown_at != NO_DEADLINE:
            self._finish_connection(idx)
            return
        self._resume_http1_reading(idx)

    def _remove_hijacking_conn(mut self, idx: Int):
        for position in range(len(self._hijacking_conns)):
            if self._hijacking_conns[position] == idx:
                _ = self._hijacking_conns.pop(position)
                return

    def _discard_hijack(mut self, idx: Int):
        var addr = self._conns[idx].hijack_state_addr
        if addr != 0:
            self._conns[idx].hijack_state_addr = 0
            _cancel_hijack_state(addr)
            _release_hijack_state(addr, from_sender=False)
            self._remove_hijacking_conn(idx)

    def _process_hijacks(mut self) raises NetError:
        var position = 0
        while position < len(self._hijacking_conns):
            var idx = self._hijacking_conns[position]
            var state = _hijack_state(self._conns[idx].hijack_state_addr)
            state[].mutex.lock()
            var cancelled = state[].cancelled
            state[].mutex.unlock()
            if cancelled:
                self._close_conn(idx)
            else:
                position += 1

    def _pump_hijack(mut self, idx: Int) raises NetError:
        var addr = self._conns[idx].hijack_state_addr
        var state = _hijack_state(addr)
        state[].mutex.lock()
        var cancelled = state[].cancelled
        state[].mutex.unlock()
        if (
            cancelled
            or self._conns[idx].read_eof
            or self._conns[idx].peer_hangup
            or now_ns() >= min(self._conns[idx].write_at, self._shutdown_at)
        ):
            self._close_conn(idx)
            return
        var allowance = (
            self.config.max_bytes_per_tick - self._conns[idx].bytes_this_tick
        )
        if not self._conns[idx].pending_done():
            if allowance <= 0:
                return
            try:
                var count = self._conns[idx].try_write_pending_capped(allowance)
                self._conns[idx].bytes_this_tick += count
            except e:
                if e.kind == NetErrorKind.timeout():
                    return
                self._close_conn(idx)
                return
            if self._conns[idx].tls_write_closed:
                self._close_conn(idx)
                return
            if not self._conns[idx].pending_done():
                return
        var capacity = self._conns[idx].pending.capacity()
        if capacity > 0:
            self._conns[idx].clear_pending()
            self._budget.release(capacity)
        allowance = (
            self.config.max_bytes_per_tick - self._conns[idx].bytes_this_tick
        )
        state[].mutex.lock()
        if state[].pending_offset < len(state[].pending_response):
            var bound = min(
                allowance,
                len(state[].pending_response) - state[].pending_offset,
            )
            if self._conns[idx].tls_write_retry_length > 0:
                bound = self._conns[idx].tls_write_retry_length
                if bound > allowance:
                    state[].mutex.unlock()
                    return
            if bound <= 0:
                state[].mutex.unlock()
                return
            try:
                var count = self._conns[idx].try_write_bytes(
                    Span(state[].pending_response)[
                        state[].pending_offset : state[].pending_offset + bound
                    ]
                )
                state[].pending_offset += count
                self._conns[idx].bytes_this_tick += count
            except e:
                state[].mutex.unlock()
                if e.kind == NetErrorKind.timeout():
                    return
                self._close_conn(idx)
                return
            if self._conns[idx].tls_write_closed:
                state[].mutex.unlock()
                self._close_conn(idx)
                return
        var done = state[].pending_offset >= len(state[].pending_response)
        if done:
            state[].pending_response = List[Byte]()
            state[].response_ticket.release()
        state[].mutex.unlock()
        if not done:
            return
        var peer_hangup: Bool
        try:
            peer_hangup = Reactor._probe_hangup(self._conns[idx].raw_fd())
        except error:
            _ = error
            self._close_conn(idx)
            return
        if peer_hangup:
            self._close_conn(idx)
            return
        self._note_shutdown(now_ns())
        if now_ns() >= min(self._conns[idx].write_at, self._shutdown_at):
            self._close_conn(idx)
            return
        var moved_capacity = (
            self._conns[idx].buf.capacity()
            + self._conns[idx].tls_read_buffer.capacity()
        )
        var connection = self._conns[idx]._take_hijacked_connection()
        self._conns[idx].hijack_state_addr = 0
        self._conns[idx].state = STATE_HIJACKED
        self._remove_hijacking_conn(idx)
        self._budget.release(moved_capacity)
        try:
            self._close_conn(idx)
        except e:
            _cancel_hijack_state(addr)
            _release_hijack_state(addr, from_sender=False)
            raise e^
        _ = _complete_hijack_state(addr, connection^)
        _release_hijack_state(addr, from_sender=False)

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
            # Streaming can outlive one write deadline while batches keep flushing.
            if not self._conns[idx].http2_responses.has_buffered_responses():
                self._conns[idx].write_at = NO_DEADLINE
            if self._conns[idx].http2_responses.queued_count() == 0:
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
            if self._conns[idx].stream_pending_body > 0:
                _consume_detach_bytes(
                    self._conns[idx].detach_state_addr,
                    self._conns[idx].stream_pending_body,
                )
                self._conns[idx].stream_pending_body = 0
            if not self._conns[idx].stream_finished:
                self._conns[idx].write_at = NO_DEADLINE
                self._conns[idx].detach_at = deadline_from_now(
                    self.config.stream_idle_timeout
                )
                return
            self._complete_stream(idx)
            return
        self._conns[idx].requests_served += 1
        if self._conns[idx].body_receiver_after_response:
            if self._conns[idx].body_decoder:
                self._resume_http1_reading(idx)
                return
            self._conns[idx].body_pipe = None
            self._conns[idx].body_receiver_after_response = False
        if (
            self._conns[idx].body_decoder
            and not self._conns[idx].body_pipe.value().is_discarded()
        ):
            self._conns[idx].should_close = True
        if self._conns[idx].should_close or self._shutdown_at != NO_DEADLINE:
            self._finish_connection(idx)
            return
        self._resume_http1_reading(idx)

    def _resume_http1_reading(mut self, idx: Int):
        self._conns[idx].state = STATE_READING
        self._conns[idx].is_head = False
        self._conns[idx].sent_100 = False
        self._conns[idx].write_at = NO_DEADLINE
        if self._conns[idx].body_decoder:
            self._conns[idx].header_at = NO_DEADLINE
            self._conns[idx].idle_at = NO_DEADLINE
        else:
            self._conns[idx].body_pipe = None
            self._conns[idx].body_receiver_after_response = False
            self._conns[idx].body_at = NO_DEADLINE
            self._conns[idx].header_at = (
                deadline_from_now(self.config.header_deadline) if self._conns[
                    idx
                ].buffered_len()
                > 0 else NO_DEADLINE
            )
            self._conns[idx].idle_at = deadline_from_now(
                self.config.idle_timeout
            )
        if self._conns[idx].buffered_len() > 0:
            self._push_urgent(idx)

    def _mark_detached_cancelled(mut self, idx: Int):
        if idx < 0 or idx >= len(self._conns):
            return
        var addr = self._conns[idx].detach_state_addr
        if addr != 0:
            _mark_detach_cancelled(addr)

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
        self._process_http2_detached(now)
        self._process_http3_inputs()
        self._process_http3_detached(now)
        self._flush_quic()
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
                if batch.target != _DetachTarget.http1(
                    idx, self._conns[idx].token.generation
                ):
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
                    self._handle_detached_chunk(idx, msg, batch.retains_credit)
                else:
                    self._handle_detached_abort(idx)
                    break

            if (
                batch.terminal_kind != MSG_KIND_NONE
                and self._conns[idx].active
                and self._conns[idx].detach_state_addr == addr
                and batch.target
                == _DetachTarget.http1(idx, self._conns[idx].token.generation)
            ):
                if batch.terminal_kind == MSG_KIND_FINISH:
                    self._handle_detached_finish(idx, batch.trailers)
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
        var req_close = (
            self._conns[idx].req_close
            or msg.should_close
            or (
                self._conns[idx].body_decoder
                and not self._conns[idx].body_pipe.value().is_discarded()
            )
        )
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

        if self._conns[idx].is_connect and 200 <= rw.status < 300:
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
        var req_close = (
            self._conns[idx].req_close
            or msg.should_close
            or (
                self._conns[idx].body_decoder
                and not self._conns[idx].body_pipe.value().is_discarded()
            )
        )
        var rw = ResponseWriter(self.config.max_response_body)
        rw.status = msg.status
        var h = msg.headers^
        msg.headers = Headers()
        rw.headers = h^
        rw.set_should_close(req_close or (self._shutdown_at != NO_DEADLINE))

        if self._conns[idx].is_connect and 200 <= rw.status < 300:
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

        self._conns[idx].stream_header_count = len(rw.headers)
        self._conns[idx].stream_header_bytes = 0
        for i in range(len(rw.headers)):
            self._conns[idx].stream_header_bytes += (
                rw.headers._names[i].byte_length()
                + rw.headers.value_byte_length(i)
                + 4
            )

        self._conns[idx].state = STATE_STREAMING
        self._conns[idx].stream_finished = False
        self._conns[idx].stream_known_length = _declared_content_length(
            rw.headers
        )
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
        mut self, idx: Int, mut msg: DetachMessage, retains_credit: Bool
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
            if retains_credit:
                _consume_detach_bytes(
                    self._conns[idx].detach_state_addr, len(msg.body)
                )
            return

        var body_length = len(msg.body)
        var wire: List[Byte]
        try:
            if self._conns[idx].stream_known_length >= 0:
                wire = msg.body^
                msg.body = List[Byte]()
                msg.body_ticket.amount = 0
            else:
                wire = _encode_chunk_budgeted(Span(msg.body), self._budget)
        except e:
            _ = e
            self._handle_detached_abort(idx)
            return
        if not self._conns[idx]._append_reserved_pending(wire^, self._budget):
            self._close_conn(idx)
            return

        if retains_credit:
            self._conns[idx].stream_pending_body += body_length
        self._conns[idx].write_at = deadline_from_now(
            self.config.write_deadline
        )
        self._conns[idx].detach_at = deadline_from_now(
            self.config.stream_idle_timeout
        )

    def _handle_detached_finish(
        mut self,
        idx: Int,
        trailers: Headers,
    ) raises NetError:
        if not self._conns[idx].active:
            return
        if self._conns[idx].state != STATE_STREAMING:
            return
        if self._conns[idx].stream_finished:
            return
        self._conns[idx].stream_finished = True
        if not self._conns[idx].stream_has_body:
            return

        if self._conns[idx].stream_known_length >= 0:
            return

        var wire: List[Byte]
        try:
            wire = _encode_chunk_end_budgeted(
                self._budget,
                trailers,
                self.config.max_response_headers_count
                - self._conns[idx].stream_header_count,
                self.config.max_response_headers_bytes
                - self._conns[idx].stream_header_bytes,
            )
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
        for i in range(len(self._http3_detached)):
            best = _sooner(best, self._http3_detached[i].deadline, now)
        for i in range(len(self._http3_inputs)):
            if (
                self._http3_inputs[i].wire_eof
                and not self._http3_inputs[i].eof_published
            ):
                best = _sooner(
                    best, self._http3_inputs[i].eof_admission_at, now
                )
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
