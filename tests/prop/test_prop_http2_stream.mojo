from std.testing import assert_equal
from proptest import (
    Settings,
    StateMachine,
    TestCase,
    for_all,
    booleans,
    run_state_machine,
)
from net.http._http2.stream_state import Http2StreamState


struct StreamMachine(StateMachine):
    var sut: Http2StreamState
    var remote: Int
    var local: Int
    var reset: Bool

    def __init__(out self):
        self.sut = Http2StreamState()
        self.remote = 0
        self.local = 0
        self.reset = False

    def num_rules(self) -> Int:
        return 6

    def run_rule(mut self, mut tc: TestCase, rule: Int) raises:
        var end_stream = tc.draw(booleans(), "end-stream")
        if rule == 0:
            var allowed = not self.reset and (
                self.remote == 0 or (self.remote == 1 and end_stream)
            )
            assert_equal(self.sut.receive_headers(end_stream), allowed)
            if allowed:
                if self.remote == 1:
                    self.remote = 3
                else:
                    self.remote = 2 if end_stream else 1
        elif rule == 1:
            var allowed = not self.reset and self.remote == 1
            assert_equal(self.sut.receive_data(end_stream), allowed)
            if allowed and end_stream:
                self.remote = 2
        elif rule == 2:
            var allowed = (
                not self.reset and self.remote != 0 and self.local != 2
            )
            assert_equal(self.sut.send_headers(end_stream), allowed)
            if allowed:
                self.local = 2 if end_stream else 1
        elif rule == 3:
            var allowed = not self.reset and self.local == 1
            assert_equal(self.sut.send_data(end_stream), allowed)
            if allowed and end_stream:
                self.local = 2
        elif rule == 4:
            var closed = self.remote >= 2 and self.local == 2
            var allowed = self.remote != 0 and not self.reset and not closed
            assert_equal(self.sut.reset(), allowed)
            if allowed:
                self.reset = True
        else:
            self.check_invariants()

    def check_invariants(self) raises:
        assert_equal(self.sut.remote_headers_received, self.remote != 0)
        assert_equal(self.sut.remote_trailers_received, self.remote == 3)
        assert_equal(self.sut.local_headers_sent, self.local != 0)
        assert_equal(self.sut.is_remote_closed(), self.remote >= 2)
        assert_equal(self.sut.is_local_closed(), self.local == 2)
        assert_equal(
            self.sut.is_closed(),
            self.reset or (self.remote >= 2 and self.local == 2),
        )
        assert_equal(self.sut.reset_done, self.reset)


def _stream(mut tc: TestCase) raises:
    var machine = run_state_machine(StreamMachine(), tc, max_ops=64)
    machine.check_invariants()


def main() raises:
    for_all(_stream, Settings(name="net-http2-stream-model"))
