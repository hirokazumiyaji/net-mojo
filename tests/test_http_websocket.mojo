from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, TestSuite
from net import Timeout
from net.error import NetError
from net.http.websocket import (
    DuplexStream,
    WebSocketConfig,
    WebSocketConn,
    WebSocketMessage,
)


struct _MemoryState:
    var outgoing: List[Byte]
    var closed: Bool

    def __init__(out self):
        self.outgoing = List[Byte]()
        self.closed = False


struct _MemoryStream(DuplexStream):
    var incoming: List[Byte]
    var state: ArcPointer[_MemoryState]
    var offset: Int
    var require_closing_pong: Bool
    var read_delay_ns: UInt64
    var write_delay_ns: UInt64

    def __init__(out self, var incoming: List[Byte]):
        self.incoming = incoming^
        self.state = ArcPointer(_MemoryState())
        self.offset = 0
        self.require_closing_pong = False
        self.read_delay_ns = 0
        self.write_delay_ns = 0

    def read[
        o: MutOrigin
    ](
        mut self, buffer: Span[mut=True, Byte, o], timeout: Timeout
    ) raises NetError -> Int:
        if self.read_delay_ns > 0:
            if timeout._value < self.read_delay_ns:
                sleep(Float64(timeout._value) / 1_000_000_000)
                raise NetError(
                    .timeout(), "memory read", None, "read deadline elapsed"
                )
            sleep(Float64(self.read_delay_ns) / 1_000_000_000)
        if self.offset == len(self.incoming):
            raise NetError(
                .timeout(), "memory read", None, "no available bytes"
            )
        var count = min(3, min(len(buffer), len(self.incoming) - self.offset))
        for i in range(count):
            buffer[i] = self.incoming[self.offset + i]
        self.offset += count
        return count

    def write[
        o: ImmOrigin
    ](mut self, buffer: Span[Byte, o], timeout: Timeout) raises NetError -> Int:
        if self.write_delay_ns > 0:
            if timeout._value < self.write_delay_ns:
                sleep(Float64(timeout._value) / 1_000_000_000)
                raise NetError(
                    .timeout(), "memory write", None, "write deadline elapsed"
                )
            sleep(Float64(self.write_delay_ns) / 1_000_000_000)
        var count = min(2, len(buffer))
        self.state[].outgoing.extend(buffer[0:count])
        return count

    def close(deinit self) raises NetError:
        self.state[].closed = True
        if self.require_closing_pong:
            var found = False
            for i in range(max(0, len(self.state[].outgoing) - 2)):
                if (
                    self.state[].outgoing[i] == 138
                    and self.state[].outgoing[i + 1] == 1
                    and self.state[].outgoing[i + 2] == 120
                ):
                    found = True
            if not found:
                raise NetError(
                    .invalid_state(),
                    "memory close",
                    None,
                    "closing Ping was not answered",
                )


def test_fragmented_text_with_ping_interruption() raises:
    var wire: List[Byte] = [
        1,
        130,
        0,
        0,
        0,
        0,
        72,
        101,
        137,
        129,
        0,
        0,
        0,
        0,
        120,
        128,
        131,
        0,
        0,
        0,
        0,
        108,
        108,
        111,
    ]
    var ws = _make_ws(wire^)
    var message = _read_message(ws)
    assert_equal(message.opcode, 1)
    assert_equal(String(from_utf8_lossy=Span(message.payload)), "Hello")
    assert_equal(ws._stream.value().state[].outgoing[0], 138)
    assert_equal(ws._stream.value().state[].outgoing[2], 120)


def test_server_writer_completes_partial_writes() raises:
    var ws = _make_ws(List[Byte]())
    try:
        ws.write_text("Hello")
    except err:
        raise Error(String(err))
    assert_equal(len(ws._stream.value().state[].outgoing), 7)
    assert_equal(ws._stream.value().state[].outgoing[0], 129)
    assert_equal(ws._stream.value().state[].outgoing[1], 5)


def _make_ws(var incoming: List[Byte]) raises -> WebSocketConn[_MemoryStream]:
    try:
        return WebSocketConn[_MemoryStream](
            _MemoryStream(incoming^), WebSocketConfig.default()
        )
    except err:
        raise Error(String(err))


def _read_message(
    mut ws: WebSocketConn[_MemoryStream],
) raises -> WebSocketMessage:
    try:
        return ws.read_message()
    except err:
        raise Error(String(err))


def _expect_close(
    var input: List[Byte],
    code: UInt16,
    var config: WebSocketConfig = WebSocketConfig.default(),
) raises:
    var ws = _make_configured_ws(input^, config)
    var state = ws._stream.value().state.copy()
    var failed = False
    try:
        _ = ws.read_message()
    except:
        failed = True
    assert_true(failed)
    assert_true(ws.is_closed())
    assert_equal(state[].outgoing[0], 136)
    assert_equal(state[].outgoing[1], 2)
    assert_equal(
        (UInt16(state[].outgoing[2]) << 8) | UInt16(state[].outgoing[3]),
        code,
    )


