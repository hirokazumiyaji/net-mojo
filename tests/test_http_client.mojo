from std.ffi import c_int, c_ulong, external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, TestSuite
from net import TCPConn, TCPListener, Timeout, listen_tcp
from net.http import (
    Client,
    ClientConfig,
    ClientRequest,
    ClientError,
    ServerConfig,
    Server,
    ServerControl,
    Handler,
    Request,
    ResponseWriter,
    Response,
)
from net.http._parser import parse_one
from net.tls import TLSContext


struct _FixtureState(Movable):
    var listener: TCPListener
    var replies: List[String]
    var accepted: Int
    var served: Int
    var failed: Bool
    var requests: List[String]

    def __init__(
        out self, var listener: TCPListener, var replies: List[String]
    ):
        self.listener = listener^
        self.replies = replies^
        self.accepted = 0
        self.served = 0
        self.failed = False
        self.requests = List[String]()


def _fixture_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var state = arg.unsafe_bitcast[_FixtureState]()
    try:
        var config = ServerConfig.default()
        var connection: Optional[TCPConn] = None
        var wire = List[Byte]()
        var buffer = List[Byte](length=4096, fill=0)
        while state[].served < len(state[].replies):
            if not connection:
                connection = state[].listener.accept(Timeout.seconds(3))
                state[].accepted += 1
            var count = connection.value().read(
                Span(buffer), Timeout.seconds(3)
            )
            if count == 0:
                connection = None
                wire.clear()
                continue
            wire.extend(Span(buffer)[:count])
            var request = parse_one(Span(wire), config)
            if request.is_need_more():
                continue
            if request.is_error():
                state[].failed = True
                return arg
            state[].requests.append(
                request.request.method
                + " "
                + request.request.target
                + " "
                + String(from_utf8_lossy=request.request.body)
            )
            var reply = state[].replies[state[].served].copy()
            connection.value().write_all(reply.as_bytes(), Timeout.seconds(3))
            state[].served += 1
            wire.clear()
            if reply.find("Connection: close") >= 0 or reply.startswith(
                "HTTP/1.0"
            ):
                connection = None
    except:
        state[].failed = True
    return arg


