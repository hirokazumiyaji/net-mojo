"""Global buffer budget for the HTTP server loop.

Receive buffers charge retained capacity and the old + new allocation
peak during growth. Queued responses and other reservations still charge
wire lengths; parser, writer and provider allocations remain separate.
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


def _reserve_capacity(
    mut bytes: List[Byte],
    mut budget: BufferBudget,
    needed: Int,
    mut reservation: Int,
) -> Bool:
    var old_capacity = bytes.capacity()
    if needed <= old_capacity:
        return True
    var available = reservation + budget.remaining()
    var target = max(needed, old_capacity * 2)
    target = min(target, available)
    if target < needed:
        return False
    var covered = min(target, reservation)
    if not budget.try_reserve(target - covered):
        return False
    # Keep the old allocation charged until reserve replaces it.
    bytes.reserve(target)
    reservation -= covered
    budget.release(old_capacity)
    return True
