"""Global buffer budget for the HTTP server loop.

Receive and adopted pending buffers charge retained capacity and growth
peaks. Pending growth also charges its incoming wire allocation. Synchronous
HTTP/1 buffered response and error wire are reserved before allocation. Other encoding,
parser scratch and provider allocations remain separate. Decoded
HTTP/1 body copies reserve their exact capacity before materialization and remain
charged through the handler call. Synchronous
HTTP/1 writer bodies use a reserved workspace; other writer paths and other
reservations still need separate capacity accounting.

The global counter uses a mutex-protected shared capability; local writer
workspace counters remain plain. Detached allocation accounting is separate.
"""

from std.memory import ArcPointer

from net._actor import PthreadMutex


trait _CapacityBudget(Movable):
    def remaining(self) -> Int:
        ...

    def try_reserve(mut self, amount: Int) -> Bool:
        ...

    def release(mut self, amount: Int):
        ...


struct BufferBudget(_CapacityBudget):
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


struct _BudgetState(Movable):
    var mutex: PthreadMutex
    var budget: BufferBudget

    def __init__(out self, total: Int):
        self.mutex = PthreadMutex._uninitialized()
        self.budget = BufferBudget(total)

    def __deinit__(deinit self):
        self.mutex.destroy()


struct SharedBufferBudget(Copyable, _CapacityBudget):
    var _state: ArcPointer[_BudgetState]

    def __init__(out self, total: Int):
        self._state = ArcPointer(_BudgetState(total))
        self._state[].mutex._initialize()

    def total(self) -> Int:
        self._state[].mutex.lock()
        var total = self._state[].budget.total
        self._state[].mutex.unlock()
        return total

    def used(self) -> Int:
        self._state[].mutex.lock()
        var used = self._state[].budget.used
        self._state[].mutex.unlock()
        return used

    def remaining(self) -> Int:
        self._state[].mutex.lock()
        var remaining = self._state[].budget.remaining()
        self._state[].mutex.unlock()
        return remaining

    def try_reserve(mut self, amount: Int) -> Bool:
        self._state[].mutex.lock()
        var admitted = self._state[].budget.try_reserve(amount)
        self._state[].mutex.unlock()
        return admitted

    def release(mut self, amount: Int):
        self._state[].mutex.lock()
        self._state[].budget.release(amount)
        self._state[].mutex.unlock()


def _reserve_capacity[
    B: _CapacityBudget
](
    mut bytes: List[Byte],
    mut budget: B,
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
