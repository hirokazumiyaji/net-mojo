"""Single event-loop HTTP/1.1 origin server (poll baseline).

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

from net import TCPListener, Timeout, listen_tcp
from net._reactor import Reactor, ReactorToken
from net.error import NetError, NetErrorKind

from ._buffer import BufferBudget
from ._connection import (
    HttpConnection,
    STATE_READING,
    STATE_SENDING,
    STATE_SENDING_100,
)
from ._deadline import NO_DEADLINE, deadline_from_now, now_ns
from ._encoder import (
    current_http_date,
    encode_100_continue,
    encode_error,
    encode_response,
)
from ._parser import ParseResult, parse_head, parse_one
from .config import ServerConfig
from .handler import Handler
from .response import ResponseWriter


comptime _TICK_POLL_CAP_MS: Int = 100
comptime _READ_CHUNK: Int = 8192
comptime _SHUTDOWN_QUIET_MS: Int = 10


struct ServerControl(Movable):
    """Shutdown handle. Only the request crosses threads (flag polled on
    a bounded tick); the loop owner performs every socket operation."""

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

    def __init__(out self, var config: ServerConfig):
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
        for i in range(len(self._conns)):
            if self._conns[i].active:
                self._conns[i].reset_tick()
        var events = self._reactor.wait(self._compute_timeout(now, timeout))
        now = now_ns()
        if self._listener:
            for i in range(len(events)):
                if events[i].token == self._listener_token:
                    self._accept_pending(now)
                    break
        for i in range(len(self._conns)):
            if not self._conns[i].active:
                continue
            var event = False
            for k in range(len(events)):
                if events[k].token == self._conns[i].token:
                    event = True
                    break
            if (
                event
                or self._conns[i].buffered_len() > 0
                or self._conns[i].pending_remaining() > 0
            ):
                self._drive_conn(i, event, handler, now)
        self._check_deadlines(now_ns())
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

    def _ensure_slot_map(mut self, slot: Int):
        while len(self._slot_map) <= slot:
            self._slot_map.append(-1)

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
        var token = self._conns[idx].token.copy()
        _ = self._reactor.remove(token)
        if token.slot >= 0 and token.slot < len(self._slot_map):
            if self._slot_map[token.slot] == idx:
                self._slot_map[token.slot] = -1
        self._budget.release(
            self._conns[idx].buffered_len()
            + self._conns[idx].pending_remaining()
        )
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

    def _send_error(mut self, idx: Int, status: Int) raises NetError:
        var wire = encode_error(status, True, self._tick_date)
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
    ](mut self, idx: Int, event: Bool, mut handler: H, now: Int,) raises:
        if not self._conns[idx].active:
            return
        if (
            self._conns[idx].state == STATE_SENDING
            or self._conns[idx].state == STATE_SENDING_100
        ):
            self._pump_send(idx, event)
            if not self._conns[idx].active:
                return
        if self._conns[idx].state == STATE_READING:
            self._pump_read(idx, event, now)
            if not self._conns[idx].active:
                return
            self._pump_parse(idx, handler, now)
            if not self._conns[idx].active:
                return
            self._pump_send(idx, True)
            if not self._conns[idx].active:
                return
        self._sync_interests(idx)

    def _pump_read(mut self, idx: Int, event: Bool, now: Int) raises NetError:
        if not event:
            return
        if self._conns[idx].read_eof:
            return
        while self._conns[idx].bytes_this_tick < self.config.max_bytes_per_tick:
            try:
                var chunk = self._conns[idx].try_read_bytes(_READ_CHUNK)
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
                if not self._budget.try_reserve(len(chunk)):
                    self._admit_over_budget(idx)
                    return
                var first = self._conns[idx].buffered_len() == 0
                self._conns[idx].append_bytes(Span(chunk))
                self._conns[idx].bytes_this_tick += len(chunk)
                if first:
                    self._conns[idx].header_at = deadline_from_now(
                        self.config.header_deadline
                    )
                if len(chunk) < _READ_CHUNK:
                    break
            except e:
                if e.kind == NetErrorKind.timeout():
                    break
                self._close_conn(idx)
                return

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
                break
            if head.is_error():
                var head_status = head.take_error().status
                self._send_error(idx, head_status)
                return
            var content_length = head.head.content_length
            if (
                content_length > 0
                and self._budget.used + content_length > self._budget.total
            ):
                self._send_error(idx, 503)
                return
            if head.head.expect_100 and not self._conns[idx].sent_100:
                if not self._send_100(idx):
                    return
            if self._conns[idx].body_at == NO_DEADLINE:
                self._conns[idx].body_at = deadline_from_now(
                    self.config.body_deadline
                )
            var result = parse_one(Span(self._conns[idx].buf), self.config)
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
        try:
            var written = self._conns[idx].try_write_bytes(Span(cont))
            if written < len(cont):
                var rest = List[Byte]()
                for i in range(written, len(cont)):
                    rest.append(cont[i])
                self._conns[idx].set_pending(rest^)
                self._conns[idx].state = STATE_SENDING_100
                self._conns[idx].write_at = deadline_from_now(
                    self.config.write_deadline
                )
                self._sync_interests(idx)
                return False
        except e:
            if e.kind == NetErrorKind.timeout():
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
        var cap = self.config.max_response_body
        var room = self._budget.remaining()
        if room < cap:
            cap = room
        if cap < 0:
            cap = 0
        var writer = ResponseWriter(cap)
        # The wire must advertise close whenever the connection will not
        # persist, even when the handler leaves the writer untouched.
        if req_close or self._shutdown_at != NO_DEADLINE:
            writer.set_should_close(True)
        try:
            handler.handle(req^, writer)
        except e:
            _ = e
            self._send_error(idx, 500)
            return
        if len(writer.headers) > self.config.max_response_headers_count:
            self._send_error(idx, 500)
            return
        var header_bytes = 0
        for i in range(len(writer.headers)):
            header_bytes += (
                writer.headers.name_at(i).byte_length()
                + writer.headers.value_at(i).byte_length()
                + 4
            )
        if header_bytes > self.config.max_response_headers_bytes:
            self._send_error(idx, 500)
            return
        var wire: List[Byte]
        try:
            wire = encode_response(writer, is_head, self._tick_date)
        except e:
            _ = e
            self._send_error(idx, 500)
            return
        if not self._budget.try_reserve(len(wire)):
            self._send_error(idx, 500)
            return
        self._conns[idx].set_pending(wire^)
        self._conns[idx].should_close = (
            req_close
            or writer.should_close
            or self._conns[idx].read_eof
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
            try:
                var n = self._conns[idx].try_write_pending()
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
        self._conns[idx].sent_100 = False
        self._conns[idx].header_at = NO_DEADLINE
        self._conns[idx].body_at = NO_DEADLINE
        self._conns[idx].write_at = NO_DEADLINE
        self._conns[idx].idle_at = deadline_from_now(self.config.idle_timeout)

    def _check_deadlines(mut self, now: Int) raises NetError:
        for i in range(len(self._conns)):
            if not self._conns[i].active:
                continue
            if self._shutdown_at != NO_DEADLINE and now >= self._shutdown_at:
                self._close_conn(i)
                continue
            if self._conns[i].state == STATE_READING:
                if self._conns[i].buffered_len() > 0:
                    if (
                        self._conns[i].body_at != NO_DEADLINE
                        and now >= self._conns[i].body_at
                    ):
                        self._close_conn(i)
                        continue
                    if (
                        self._conns[i].header_at != NO_DEADLINE
                        and now >= self._conns[i].header_at
                    ):
                        self._close_conn(i)
                        continue
                else:
                    if now >= self._conns[i].idle_at:
                        self._close_conn(i)
                        continue
            else:
                if (
                    self._conns[i].write_at != NO_DEADLINE
                    and now >= self._conns[i].write_at
                ):
                    self._close_conn(i)
                    continue

    def _compute_timeout(
        self, now: Int, timeout: Optional[Timeout]
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
        for i in range(len(self._conns)):
            if not self._conns[i].active:
                continue
            var marks = List[Int]()
            marks.append(self._conns[i].idle_at)
            marks.append(self._conns[i].header_at)
            marks.append(self._conns[i].body_at)
            marks.append(self._conns[i].write_at)
            for k in range(len(marks)):
                if marks[k] == NO_DEADLINE:
                    continue
                var left_ms = (marks[k] - now) // 1_000_000
                if left_ms < 0:
                    left_ms = 0
                if left_ms < best:
                    best = Int(left_ms)
        if best < 0:
            best = 0
        return Timeout.milliseconds(UInt64(best))


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
