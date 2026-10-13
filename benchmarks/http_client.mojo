"""Bounded loopback measurements of Client plus Server, without thresholds."""

from std.ffi import c_int, c_ulong, external_call
from std.memory import ArcPointer
from std.time import perf_counter_ns
from net.http import Client, ClientConfig, ClientRequest
from examples._http_client_loopback import _LoopbackHTTPServer


struct _WorkerState(Movable):
    var url: String
    var rounds: Int
    var completed: Int
    var failed: Bool

    def __init__(out self, var url: String, rounds: Int):
        self.url = url^
        self.rounds = rounds
        self.completed = 0
        self.failed = False


def _request(mut client: Client, url: StringSlice) raises:
    var response = client.do(ClientRequest.get(String(url)))
    if response.status != 200 or len(response.read_all()) != 64:
        raise Error("HTTP client benchmark response mismatch")


def _run_worker(mut state: _WorkerState) raises:
    var client = Client(ClientConfig.default())
    for _ in range(state.rounds):
        _request(client, state.url)
        state.completed += 1
    client.close()


def _worker(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var state = arg.unsafe_bitcast[_WorkerState]()
    try:
        _run_worker(state[])
    except:
        state[].failed = True
    return arg


struct _Workers(Movable):
    var _states: List[ArcPointer[_WorkerState]]
    var _threads: List[UInt64]
    var _joined: Int

    def __init__(out self, url: StringSlice, count: Int, rounds: Int) raises:
        self._states = List[ArcPointer[_WorkerState]]()
        self._threads = List[UInt64]()
        self._joined = 0
        for _ in range(count):
            self._states.append(ArcPointer(_WorkerState(String(url), rounds)))
            var thread: UInt64 = 0
            var result = external_call["pthread_create", c_int](
                Pointer(to=thread),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
                _worker,
                Pointer(
                    to=self._states[len(self._states) - 1][]
                ).unsafe_bitcast[Byte](),
            )
            if result != 0:
                raise Error("could not start HTTP client benchmark worker")
            self._threads.append(thread)

    def finish(mut self) raises -> Int:
        while self._joined < len(self._threads):
            var result = external_call["pthread_join", c_int](
                c_ulong(self._threads[self._joined]),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
            if result != 0:
                raise Error("could not join HTTP client benchmark worker")
            self._joined += 1
        var completed = 0
        for i in range(len(self._states)):
            if (
                self._states[i][].failed
                or self._states[i][].completed != self._states[i][].rounds
            ):
                raise Error("HTTP client benchmark worker failed")
            completed += self._states[i][].completed
        return completed

    def __deinit__(deinit self):
        for i in range(self._joined, len(self._threads)):
            _ = external_call["pthread_join", c_int](
                c_ulong(self._threads[i]),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
        _ = self._states^


def _report(label: StringSlice, requests: Int, elapsed_ns: Int):
    print(label, "requests:", requests)
    print(label, "elapsed_ms:", Float64(elapsed_ns) / 1e6)
    print(
        label,
        "requests_per_second:",
        Float64(requests) * 1e9 / Float64(elapsed_ns),
    )


def main() raises:
    var server = _LoopbackHTTPServer(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    var client = Client(ClientConfig.default())
    for _ in range(10):
        _request(client, server.url)
    var rounds = 1000
    var start = perf_counter_ns()
    for _ in range(rounds):
        _request(client, server.url)
    var sequential_ns = perf_counter_ns() - start
    client.close()
    _report("single pooled client", rounds, sequential_ns)
    start = perf_counter_ns()
    var workers = _Workers(server.url, 32, 100)
    var completed = workers.finish()
    var concurrent_ns = perf_counter_ns() - start
    _report("32 independent clients", completed, concurrent_ns)
    var served = server.finish()
    if completed != 3200 or served != rounds + 10 + completed:
        raise Error("HTTP client benchmark request accounting mismatch")
    print("benchmark-http-client done")
