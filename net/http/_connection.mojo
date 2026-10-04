"""Per-connection state for the HTTP server loop.

A connection owns its socket, its unprocessed wire bytes, and at most
one queued response. All moves are whole values; nothing borrows across
connections, so the table never shares ownership between threads.
"""

from net import TCPConn
from net._reactor import ReactorToken
from net.error import NetError, NetErrorKind
from net.tls import TLSConnection, TLSIOResult
from net.http._http2.hpack import Http2HpackDeflater
from net.http._http2.request_session import Http2RequestSession
from net.http._http2.response_scheduler import Http2ResponseScheduler
from net.http._buffer import _CapacityBudget, _reserve_capacity

comptime STATE_READING: UInt8 = 0
comptime STATE_SENDING: UInt8 = 1
comptime STATE_SENDING_100: UInt8 = 2
comptime STATE_DETACHED: UInt8 = 3
comptime STATE_STREAMING: UInt8 = 4
comptime STATE_HANDSHAKING: UInt8 = 5
comptime STATE_TLS_SHUTDOWN: UInt8 = 6
comptime STATE_SENDING_HTTP2_CONTROL: UInt8 = 7
comptime PROTOCOL_HTTP11: UInt8 = 1
comptime PROTOCOL_HTTP2: UInt8 = 2
comptime READ_BUFFER_SIZE: Int = 8192