struct _Fixture(Movable):
    var state: ArcPointer[_FixtureState]
    var handle: UInt64
    var joined: Bool
    var url: String

    def __init__(out self, var replies: List[String]) raises:
        var listener = listen_tcp("127.0.0.1:0")
        self.url = String("http://") + String(listener.local_address())
        self.state = ArcPointer(_FixtureState(listener^, replies^))
        self.handle = 0
        self.joined = True
        var rc = external_call["pthread_create", c_int](
            Pointer(to=self.handle),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _fixture_entry,
            Pointer(to=self.state[]).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(rc), 0)
        self.joined = False

    def finish(mut self) raises:
        if not self.joined:
            var rc = external_call["pthread_join", c_int](
                c_ulong(self.handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
            self.joined = True
            assert_equal(Int(rc), 0)
        assert_true(not self.state[].failed)
        assert_equal(self.state[].served, len(self.state[].replies))

    def __deinit__(deinit self):
        if not self.joined:
            _ = external_call["pthread_join", c_int](
                c_ulong(self.handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
        _ = self.state^


def test_client_fixed_keepalive_and_post() raises:
    var replies: List[String] = [
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
        "HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok",
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var response = client.do(ClientRequest.get(fixture.url + "/one"))
    assert_equal(response.status, 200)
    assert_equal(String(from_utf8_lossy=response.body.read_all()), "abc")
    var body = List[Byte]("data".as_bytes())
    var posted = client.do(
        ClientRequest.post_bytes(fixture.url + "/two", body^)
    )
    assert_equal(posted.status, 201)
    assert_equal(String(from_utf8_lossy=posted.body.read_all()), "ok")
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].accepted, 1)
    assert_equal(fixture.state[].requests[1], "POST /two data")


def test_client_chunked_trailers_and_eof() raises:
    var replies: List[String] = [
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding:"
            " chunked\r\n\r\n2\r\nab\r\n3\r\ncde\r\n0\r\nX-End: yes\r\n\r\n"
        ),
        "HTTP/1.0 200 OK\r\n\r\neof",
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var response = client.do(ClientRequest.get(fixture.url))
    var buffer = List[Byte](length=2, fill=0)
    var body = List[Byte]()
    while True:
        var count = response.body.read(buffer)
        if count == 0:
            break
        body.extend(Span(buffer)[:count])
    assert_equal(String(from_utf8_lossy=body), "abcde")
    assert_equal(response.trailers().get_first("x-end").value(), "yes")
    var closing = client.do(ClientRequest.get(fixture.url))
    assert_equal(String(from_utf8_lossy=closing.body.read_all()), "eof")
    client.close()
    fixture.finish()


def test_client_head_interim_and_no_body() raises:
    var replies: List[String] = [
        (
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length:"
            " 9\r\n\r\n"
        ),
        "HTTP/1.1 204 No Content\r\n\r\n",
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var request = ClientRequest.get(fixture.url)
    request.method = "HEAD"
    var response = client.do(request^)
    assert_equal(response.status, 200)
    assert_equal(len(response.body.read_all()), 0)
    var nobody = client.do(ClientRequest.get(fixture.url))
    assert_equal(nobody.status, 204)
    assert_equal(len(nobody.body.read_all()), 0)
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].accepted, 1)


def test_client_pool_full_and_response_outlives_client() raises:
    var replies: List[String] = [
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
    ]
    var fixture = _Fixture(replies^)
    var config = ClientConfig.default()
    config.max_conns_per_host = 1
    var client = Client(config^)
    var response = client.do(ClientRequest.get(fixture.url))
    var caught = False
    try:
        var _ = client.do(ClientRequest.get(fixture.url))
    except error:
        assert_equal(error.kind, ClientError.POOL_FULL)
        caught = True
    assert_true(caught)
    client.close()
    _ = client^
    assert_equal(String(from_utf8_lossy=response.body.read_all()), "hello")
    fixture.finish()


def test_client_bounded_read_and_close_drain() raises:
    var replies: List[String] = [
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var first = client.do(ClientRequest.get(fixture.url))
    first.close()
    var second = client.do(ClientRequest.get(fixture.url))
    var caught = False
    try:
        var _ = second.body.read_all(1)
    except error:
        assert_equal(error.kind, ClientError.BODY_TOO_LARGE)
        caught = True
    assert_true(caught)
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].accepted, 1)


def test_client_streams_past_default_materialization_limit() raises:
    var payload = List[Byte](length=2 * 1048576, fill=Byte(ord("x")))
    var reply = String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2097152\r\n\r\n"
    ) + String(from_utf8_lossy=payload)
    var replies = List[String]()
    replies.append(reply^)
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var response = client.do(ClientRequest.get(fixture.url))
    var buffer = List[Byte](length=4096, fill=0)
    var total = 0
    while True:
        var count = response.body.read(buffer)
        if count == 0:
            break
        assert_equal(buffer[0], Byte(ord("x")))
        assert_equal(buffer[count - 1], Byte(ord("x")))
        total += count
    assert_equal(total, 2097152)
    client.close()
    fixture.finish()


def test_client_idle_expiry_and_disabled_pooling() raises:
    from std.time import sleep

    for expire in range(2):
        var replies: List[String] = [
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx",
        ]
        var fixture = _Fixture(replies^)
        var config = ClientConfig.default()
        if expire == 0:
            config.max_idle_conns_per_host = 0
        else:
            config.idle_conn_timeout = Timeout.milliseconds(1)
        var client = Client(config^)
        var first = client.do(ClientRequest.get(fixture.url))
        var _ = first.read_all()
        if expire == 1:
            sleep(0.01)
        var second = client.do(ClientRequest.get(fixture.url))
        var _ = second.read_all()
        client.close()
        fixture.finish()
        assert_equal(fixture.state[].accepted, 2)


def test_client_malformed_heads_and_truncated_bodies() raises:
    var replies: List[String] = [
        (
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding:"
            " chunked\r\n\r\n"
        ),
        "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort",
    ]
    for i in range(len(replies)):
        var script = List[String]()
        script.append(replies[i].copy())
        var fixture = _Fixture(script^)
        var client = Client(ClientConfig.default())
        var caught = False
        try:
            var response = client.do(ClientRequest.get(fixture.url))
            var _ = response.read_all()
        except error:
            assert_equal(
                error.kind, ClientError.PARSE if i == 0 else ClientError.READ
            )
            caught = True
        assert_true(caught)
        client.close()
        fixture.finish()
        assert_equal(client._pool.state[].origins[0].count, 0)


