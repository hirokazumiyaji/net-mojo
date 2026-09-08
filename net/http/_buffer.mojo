"""Global buffer budget for the HTTP server loop.

Every wire byte the server holds (connection receive buffers and queued
responses) counts against `total`. Decoded request bodies live only for
the handler call on a single-threaded loop, so at most one extra
`max_body_bytes` transient exists next to the counted bytes.
"""


struct BufferBudget(Movable):
    var total: Int
    var used: Int

    def __init__(out self, total: Int):
        self.total = total
        self.used = 0

    def remaining(self) -> Int:
        return self.total - self.used

    def try_reserve(mut self, amount: Int) -> Bool:
        if amount < 0:
            return False
        if self.used + amount > self.total:
            return False
        self.used += amount
        return True

    def release(mut self, amount: Int):
        self.used -= amount
        if self.used < 0:
            self.used = 0
