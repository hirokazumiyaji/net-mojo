"""Per-connection state for the HTTP server loop.

A connection owns its socket, its unprocessed wire bytes, and at most
one queued response. All moves are whole values; nothing borrows across
connections, so the table never shares ownership between threads.
"""

from net import TCPConn
from net._reactor import ReactorToken
from net.error import NetError

comptime STATE_READING: UInt8 = 0
comptime STATE_SENDING: UInt8 = 1
comptime STATE_SENDING_100: UInt8 = 2
comptime STATE_DETACHED: UInt8 = 3
comptime STATE_STREAMING: UInt8 = 4


struct HttpConnection(Movable):
    var token: ReactorToken
    var conn: TCPConn
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
    var scanned_len: Int
    var more_work: Bool
    var active: Bool
    var _no_deadline: Int

    def __init__(
        out self,
        token: ReactorToken,
        var conn: TCPConn,
        idle_at: Int,
        no_deadline: Int,
    ):
        self.token = token.copy()
        self.conn = conn^
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
        self.scanned_len = 0
        self.more_work = False
        self.active = True

    def wants_read(self) -> Bool:
        if not self.active or self.read_eof:
            return False
        if self.state == STATE_READING:
            return True
        if self.state == STATE_DETACHED or self.state == STATE_STREAMING:
            # While detached or streaming, only read if buffer is empty, so pipelined
            # data does not consume the shared buffer budget unparsed.
            # Reading when buffer is empty allows detecting peer disconnect (EOF).
            return self.buffered_len() == 0
        return False

    def wants_write(self) -> Bool:
        return (
            self.active
            and (self.state == STATE_SENDING or self.state == STATE_STREAMING)
            and self.pending_offset < len(self.pending)
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
        var rest = List[Byte]()
        for i in range(count, len(self.buf)):
            rest.append(self.buf[i])
        self.buf = rest^
        # The drained prefix was necessarily scanned; the remainder
        # keeps its scanned prefix length.
        if self.scanned_len > count:
            self.scanned_len -= count
        else:
            self.scanned_len = 0

    def set_pending(mut self, var bytes: List[Byte]):
        self.pending = bytes^
        self.pending_offset = 0
        self.state = STATE_SENDING

    def append_pending(mut self, var bytes: List[Byte]):
        if self.pending_offset >= len(self.pending):
            self.pending = bytes^
            self.pending_offset = 0
        elif self.pending_offset > 0:
            var rest = List[Byte]()
            rest.reserve(self.pending_remaining() + len(bytes))
            for i in range(self.pending_offset, len(self.pending)):
                rest.append(self.pending[i])
            for i in range(len(bytes)):
                rest.append(bytes[i])
            self.pending = rest^
            self.pending_offset = 0
        else:
            self.pending.reserve(len(self.pending) + len(bytes))
            for i in range(len(bytes)):
                self.pending.append(bytes[i])

    def pending_span(self) -> Span[Byte, origin_of(self.pending)]:
        return Span(self.pending)[self.pending_offset :]

    def advance_pending(mut self, count: Int):
        self.pending_offset += count

    def pending_done(self) -> Bool:
        return self.pending_offset >= len(self.pending)

    def clear_pending(mut self):
        self.pending.clear()
        self.pending_offset = 0

    def try_read_bytes(mut self, limit: Int) raises NetError -> List[Byte]:
        """One non-blocking read of up to `limit` bytes. An empty result
        means EOF; a would-block socket raises a timeout `NetError`."""
        var tmp = Array[Byte, 8192](fill=0)
        var bound = limit if limit < 8192 else 8192
        var count = self.conn.try_read(Span(tmp)[0:bound])
        var out = List[Byte]()
        for i in range(count):
            out.append(tmp[i])
        return out^

    def try_write_pending_capped(mut self, cap: Int) raises NetError -> Int:
        """Writes at most `cap` pending bytes so one connection cannot
        exceed its per-tick fairness allowance in a single call."""
        var available = len(self.pending) - self.pending_offset
        var bound = available if available < cap else cap
        if bound <= 0:
            return 0
        var end = self.pending_offset + bound
        var written = self.conn.try_write(
            Span(self.pending)[self.pending_offset : end]
        )
        self.pending_offset += written
        return written

    def try_write_bytes[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError -> Int:
        return self.conn.try_write(data)

    def raw_fd(self) raises NetError -> Int32:
        return self.conn.raw_fd()

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
        self.conn.close()
