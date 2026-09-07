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
    var header_at: Int
    var body_at: Int
    var write_at: Int
    var idle_at: Int
    var requests_served: Int
    var bytes_this_tick: Int
    var requests_this_tick: Int
    var reserved: Int
    var active: Bool

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
        self.header_at = no_deadline
        self.body_at = no_deadline
        self.write_at = no_deadline
        self.idle_at = idle_at
        self.requests_served = 0
        self.bytes_this_tick = 0
        self.requests_this_tick = 0
        self.reserved = 0
        self.active = True

    def wants_read(self) -> Bool:
        return self.active and self.state == STATE_READING and not self.read_eof

    def wants_write(self) -> Bool:
        return (
            self.active
            and self.state == STATE_SENDING
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

    def set_pending(mut self, var bytes: List[Byte]):
        self.pending = bytes^
        self.pending_offset = 0
        self.state = STATE_SENDING

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
        self.active = False
        # Drop the allocations instead of clearing: clear() would retain
        # capacity on a free-listed slot, hoarding memory the budget no
        # longer accounts for. Both lists are replaced, not cleared.
        self.buf = List[Byte]()
        self.pending = List[Byte]()
        self.pending_offset = 0
        self.reserved = 0
        self.conn.close()