struct HttpConnection(Movable):
    var token: ReactorToken
    var conn: Optional[TCPConn]
    var tls: Optional[TLSConnection]
    var http2_session: Optional[Http2RequestSession]
    var http2_deflater: Optional[Http2HpackDeflater]
    var http2_responses: Http2ResponseScheduler
    var http2_response_bytes_reserved: Int
    var http2_body_reserved: Int
    var protocol: UInt8
    var buf: List[Byte]
    var state: UInt8
    var pending: List[Byte]
    var pending_offset: Int
    var should_close: Bool
    var sent_100: Bool
    var read_eof: Bool
    var stream_finished: Bool
    var stream_has_body: Bool
    var header_at: Int
    var body_at: Int
    var write_at: Int
    var idle_at: Int
    var detach_at: Int
    var detach_state_addr: Int
    var is_head: Bool
    var req_close: Bool
    var requests_served: Int
    var bytes_this_tick: Int
    var requests_this_tick: Int
    var reserved: Int
    var http1_body_reserved: Int
    var scanned_len: Int
    var more_work: Bool
    var active: Bool
    var _no_deadline: Int
    var tls_handshake_at: Int
    var tls_shutdown_at: Int
    var tls_handshake_wants_read: Bool
    var tls_handshake_wants_write: Bool
    var tls_shutdown_wants_write: Bool
    var tls_read_would_block: Bool
    var tls_read_wants_write: Bool
    var tls_read_retry_length: Int
    var tls_write_would_block: Bool
    var tls_write_wants_read: Bool
    var tls_write_closed: Bool
    var tls_write_retry_length: Int
    var tls_read_buffer: List[Byte]

    def __init__(
        out self,
        token: ReactorToken,
        var conn: Optional[TCPConn],
        var tls: Optional[TLSConnection],
        idle_at: Int,
        no_deadline: Int,
        handshake_at: Int,
    ):
        self.token = token.copy()
        self.conn = conn^
        self.tls = tls^
        self.http2_session = None
        self.http2_deflater = None
        self.http2_responses = Http2ResponseScheduler()
        self.http2_response_bytes_reserved = 0
        self.http2_body_reserved = 0
        self.protocol = PROTOCOL_HTTP11
        self.buf = List[Byte]()
        self.state = STATE_READING
        self.pending = List[Byte]()
        self.pending_offset = 0
        self.should_close = False
        self.sent_100 = False
        self.read_eof = False
        self.stream_finished = False
        self.stream_has_body = False
        self._no_deadline = no_deadline
        self.header_at = no_deadline
        self.body_at = no_deadline
        self.write_at = no_deadline
        self.idle_at = idle_at
        self.detach_at = no_deadline
        self.detach_state_addr = 0
        self.is_head = False
        self.req_close = False
        self.requests_served = 0
        self.bytes_this_tick = 0
        self.requests_this_tick = 0
        self.reserved = 0
        self.http1_body_reserved = 0
        self.scanned_len = 0
        self.more_work = False
        self.active = True
        self.tls_handshake_at = handshake_at
        self.tls_shutdown_at = no_deadline
        self.tls_handshake_wants_read = False
        self.tls_handshake_wants_write = False
        self.tls_shutdown_wants_write = False
        self.tls_read_would_block = False
        self.tls_read_wants_write = False
        self.tls_read_retry_length = 0
        self.tls_write_would_block = False
        self.tls_write_wants_read = False
        self.tls_write_closed = False
        self.tls_write_retry_length = 0
        self.tls_read_buffer = List[Byte]()
        if self.tls:
            self.state = STATE_HANDSHAKING
            self.tls_handshake_wants_read = True
            self.tls_read_buffer = List[Byte](length=READ_BUFFER_SIZE, fill=0)

    def wants_read(self) -> Bool:
        if not self.active or self.read_eof:
            return False
        if self.state == STATE_HANDSHAKING:
            return self.tls_handshake_wants_read
        if self.state == STATE_TLS_SHUTDOWN:
            return not self.tls_shutdown_wants_write
        if self.tls_write_would_block or self.tls_read_would_block:
            return (
                self.tls_write_would_block and self.tls_write_wants_read
            ) or (self.tls_read_would_block and not self.tls_read_wants_write)
        if self.state == STATE_SENDING_HTTP2_CONTROL:
            return True
        if self.state == STATE_READING:
            return True
        if self.state == STATE_DETACHED or self.state == STATE_STREAMING:
            # While detached or streaming, only read if buffer is empty, so pipelined
            # data does not consume the shared buffer budget unparsed.
            # Reading when buffer is empty allows detecting peer disconnect (EOF).
            return self.buffered_len() == 0
        return False

    def wants_write(self) -> Bool:
        if not self.active:
            return False
        if self.state == STATE_HANDSHAKING:
            return self.tls_handshake_wants_write
        if self.state == STATE_TLS_SHUTDOWN:
            return self.tls_shutdown_wants_write
        if self.tls_read_would_block and self.tls_read_wants_write:
            return True
        if self.tls_write_would_block:
            return not self.tls_write_wants_read
        return (
            self.state == STATE_SENDING
            or self.state == STATE_SENDING_100
            or self.state == STATE_SENDING_HTTP2_CONTROL
            or self.state == STATE_STREAMING
        ) and self.pending_offset < len(self.pending)

    def is_tls(self) -> Bool:
        return Bool(self.tls)

    def tls_pending(self) -> Int:
        if self.tls:
            return self.tls.value().pending()
        return 0

    def read_ready(self, readable: Bool, writable: Bool) -> Bool:
        return readable or (
            writable and self.tls_read_would_block and self.tls_read_wants_write
        )

    def write_ready(self, readable: Bool, writable: Bool) -> Bool:
        return writable or (
            readable
            and self.tls_write_would_block
            and self.tls_write_wants_read
        )

    def buffered_len(self) -> Int:
        return len(self.buf)

    def pending_remaining(self) -> Int:
        return len(self.pending) - self.pending_offset

    def reset_tick(mut self):
        self.bytes_this_tick = 0
        self.requests_this_tick = 0

    def append_bytes[origin: ImmOrigin](mut self, data: Span[Byte, origin]):
        for i in range(len(data)):
            self.buf.append(data[i])

    def drain_prefix(mut self, count: Int):
        var remaining = len(self.buf) - count
        if remaining == 0:
            self.buf = List[Byte]()
        else:
            for i in range(remaining):
                self.buf[i] = self.buf[count + i]
            self.buf.shrink(remaining)
        # The drained prefix was necessarily scanned; the remainder
        # keeps its scanned prefix length.
        if self.scanned_len > count:
            self.scanned_len -= count
        else:
            self.scanned_len = 0

    def _adopt_pending[
        B: _CapacityBudget
    ](mut self, var bytes: List[Byte], mut budget: B) -> Bool:
        if not budget.try_reserve(bytes.capacity()):
            return False
        self._adopt_reserved_pending(bytes^, budget)
        return True

    def _adopt_reserved_pending[
        B: _CapacityBudget
    ](mut self, var bytes: List[Byte], mut budget: B):
        var old_capacity = self.pending.capacity()
        self.pending = bytes^
        budget.release(old_capacity)
        self.pending_offset = 0

    def _set_reserved_pending[
        B: _CapacityBudget
    ](mut self, var bytes: List[Byte], mut budget: B):
        self._adopt_reserved_pending(bytes^, budget)
        self.state = STATE_SENDING

    def set_pending[
        B: _CapacityBudget
    ](mut self, var bytes: List[Byte], mut budget: B) -> Bool:
        if not self._adopt_pending(bytes^, budget):
            return False
        self.state = STATE_SENDING
        return True

    def append_pending[
        B: _CapacityBudget
    ](mut self, var bytes: List[Byte], mut budget: B) -> Bool:
        if self.pending_offset >= len(self.pending):
            return self._adopt_pending(bytes^, budget)
        var incoming_capacity = bytes.capacity()
        if not budget.try_reserve(incoming_capacity):
            return False
        var remaining = self.pending_remaining()
        var reservation = 0
        if not _reserve_capacity(
            self.pending, budget, remaining + len(bytes), reservation
        ):
            _ = bytes^
            budget.release(incoming_capacity)
            return False
        if self.pending_offset > 0:
            for i in range(remaining):
                self.pending[i] = self.pending[self.pending_offset + i]
            self.pending.shrink(remaining)
            self.pending_offset = 0
        for i in range(len(bytes)):
            self.pending.append(bytes[i])
        _ = bytes^
        budget.release(incoming_capacity)
        return True

    def pending_span(self) -> Span[Byte, origin_of(self.pending)]:
        return Span(self.pending)[self.pending_offset :]

    def advance_pending(mut self, count: Int):
        self.pending_offset += count

    def pending_done(self) -> Bool:
        return self.pending_offset >= len(self.pending)

    def clear_pending(mut self):
        self.pending = List[Byte]()
        self.pending_offset = 0
        self.tls_write_would_block = False
        self.tls_write_wants_read = False
        self.tls_write_closed = False
        self.tls_write_retry_length = 0

    def try_read_into[
        origin: MutOrigin
    ](mut self, output: Span[mut=True, Byte, origin]) raises NetError -> Int:
        """One non-blocking read into caller scratch. A zero count
        means EOF; a would-block socket raises a timeout `NetError`."""
        var bound = min(len(output), READ_BUFFER_SIZE)
        if self.tls:
            if self.tls_read_retry_length > 0:
                bound = self.tls_read_retry_length
            var result = self.tls.value().try_read(
                Span(self.tls_read_buffer)[0:bound]
            )
            if (
                result.progress.is_wants_read()
                or result.progress.is_wants_write()
            ):
                self.tls_read_would_block = True
                self.tls_read_wants_write = result.progress.is_wants_write()
                self.tls_read_retry_length = bound
                raise NetError(
                    NetErrorKind.timeout(),
                    "TLS read",
                    None,
                    "OpenSSL is waiting for socket readiness",
                )
            self.tls_read_would_block = False
            self.tls_read_wants_write = False
            self.tls_read_retry_length = 0
            if result.progress.is_closed():
                return 0
            for i in range(result.count):
                output[i] = self.tls_read_buffer[i]
            if self.tls.value().pending() > 0:
                self.more_work = True
            return result.count
        else:
            return self.conn.value().try_read(output[0:bound])

    def try_write_pending_capped(mut self, cap: Int) raises NetError -> Int:
        """Writes at most `cap` pending bytes so one connection cannot
        exceed its per-tick fairness allowance in a single call."""
        var available = len(self.pending) - self.pending_offset
        var bound = available if available < cap else cap
        if self.tls and self.tls_write_retry_length > 0:
            bound = self.tls_write_retry_length
            if bound > cap:
                return 0
        if bound <= 0:
            return 0
        var end = self.pending_offset + bound
        var written: Int
        if self.tls:
            var result = self.tls.value().try_write(
                Span(self.pending)[self.pending_offset : end]
            )
            written = self._note_tls_write(result, bound)
        else:
            written = self.conn.value().try_write(
                Span(self.pending)[self.pending_offset : end]
            )
        self.pending_offset += written
        return written

    def try_write_bytes[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError -> Int:
        if self.tls:
            var result = self.tls.value().try_write(data)
            return self._note_tls_write(result, len(data))
        return self.conn.value().try_write(data)

    def _note_tls_write(mut self, result: TLSIOResult, length: Int) -> Int:
        """Records a TLS write outcome; OpenSSL requires a would-block
        write to be retried with the same length."""
        var blocked = (
            result.progress.is_wants_read() or result.progress.is_wants_write()
        )
        self.tls_write_would_block = blocked
        self.tls_write_wants_read = result.progress.is_wants_read()
        self.tls_write_retry_length = length if blocked else 0
        if blocked:
            return 0
        self.tls_write_closed = result.progress.is_closed()
        return result.count

    def raw_fd(self) raises NetError -> Int32:
        if self.tls:
            return self.tls.value().raw_fd()
        return self.conn.value().raw_fd()

    def close(mut self) raises NetError:
        """Closes the underlying connection and releases socket allocations.

        Note on detach state ownership: if `detach_state_addr` is non-zero,
        the caller (e.g. Server._close_conn) must cancel and release the
        shared state reference prior to calling `close()`.
        """
        self.active = False
        # Drop the allocations instead of clearing: clear() would retain
        # capacity on a free-listed slot, hoarding memory the budget no
        # longer accounts for. Both lists are replaced, not cleared.
        self.buf = List[Byte]()
        self.pending = List[Byte]()
        self.pending_offset = 0
        self.reserved = 0
        self.detach_state_addr = 0
        self.detach_at = self._no_deadline
        self.is_head = False
        self.stream_finished = False
        self.stream_has_body = False
        self.tls = None
        self.http2_session = None
        self.http2_deflater = None
        self.http2_responses = Http2ResponseScheduler()
        self.http2_response_bytes_reserved = 0
        self.http2_body_reserved = 0
        if self.conn:
            self.conn.value().close()
            self.conn = None