def _make_configured_ws(
    var input: List[Byte], config: WebSocketConfig
) raises -> WebSocketConn[_MemoryStream]:
    try:
        return WebSocketConn[_MemoryStream](_MemoryStream(input^), config)
    except err:
        raise Error(String(err))


def test_fragment_state_and_utf8_fail_with_expected_close() raises:
    _expect_close([128, 128, 0, 0, 0, 0], 1002)
    _expect_close([1, 128, 0, 0, 0, 0, 129, 128, 0, 0, 0, 0], 1002)
    _expect_close([129, 130, 0, 0, 0, 0, 192, 128], 1007)
    _expect_close([1, 129, 0, 0, 0, 0, 240, 128, 128, 0, 0, 0, 0], 1007)


def test_message_fragment_and_frame_limits() raises:
    var config = WebSocketConfig.default()
    config.max_message_bytes = 3
    _expect_close(
        [2, 130, 0, 0, 0, 0, 1, 2, 128, 130, 0, 0, 0, 0, 3, 4],
        1009,
        config.copy(),
    )
    config.max_fragment_count = 1
    _expect_close(
        [2, 128, 0, 0, 0, 0, 128, 128, 0, 0, 0, 0], 1008, config.copy()
    )
    config.max_frame_bytes = 1
    _expect_close([130, 130, 0, 0, 0, 0], 1009, config^)


def test_peer_close_echo_and_retained_reason() raises:
    var ws = _make_ws([136, 132, 0, 0, 0, 0, 3, 232, 111, 107])
    var state = ws._stream.value().state.copy()
    var closed = False
    try:
        _ = ws.read_message()
    except err:
        closed = err.kind == .closed()
    assert_true(closed)
    assert_true(ws.is_closed())
    var info = ws.close_info().value().copy()
    assert_equal(info.code, 1000)
    assert_equal(info.reason, "ok")
    assert_equal(len(state[].outgoing), 6)
    assert_equal(state[].outgoing[0], 136)
    assert_equal(state[].outgoing[5], 107)


def test_ping_limit_rejects_before_writing() raises:
    var ws = _make_ws(List[Byte]())
    var payload = List[Byte](length=126, fill=0)
    var rejected = False
    try:
        ws.write_ping(Span(payload))
    except err:
        rejected = err.kind == .invalid_argument()
    assert_true(rejected)
    assert_equal(len(ws._stream.value().state[].outgoing), 0)
    assert_equal(ws.is_closed(), False)


from net import dial_tcp, listen_tcp
from net.http import (
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    HttpVersion,
)
from net.http.websocket import (
    WebSocketUpgrade,
    websocket_accept,
    websocket_adopt,
    _handshake,
)


struct _UpgradeHandler(Handler):
    var upgrade: Optional[WebSocketUpgrade]

    def __init__(out self):
        self.upgrade = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        var config = WebSocketConfig.default()
        config.subprotocols.append(String("chat"))
        try:
            self.upgrade = websocket_accept(request, writer, config)
        except err:
            raise Error(String(err))


