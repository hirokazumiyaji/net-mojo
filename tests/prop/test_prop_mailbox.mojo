from std.testing import assert_equal
from proptest import (
    Settings,
    StateMachine,
    TestCase,
    for_all,
    integers,
    run_state_machine,
)
from net._actor import Mailbox


struct MailboxMachine(StateMachine):
    var sut: Mailbox[Int]
    var pending: List[Int]
    var closed: Bool

    def __init__(out self):
        self.sut = Mailbox[Int]()
        self.pending = List[Int]()
        self.closed = False

    def num_rules(self) -> Int:
        return 3

    def run_rule(mut self, mut tc: TestCase, rule: Int) raises:
        if rule == 0:
            var value = tc.draw(integers(-1000, 1000), "value")
            assert_equal(self.sut.push(value), not self.closed)
            if not self.closed:
                self.pending.append(value)
        elif rule == 1:
            var batch = self.sut.pop_all()
            assert_equal(len(batch), len(self.pending))
            for i in range(len(batch)):
                assert_equal(batch[i], self.pending[i])
            self.pending.clear()
        else:
            self.sut.close()
            self.closed = True
        assert_equal(self.sut.count(), len(self.pending))
        assert_equal(self.sut.is_closed(), self.closed)

    def check_invariants(self) raises:
        assert_equal(len(self.sut._items), len(self.pending))
        assert_equal(self.sut._closed, self.closed)


def _mailbox(mut tc: TestCase) raises:
    var machine = run_state_machine(MailboxMachine(), tc, max_ops=64)
    machine.run_rule(tc, 1)


def main() raises:
    for_all(_mailbox, Settings(name="net-mailbox-model"))
