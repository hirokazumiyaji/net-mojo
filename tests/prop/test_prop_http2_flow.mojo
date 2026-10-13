from std.testing import assert_equal
from proptest import (
    Settings,
    StateMachine,
    TestCase,
    for_all,
    integers,
    run_state_machine,
)
from net.http._http2.flow_window import Http2FlowWindow


comptime LIMIT = 0x7FFFFFFF


def _amount(mut tc: TestCase, boundary: Int) raises -> Int:
    var mode = tc.draw(integers(0, 4), "amount-mode")
    if mode == 0:
        return tc.draw(integers(-1, LIMIT + 1), "amount")
    if mode == 1:
        return 0
    return max(0, boundary) + mode - 3


struct FlowMachine(StateMachine):
    var sut: Http2FlowWindow
    var initial_send: Int
    var initial_receive: Int
    var updates: Int
    var sent: Int
    var received: Int
    var released: Int

    def __init__(out self, outbound: Int, inbound: Int):
        self.sut = Http2FlowWindow(outbound, inbound)
        self.initial_send = outbound
        self.initial_receive = inbound
        self.updates = 0
        self.sent = 0
        self.received = 0
        self.released = 0

    def num_rules(self) -> Int:
        return 5

    def run_rule(mut self, mut tc: TestCase, rule: Int) raises:
        var send = self.initial_send + self.updates - self.sent
        var receive = self.initial_receive - self.received + self.released
        var pending = self.received - self.released
        if rule == 0:
            var amount = _amount(tc, send)
            var allowed = amount >= 0 and amount <= send
            assert_equal(self.sut.consume_outbound(amount), allowed)
            if allowed:
                self.sent += amount
        elif rule == 1:
            var increment = _amount(tc, LIMIT - send)
            var allowed = (
                increment > 0
                and increment <= LIMIT
                and send + increment <= LIMIT
            )
            assert_equal(self.sut.apply_window_update(increment), allowed)
            if allowed:
                self.updates += increment
        elif rule == 2:
            var amount = _amount(tc, receive)
            var allowed = amount >= 0 and amount <= receive
            assert_equal(self.sut.receive_data(amount), allowed)
            if allowed:
                self.received += amount
        elif rule == 3:
            var amount = _amount(tc, pending)
            var allowed = (
                amount >= 0 and amount <= pending and receive + amount <= LIMIT
            )
            assert_equal(self.sut.release_received(amount), allowed)
            if allowed:
                self.released += amount
        else:
            var value = _amount(tc, self.initial_send)
            var resulting = value + self.updates - self.sent
            var allowed = value >= 0 and value <= LIMIT and resulting <= LIMIT
            assert_equal(self.sut.update_initial_send_window(value), allowed)
            if allowed:
                self.initial_send = value

    def check_invariants(self) raises:
        assert_equal(
            self.sut.send_window(), self.initial_send + self.updates - self.sent
        )
        assert_equal(
            self.sut.receive_window(),
            self.initial_receive - self.received + self.released,
        )
        assert_equal(
            self.sut.pending_receive_credit(), self.received - self.released
        )
        assert_equal(
            self.sut.receive_window() + self.sut.pending_receive_credit(),
            self.initial_receive,
        )


def _flow(mut tc: TestCase) raises:
    var outbound = tc.draw(integers(0, LIMIT), "initial-send")
    var inbound = tc.draw(integers(0, LIMIT), "initial-receive")
    var machine = FlowMachine(outbound, inbound)
    machine.check_invariants()
    var final = run_state_machine(machine^, tc, max_ops=64)
    final.check_invariants()


def main() raises:
    for_all(_flow, Settings(name="net-http2-flow-model"))