def test_client_deadline_covers_buffered_body_and_closed_client() raises:
    from std.time import sleep

    var replies: List[String] = [
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"
    ]
    var fixture = _Fixture(replies^)
    var client = Client(ClientConfig.default())
    var request = ClientRequest.get(fixture.url)
    request.deadline = Timeout.milliseconds(100)
    var response = client.do(request^)
    sleep(0.2)
    var caught = False
    try:
        var _ = response.read_all()
    except error:
        assert_equal(error.kind, ClientError.TIMEOUT)
        caught = True
    assert_true(caught)
    client.close()
    caught = False
    try:
        var _ = client.do(ClientRequest.get(fixture.url))
    except error:
        assert_equal(error.kind, ClientError.CANCELED)
        caught = True
    assert_true(caught)
    fixture.finish()


struct _LoopHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, request: Request, mut response: ResponseWriter) raises:
        self.requests += 1
        response.write_string("hello")


struct _LoopState(Movable):
    var server: Server
    var handler: _LoopHandler
    var failed: Bool

    def __init__(out self, var server: Server):
        self.server = server^
        self.handler = _LoopHandler()
        self.failed = False


def _loop_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var state = arg.unsafe_bitcast[_LoopState]()
    try:
        while True:
            if not state[].server.tick(
                state[].handler, Timeout.nanoseconds(10000000)
            ):
                break
    except:
        state[].failed = True
    return arg


struct _LoopFixture(Movable):
    var state: ArcPointer[_LoopState]
    var control: ServerControl
    var handle: UInt64
    var joined: Bool
    var url: String

    def __init__(out self, var tls: Optional[TLSContext] = None) raises:
        var config = ServerConfig.default()
        config.shutdown_grace = Timeout.seconds(1)
        var server = Server(config^)
        var listener = listen_tcp("127.0.0.1:0")
        var port = listener.local_address().port
        if tls:
            server.add_tls_listener(listener^, tls.take())
            self.url = String("https://localhost:") + String(port)
        else:
            server.add_listener(listener^)
            self.url = String("http://127.0.0.1:") + String(port)
        self.control = server.control.copy()
        self.state = ArcPointer(_LoopState(server^))
        self.handle = 0
        self.joined = True
        var rc = external_call["pthread_create", c_int](
            Pointer(to=self.handle),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _loop_entry,
            Pointer(to=self.state[]).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(rc), 0)
        self.joined = False

    def finish(mut self) raises:
        self.control.request_shutdown()
        if not self.joined:
            var rc = external_call["pthread_join", c_int](
                c_ulong(self.handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
            self.joined = True
            assert_equal(Int(rc), 0)
        assert_true(not self.state[].failed)

    def __deinit__(deinit self):
        self.control.request_shutdown()
        if not self.joined:
            _ = external_call["pthread_join", c_int](
                c_ulong(self.handle),
                Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            )
        _ = self.state^


def test_client_32_live_responses_and_idle_cap_against_server() raises:
    var fixture = _LoopFixture()
    var config = ClientConfig.default()
    config.max_conns_per_host = 32
    config.max_idle_conns_per_host = 2
    var client = Client(config^)
    var responses = List[Response]()
    for _ in range(32):
        responses.append(client.do(ClientRequest.get(fixture.url)))
    assert_equal(client._pool.state[].origins[0].count, 32)
    var full = False
    try:
        var _ = client.do(ClientRequest.get(fixture.url))
    except error:
        assert_equal(error.kind, ClientError.POOL_FULL)
        full = True
    assert_true(full)
    for i in range(len(responses)):
        assert_equal(String(from_utf8_lossy=responses[i].read_all()), "hello")
    assert_equal(client._pool.state[].origins[0].count, 2)
    assert_equal(len(client._pool.state[].origins[0].idle), 2)
    client.close()
    assert_equal(client._pool.state[].origins[0].count, 0)
    fixture.finish()
    assert_equal(fixture.state[].handler.requests, 32)


def test_client_1000_keepalive_against_server() raises:
    var fixture = _LoopFixture()
    var client = Client(ClientConfig.default())
    for _ in range(1000):
        var response = client.do(ClientRequest.get(fixture.url))
        assert_equal(String(from_utf8_lossy=response.read_all()), "hello")
    assert_equal(client._pool.state[].origins[0].count, 1)
    assert_equal(len(client._pool.state[].origins[0].idle), 1)
    client.close()
    fixture.finish()
    assert_equal(fixture.state[].handler.requests, 1000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
