"""Global buffer budget for the HTTP server loop.

Receive and adopted pending buffers charge retained capacity and growth
peaks. Pending growth also charges its incoming wire allocation. Synchronous
and detached buffered HTTP/1 response wire, detached streaming wire, and HTTP/1
error wire are reserved before allocation. Other encoding, parser scratch and provider allocations
remain separate. Decoded
HTTP/1 body copies reserve their exact capacity before materialization and remain
charged through the handler call. Synchronous HTTP/1 writer bodies own their
capacity reservation directly; other writer paths and other reservations still
need separate capacity accounting.

The global counter uses a mutex-protected shared capability. Detached message
arrays charge their retained capacity through drained-batch destruction. HTTP/1
detached state reserves its requested malloc payload until final free. Detached
message bodies retain adopted capacity reservations through their destruction;
send reserves exact chunk capacity before allocation. Streaming wire reserves
exact start/chunk/end capacity before allocation and transfers its charge into
pending storage, retaining old + incoming + new growth peaks. Response Headers
charge their three List arrays and raw value capacities through owned tickets;
grouped growth reserves full new arrays while the old storage stays charged.
String backing/scratch and request/parser Header admission remain separate.
"""

from std.memory import ArcPointer
from std.sys import size_of

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

    def _shares_storage(self, other: Self) -> Bool:
        return self._state.ptr() == other._state.ptr()


struct _CapacityTicket(Movable):
    var budget: Optional[SharedBufferBudget]
    var amount: Int

    def __init__(
        out self,
        var budget: Optional[SharedBufferBudget] = None,
        amount: Int = 0,
    ):
        self.budget = budget^
        self.amount = amount

    def _try_reserve(mut self, amount: Int) -> Bool:
        if self.budget and not self.budget.value().try_reserve(amount):
            return False
        self.amount = amount
        return True

    def release(mut self):
        if self.budget:
            self.budget.value().release(self.amount)
        self.amount = 0

    def __deinit__(deinit self):
        self.release()


def _reserve_capacity[
    T: Movable, B: _CapacityBudget
](
    mut bytes: List[T],
    mut budget: B,
    needed: Int,
    mut reservation: Int,
) -> Bool:
    var old_capacity = bytes.capacity()
    if needed <= old_capacity:
        return True
    comptime element_size = size_of[T]()
    var available = (reservation + budget.remaining()) // element_size
    var target = max(needed, old_capacity * 2)
    target = min(target, available)
    if target < needed:
        return False
    var target_bytes = target * element_size
    var covered = min(target_bytes, reservation)
    if not budget.try_reserve(target_bytes - covered):
        return False
    # Keep the old allocation charged until reserve replaces it.
    bytes.reserve(target)
    reservation -= covered
    budget.release(old_capacity * element_size)
    return True