def test_live_upgrade_preserves_protocol_and_coalesced_frame() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    var wire = List[Byte]()
    wire.extend(
        "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive,"
        " Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version:"
        " 13\r\nSec-WebSocket-Key:"
        " dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: other,"
        " chat\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
        .as_bytes()
    )
    var frame: List[Byte] = [129, 130, 0, 0, 0, 0, 72, 105]
    wire.extend(Span(frame))
    client.write_all(Span(wire), Timeout.seconds(1))
    var handler = _UpgradeHandler()
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(10))
        if handler.upgrade and server.active_connections() == 0:
            break
    assert_true(handler.upgrade)
    assert_equal(server.active_connections(), 0)
    var protocol: String
    var received: String
    try:
        var ws = websocket_adopt(handler.upgrade.take())
        protocol = ws.selected_subprotocol()
        var message = ws.read_message()
        received = String(from_utf8_lossy=Span(message.payload))
        ws.write_text("Hi")
        _ = ws^
    except err:
        raise Error(String(err))
    assert_equal(protocol, "chat")
    assert_equal(received, "Hi")
    var response = List[Byte]()
    var scratch = Array[Byte, 512](fill=0)
    while True:
        var count = client.read(Span(scratch), Timeout.seconds(1))
        if count == 0:
            break
        response.extend(Span(scratch)[0:count])
    var text = String(from_utf8_lossy=Span(response))
    assert_true(text.startswith("HTTP/1.1 101 Switching Protocols\r\n"))
    assert_true("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in text)
    assert_true("Sec-WebSocket-Protocol: chat" in text)
    assert_equal("Sec-WebSocket-Extensions" in text, False)
    assert_equal(response[len(response) - 4], 129)


def _request() raises -> Request:
    var request = Request(
        String("GET"), String("/"), String("/"), String(), HttpVersion.http11()
    )
    request.headers.add(String("Connection"), String("Upgrade"))
    request.headers.add(String("Upgrade"), String("websocket"))
    request.headers.add(String("Sec-WebSocket-Version"), String("13"))
    request.headers.add(
        String("Sec-WebSocket-Key"), String("dGhlIHNhbXBsZSBub25jZQ==")
    )
    return request^


def test_handshake_rejects_duplicates_and_invalid_subprotocols() raises:
    for scenario in range(5):
        var request = _request()
        if scenario == 0:
            request.headers.add(
                String("Sec-WebSocket-Key"), String("dGhlIHNhbXBsZSBub25jZQ==")
            )
        elif scenario == 1:
            request.headers.add(String("Sec-WebSocket-Version"), String("13"))
        elif scenario == 2:
            request.headers.add(
                String("Sec-WebSocket-Protocol"), String("chat, chat")
            )
        elif scenario == 3:
            request.headers.add(
                String("Sec-WebSocket-Protocol"), String("bad protocol")
            )
        else:
            request.method = String("POST")
        var rejected = False
        try:
            _ = _handshake(request, WebSocketConfig.default())
        except err:
            rejected = err.kind == .invalid_argument()
        assert_true(rejected)


def test_explicit_close_waits_for_peer_close() raises:
    var ws = _make_ws([136, 130, 0, 0, 0, 0, 3, 232])
    try:
        ws^.close()
    except err:
        raise Error(String(err))


def test_missing_keepalive_pong_closes_with_1011() raises:
    var config = WebSocketConfig.default()
    config.ping_interval = Timeout.nanoseconds(1_000_000)
    config.read_deadline = Timeout.nanoseconds(50_000_000)
    var ws = _make_configured_ws(List[Byte](), config)
    var state = ws._stream.value().state.copy()
    var rejected = False
    try:
        _ = ws.read_message()
    except:
        rejected = True
    assert_true(rejected)
    assert_true(ws.is_closed())
    assert_equal(state[].outgoing[0], 137)
    var length = len(state[].outgoing)
    assert_equal(state[].outgoing[length - 4], 136)
    assert_equal(
        (UInt16(state[].outgoing[length - 2]) << 8)
        | UInt16(state[].outgoing[length - 1]),
        1011,
    )


def test_writer_fragments_at_frame_limit() raises:
    var config = WebSocketConfig.default()
    config.max_frame_bytes = 3
    var ws = _make_configured_ws(List[Byte](), config)
    try:
        ws.write_text("Hello")
    except err:
        raise Error(String(err))
    assert_equal(len(ws._stream.value().state[].outgoing), 9)
    assert_equal(ws._stream.value().state[].outgoing[0], 1)
    assert_equal(ws._stream.value().state[].outgoing[1], 3)
    assert_equal(ws._stream.value().state[].outgoing[5], 128)
    assert_equal(ws._stream.value().state[].outgoing[6], 2)


def test_closing_handshake_disables_keepalive() raises:
    for waiting_pong in [False, True]:
        var config = WebSocketConfig.default()
        config.ping_interval = Timeout.nanoseconds(1)
        var ws = _make_configured_ws([136, 130, 0, 0, 0, 0, 3, 232], config)
        ws._waiting_pong = waiting_pong
        try:
            ws^.close()
        except err:
            raise Error(String(err))


def test_closing_handshake_answers_inflight_ping() raises:
    var ws = _make_ws([137, 129, 0, 0, 0, 0, 120, 136, 130, 0, 0, 0, 0, 3, 232])
    ws._stream.value().require_closing_pong = True
    try:
        ws^.close()
    except err:
        raise Error(String(err))


from std.time import sleep
from net.timeout import _Deadline


def test_queued_pong_survives_application_processing_pause() raises:
    var config = WebSocketConfig.default()
    config.ping_interval = Timeout.nanoseconds(40_000_000)
    var ws = _make_configured_ws(
        [
            129,
            129,
            0,
            0,
            0,
            0,
            65,
            138,
            129,
            0,
            0,
            0,
            0,
            9,
            129,
            129,
            0,
            0,
            0,
            0,
            66,
        ],
        config,
    )
    ws._waiting_pong = True
    ws._ping_payload.append(9)
    ws._ping_deadline = _Deadline.from_timeout(config.ping_interval)
    var first = _read_message(ws)
    assert_equal(first.payload[0], 65)
    sleep(0.08)
    var second = _read_message(ws)
    assert_equal(second.payload[0], 66)
    assert_equal(ws._waiting_pong, False)


def test_control_frames_share_message_operation_deadline() raises:
    var config = WebSocketConfig.default()
    config.read_deadline = Timeout.nanoseconds(40_000_000)
    var wire = List[Byte]()
    var ping: List[Byte] = [137, 129, 0, 0, 0, 0, 120]
    for _ in range(20):
        wire.extend(Span(ping))
    var final: List[Byte] = [129, 129, 0, 0, 0, 0, 65]
    wire.extend(Span(final))
    var ws = _make_configured_ws(wire^, config)
    ws._stream.value().read_delay_ns = 1_000_000
    var expired = False
    try:
        _ = ws.read_message()
    except err:
        expired = err.is_timeout()
    assert_true(expired)
    assert_true(ws.is_closed())


from std.time import perf_counter_ns
from net.http.switch import HijackedConn
from net.http._websocket_conn import _HijackedWebSocketStream


def test_peer_close_releases_tcp_while_metadata_remains_owned() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var raw = HijackedConn(listener.accept(Timeout.seconds(1)), List[Byte]())
    var config = WebSocketConfig.default()
    var ws: WebSocketConn[_HijackedWebSocketStream]
    try:
        ws = WebSocketConn(_HijackedWebSocketStream(raw^), config)
    except err:
        raise Error(String(err))
    var wire: List[Byte] = [136, 130, 0, 0, 0, 0, 3, 232]
    client.write_all(Span(wire), Timeout.seconds(1))
    try:
        _ = ws.read_message()
    except:
        pass
    assert_true(ws.is_closed())
    assert_equal(ws.close_info().value().code, 1000)
    var incoming = Array[Byte, 4](fill=0)
    var offset = 0
    while offset < 4:
        offset += client.read(Span(incoming)[offset:], Timeout.seconds(1))
    var eof = False
    try:
        eof = client.read(Span(incoming), Timeout.milliseconds(20)) == 0
    except:
        pass
    assert_true(eof)
    assert_equal(ws.close_info().value().code, 1000)


def test_automatic_control_writes_share_read_budget() raises:
    for scenario in range(4):
        var config = WebSocketConfig.default()
        config.read_deadline = Timeout.nanoseconds(10_000_000)
        config.write_deadline = Timeout.nanoseconds(500_000_000)
        if scenario == 3:
            config.ping_interval = Timeout.nanoseconds(1)
        var wire: List[Byte] = [137, 129, 0, 0, 0, 0, 120]
        if scenario == 1:
            wire = [136, 130, 0, 0, 0, 0, 3, 232]
        elif scenario == 2:
            wire = [193, 128]
        var ws = _make_configured_ws(wire^, config)
        ws._stream.value().write_delay_ns = 50_000_000
        var started = perf_counter_ns()
        var expired = False
        try:
            _ = ws.read_message()
        except err:
            expired = err.is_timeout()
        assert_true(expired or scenario == 2)
        assert_true(perf_counter_ns() - started < 70_000_000)


struct _FailingWriteStream(DuplexStream):
    var inner: _MemoryStream
    var writes: Int

    def __init__(out self):
        self.inner = _MemoryStream(List[Byte]())
        self.writes = 0

    def read[
        o: MutOrigin
    ](
        mut self, buffer: Span[mut=True, Byte, o], timeout: Timeout
    ) raises NetError -> Int:
        return self.inner.read(buffer, timeout)

    def write[
        o: ImmOrigin
    ](mut self, buffer: Span[Byte, o], timeout: Timeout) raises NetError -> Int:
        if self.writes > 0:
            raise NetError(
                .timeout(),
                "injected partial write",
                123,
                "original timeout",
                321,
            )
        self.writes += 1
        return self.inner.write(buffer, timeout)

    def close(deinit self) raises NetError:
        self.inner^.close()


def test_partial_write_timeout_aborts_and_preserves_original_error() raises:
    var ws: WebSocketConn[_FailingWriteStream]
    try:
        ws = WebSocketConn[_FailingWriteStream](
            _FailingWriteStream(), WebSocketConfig.default()
        )
    except err:
        raise Error(String(err))
    var state = ws._stream.value().inner.state.copy()
    var preserved = False
    try:
        ws.write_text("Hello")
    except err:
        preserved = (
            err.is_timeout()
            and err.operation == "injected partial write"
            and err.message == "original timeout"
            and err.errno.value() == 123
            and err.resolver_status.value() == 321
        )
    assert_true(preserved)
    assert_true(ws.is_closed())
    assert_true(state[].closed)
    assert_equal(len(state[].outgoing), 2)
    assert_equal(state[].outgoing[0], 129)
    assert_equal(state[].outgoing[1], 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
