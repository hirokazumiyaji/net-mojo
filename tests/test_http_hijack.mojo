from std.sys import size_of
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.error import NetErrorKind
from net.timeout import _Deadline
from net._sys.common import _wait_readable
from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    Headers,
    ResponseWriter,
    ResponseSender,
    HijackSender,
    Handler,
    Request,
    RequestBodyReceiver,
    Server,
    ServerConfig,
    ServerControl,
)
from tests.support import _tick_n
from net.http.response import _HijackContext
from net.http._deadline import now_ns
from net.http._connection import STATE_HIJACKING_FLUSH
from net.http._body_pipe import _BodyPipe
from net.http._buffer import SharedBufferBudget
from net.http._detach import _DetachTarget
from net.http._hijack import (
    _SharedHijackState,
    _hijack_state,
    _release_hijack_state,
)


def _configure(mut writer: ResponseWriter, is_connect: Bool = False) raises:
    writer._set_body_budget(SharedBufferBudget(65536))
    writer._set_hijack_context(
        _HijackContext(
            is_connect, True, ServerControl(), String("date"), 100, 32768
        )
    )


def test_hijack_rejects_standalone_and_multiplexed_writers() raises:
    for protocol in range(3):
        var writer = ResponseWriter(32)
        if protocol != 0:
            _configure(writer)
            if protocol == 1:
                writer._set_detach_target(_DetachTarget.http2(0, 1, 1))
            else:
                writer._set_detach_target(_DetachTarget.http3(1))
        var rejected = False
        try:
            _ = writer.hijack()
        except e:
            assert_equal(e.kind, NetErrorKind.unsupported())
            rejected = True
        assert_true(rejected)
        assert_false(writer.is_hijacked())


def test_raw_hijack_excludes_detach_and_further_body_writes() raises:
    var writer = ResponseWriter(32, slot=2, generation=3)
    _configure(writer)
    var sender = writer.hijack()
    assert_true(writer.is_hijacked())
    var state = _hijack_state(writer._hijack_state_addr)
    assert_equal(state[].slot, 2)
    assert_equal(state[].generation, 3)
    assert_equal(len(state[].pending_response), 0)
    for operation in range(4):
        var rejected = False
        try:
            if operation == 0:
                _ = writer.detach()
            elif operation == 1:
                _ = writer.hijack()
            elif operation == 2:
                writer.write_string("forbidden")
            else:
                writer.add_trailer(String("X-Finish"), String("forbidden"))
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_state())
            rejected = True
        assert_true(rejected)
    sender^.abort()
    _release_hijack_state(writer._hijack_state_addr, from_sender=False)
    writer._hijack_state_addr = 0


def test_detached_writer_cannot_hijack() raises:
    var writer = ResponseWriter(32)
    _configure(writer)
    var sender = writer.detach()
    var rejected = False
    try:
        _ = writer.hijack()
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_state())
        rejected = True
    assert_true(rejected)
    writer._cancel_detach()
    sender.abort()
    _ = sender^


def test_switch_headers_match_request_method() raises:
    for is_connect in [False, True]:
        var writer = ResponseWriter(32)
        _configure(writer, is_connect)
        var headers = Headers()
        if not is_connect:
            headers.add(String("Connection"), String("Upgrade"))
            headers.add(String("Upgrade"), String("echo"))
        var sender = writer.switch_protocols(
            headers^, 200 if is_connect else 101
        )
        var state = _hijack_state(writer._hijack_state_addr)
        var text = String(from_utf8_lossy=Span(state[].pending_response))
        assert_true(
            text.startswith(
                "HTTP/1.1 200 OK\r\n" if is_connect else "HTTP/1.1 101 Switching Protocols\r\n"
            )
        )
        assert_true(text.endswith("\r\n\r\n"))
        assert_true(text.find("Content-Length") < 0)
        sender^.abort()
        _release_hijack_state(writer._hijack_state_addr, from_sender=False)
        writer._hijack_state_addr = 0


def test_writer_drop_cancels_unpublished_handoff() raises:
    var writer = ResponseWriter(32)
    _configure(writer)
    var sender = writer.hijack()
    _ = writer^
    assert_true(sender.is_cancelled())
    var rejected = False
    try:
        _ = sender^.take_connection()
    except e:
        assert_equal(e.kind, NetErrorKind.closed())
        rejected = True
    assert_true(rejected)


def test_failed_hijack_reservations_leave_writer_usable() raises:
    for switching in [False, True]:
        var budget = SharedBufferBudget(
            size_of[_SharedHijackState]() if switching else 1
        )
        var writer = ResponseWriter(32)
        writer._set_body_budget(budget.copy())
        writer._set_hijack_context(
            _HijackContext(
                True, True, ServerControl(), String("date"), 100, 32768
            )
        )
        var rejected = False
        try:
            if switching:
                _ = writer.switch_protocols(Headers(), 200)
            else:
                _ = writer.hijack()
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_true(rejected)
        assert_false(writer.is_hijacked())
        assert_equal(budget.used(), 0)


def test_shutdown_and_http10_cannot_start_handoff() raises:
    for shutting_down in [False, True]:
        var writer = ResponseWriter(32)
        var control = ServerControl()
        if shutting_down:
            control.request_shutdown()
        writer._set_hijack_context(
            _HijackContext(
                False, shutting_down, control^, String("date"), 100, 32768
            )
        )
        var rejected = False
        try:
            _ = writer.hijack()
        except e:
            assert_equal(
                e.kind,
                NetErrorKind.closed() if shutting_down else NetErrorKind.unsupported(),
            )
            rejected = True
        assert_true(rejected)


def test_invalid_switch_status_keeps_writer_buffered() raises:
    for is_connect in [False, True]:
        var writer = ResponseWriter(32)
        _configure(writer, is_connect)
        var rejected = False
        try:
            _ = writer.switch_protocols(Headers(), 101 if is_connect else 200)
        except e:
            assert_equal(e.kind, NetErrorKind.invalid_argument())
            rejected = True
        assert_true(rejected)
        assert_false(writer.is_hijacked())
        writer.write_string("ordinary response")


struct _RawHandler(Handler):
    var sender: Optional[HijackSender]
    var switching: Bool

    def __init__(out self, switching: Bool):
        self.sender = None
        self.switching = switching

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if self.switching:
            var headers = Headers()
            headers.add(String("Connection"), String("Upgrade"))
            headers.add(String("Upgrade"), String("echo"))
            self.sender = writer.switch_protocols(headers^)
        else:
            self.sender = writer.hijack()


def test_http1_handoff_preserves_surplus_and_retires_slot() raises:
    for switching in [False, True]:
        var config = ServerConfig.default()
        config.max_bytes_per_tick = 13
        config.max_connections = 1
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var client = dial_tcp(address, Timeout.seconds(1))
        client.write_all(
            "GET / HTTP/1.1\r\nHost: local\r\n\r\nsurplus".as_bytes(),
            Timeout.seconds(1),
        )
        var handler = _RawHandler(switching)
        _tick_n(server, handler, 30)
        assert_true(handler.sender)
        assert_equal(server.active_connections(), 0)
        var connection = handler.sender.take().take_connection()
        assert_equal(server._budget.used(), 0)
        var buffered = connection.take_buffered()
        assert_equal(String(from_utf8_lossy=Span(buffered)), "surplus")
        _ = connection.write("raw".as_bytes(), Timeout.seconds(1))
        var bytes = Array[Byte, 512](fill=0)
        var received = List[Byte]()
        var wire = String("")
        while not wire.endswith("raw"):
            var count = client.read(Span(bytes), Timeout.seconds(1))
            assert_true(count > 0)
            received.extend(Span(bytes)[0:count])
            wire = String(from_utf8_lossy=Span(received))
        if switching:
            assert_true(wire.startswith("HTTP/1.1 101 Switching Protocols\r\n"))
            assert_true(wire.endswith("\r\n\r\nraw"))
        else:
            assert_equal(wire, "raw")
        connection^.close()
        client.close()


struct _ConnectResponseHandler(Handler):
    var mode: Int
    var sender: Optional[ResponseSender]
    var raw: Optional[HijackSender]

    def __init__(out self, mode: Int):
        self.mode = mode
        self.sender = None
        self.raw = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        assert_equal(request.authority, "local:443")
        assert_equal(request.path, "")
        assert_equal(request.query, "")
        if self.mode == 1 or self.mode == 2:
            self.sender = writer.detach()
        elif self.mode == 3:
            self.raw = writer.switch_protocols(Headers(), 200)
        elif self.mode == 4:
            writer.status = 405
            writer.should_close = True


def test_connect_success_requires_raw_takeover_in_all_response_paths() raises:
    for mode in range(5):
        var server = Server(ServerConfig.default())
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var client = dial_tcp(address, Timeout.seconds(1))
        client.write_all(
            "CONNECT local:443 HTTP/1.1\r\nHost: local:443\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        var handler = _ConnectResponseHandler(mode)
        _tick_n(server, handler, 10)
        if mode == 1:
            handler.sender.value().respond()
        elif mode == 2:
            handler.sender.value().start()
        _tick_n(server, handler, 10)
        if mode == 3:
            assert_true(handler.raw)
            var connection = handler.raw.take().take_connection()
            assert_equal(server.active_connections(), 0)
            assert_equal(server._budget.used(), 0)
            connection^.close()
        var bytes = Array[Byte, 512](fill=0)
        var count = client.read(Span(bytes), Timeout.seconds(1))
        var wire = String(from_utf8_lossy=Span(bytes)[0:count])
        if mode == 3:
            assert_true(wire.startswith("HTTP/1.1 200 OK\r\n"))
            assert_true(wire.find("Content-Length") < 0)
            assert_true(wire.find("Transfer-Encoding") < 0)
        elif mode == 4:
            assert_true(wire.startswith("HTTP/1.1 405"))
        else:
            assert_true(wire.startswith("HTTP/1.1 500"))
        client.close()


struct _SlowSwitchHandler(Handler):
    var sender: Optional[HijackSender]
    var fail: Bool

    def __init__(out self, fail: Bool = False):
        self.sender = None
        self.fail = fail

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        var headers = Headers()
        headers.add(String("Connection"), String("Upgrade"))
        headers.add(String("Upgrade"), String("echo"))
        headers.add(String("X-Padding"), String("x" * 1024))
        self.sender = writer.switch_protocols(headers^)
        if self.fail:
            raise Error("ordinary handler failure")


def _until_switch(mut server: Server, mut handler: _SlowSwitchHandler) raises:
    var expires = Int(perf_counter_ns()) + 1_000_000_000
    while not handler.sender and Int(perf_counter_ns()) < expires:
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_true(handler.sender)


def _check_pending_switch_cancellation(cause: Int) raises:
    var config = ServerConfig.default()
    config.max_bytes_per_tick = 64
    config.shutdown_grace = Timeout.nanoseconds(0)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var client = dial_tcp(address, Timeout.seconds(1))
    client.write_all(
        "GET / HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(),
        Timeout.seconds(1),
    )
    var handler = _SlowSwitchHandler()
    _until_switch(server, handler)
    assert_equal(server._conns[0].state, STATE_HIJACKING_FLUSH)
    if cause == 0:
        handler.sender.take().abort()
    elif cause == 1:
        server._conns[0].write_at = now_ns() - 1
        server._arm_deadline(0)
    elif cause == 2:
        client.shutdown(False, True)
        assert_true(
            _wait_readable(
                server._conns[0].raw_fd(),
                _Deadline.from_timeout(Timeout.seconds(1)),
            )
        )
    elif cause == 3:
        server.request_shutdown()
    else:
        server._conns[0].conn.value().close()
        server._conns[0].reset_tick()
        server._pump_hijack(0)
    _tick_n(server, handler, 3)
    assert_equal(server.active_connections(), 0)
    if cause != 0:
        var rejected = False
        try:
            _ = handler.sender.take().take_connection()
        except e:
            assert_equal(e.kind, NetErrorKind.closed())
            rejected = True
        assert_true(rejected)
    assert_equal(server._budget.used(), 0)
    client.close()


def test_pending_switch_cancels_on_abort() raises:
    _check_pending_switch_cancellation(0)


def test_pending_switch_cancels_on_deadline() raises:
    _check_pending_switch_cancellation(1)


def test_pending_switch_cancels_on_peer_eof() raises:
    _check_pending_switch_cancellation(2)


def test_pending_switch_cancels_on_expired_shutdown_grace() raises:
    _check_pending_switch_cancellation(3)


def test_pending_switch_cancels_on_write_error() raises:
    _check_pending_switch_cancellation(4)


def test_handler_failure_and_server_drop_cancel_handoff() raises:
    for fail_handler in [False, True]:
        var config = ServerConfig.default()
        config.max_bytes_per_tick = 64
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var client = dial_tcp(address, Timeout.seconds(1))
        client.write_all(
            "GET / HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        var handler = _SlowSwitchHandler(fail_handler)
        _until_switch(server, handler)
        _ = server^
        var rejected = False
        try:
            _ = handler.sender.take().take_connection()
        except e:
            assert_equal(e.kind, NetErrorKind.closed())
            rejected = True
        assert_true(rejected)
        client.close()


def test_started_switch_drains_within_shutdown_grace() raises:
    var config = ServerConfig.default()
    config.max_bytes_per_tick = 64
    config.shutdown_grace = Timeout.seconds(1)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var address = String("127.0.0.1:") + String(server.local_address().port)
    var client = dial_tcp(address, Timeout.seconds(1))
    client.write_all(
        "GET / HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    var handler = _SlowSwitchHandler()
    _until_switch(server, handler)
    server.request_shutdown()
    _tick_n(server, handler, 30)
    assert_equal(server.active_connections(), 0)
    var connection = handler.sender.take().take_connection()
    assert_equal(server._budget.used(), 0)
    _ = connection.write("owned".as_bytes(), Timeout.seconds(1))
    connection^.close()
    client.close()


def test_hijack_requires_consumed_streaming_body_and_no_active_receiver() raises:
    for mode in range(5):
        var pipe = _BodyPipe(8, SharedBufferBudget(64))
        assert_true(pipe.push("body".as_bytes()))
        if mode != 4:
            pipe.push_eof()
        var writer = ResponseWriter(32)
        _configure(writer)
        writer._set_request_body_pipe(Optional(pipe.copy()))
        var receiver: Optional[RequestBodyReceiver] = None
        if mode == 1:
            var bytes = Array[Byte, 4](fill=0)
            assert_equal(pipe.pop(Span(bytes)), 4)
        elif mode >= 2:
            pipe.mark_reader_detached()
            receiver = RequestBodyReceiver(pipe.copy())
            if mode != 4:
                var bytes = Array[Byte, 4](fill=0)
                assert_equal(receiver.value().receive(Span(bytes)), 4)
            if mode >= 3:
                receiver = None
        var rejected = False
        try:
            var sender = writer.hijack()
            sender^.abort()
        except error:
            assert_equal(error.kind, NetErrorKind.invalid_state())
            rejected = True
        assert_equal(rejected, mode == 0 or mode == 2 or mode == 4)
        assert_equal(Bool(receiver), mode == 2)
        writer._cancel_hijack()
        _ = receiver^


struct _StreamingSwitchHandler(Handler):
    var mode: Int
    var rejected: Bool
    var sender: Optional[HijackSender]
    var receiver: Optional[RequestBodyReceiver]

    def __init__(out self, mode: Int):
        self.mode = mode
        self.rejected = False
        self.sender = None
        self.receiver = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if request.path == "/next":
            writer.write_string("next")
            return
        var reader = request.body_reader()
        if self.mode == 1:
            var bytes = Array[Byte, 4](fill=0)
            assert_equal(reader.read(Span(bytes)), 4)
        elif self.mode >= 2:
            self.receiver = reader.detach()
            if self.mode != 4:
                var bytes = Array[Byte, 4](fill=0)
                assert_equal(self.receiver.value().receive(Span(bytes)), 4)
            if self.mode >= 3:
                self.receiver = None
        try:
            self.sender = writer.hijack()
        except error:
            assert_equal(error.kind, NetErrorKind.invalid_state())
            self.rejected = True
            writer.write_string("rejected")


def test_streaming_request_handoff_uses_owned_pipe_after_initial_feed() raises:
    for mode in range(4):
        var config = ServerConfig.default()
        config.enable_request_body_streaming = True
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var client = dial_tcp(
            String(server.local_address()), Timeout.seconds(1)
        )
        client.write_all(
            "POST / HTTP/1.1\r\nHost: local\r\nContent-Length:"
            " 4\r\n\r\nbodysurplus".as_bytes(),
            Timeout.seconds(1),
        )
        var handler = _StreamingSwitchHandler(mode)
        _tick_n(server, handler, 30)
        assert_equal(handler.rejected, mode == 0 or mode == 2)
        if mode == 1 or mode == 3:
            assert_true(handler.sender)
            var connection = handler.sender.take().take_connection()
            assert_equal(
                String(from_utf8_lossy=connection.buffered()), "surplus"
            )
            assert_equal(server.active_connections(), 0)
            connection^.close()
        else:
            assert_false(handler.sender)
        client.close()


def test_dropped_standalone_receiver_before_eof_drains_before_pipeline() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    client.write_all(
        "POST / HTTP/1.1\r\nHost: local\r\nContent-Length: 4\r\n\r\n".as_bytes(),
        Timeout.seconds(1),
    )
    var handler = _StreamingSwitchHandler(4)
    _tick_n(server, handler, 10)
    assert_true(handler.rejected)
    assert_false(handler.receiver)
    assert_equal(server.active_connections(), 1)
    client.write_all(
        "bodyGET /next HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(),
        Timeout.seconds(1),
    )
    _tick_n(server, handler, 30)
    var bytes = Array[Byte, 1024](fill=0)
    var count = client.read(Span(bytes), Timeout.seconds(1))
    var wire = String(from_utf8_lossy=Span(bytes)[0:count])
    assert_true(wire.find("rejected") >= 0)
    assert_true(wire.find("next") >= 0)
    client.close()


def test_expired_switch_cannot_publish_on_a_delayed_writable_tick() raises:
    for shutdown in [False, True]:
        var config = ServerConfig.default()
        config.max_bytes_per_tick = 64
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var client = dial_tcp(
            String(server.local_address()), Timeout.seconds(1)
        )
        client.write_all(
            "GET / HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        var handler = _SlowSwitchHandler()
        _until_switch(server, handler)
        assert_equal(server._conns[0].state, STATE_HIJACKING_FLUSH)
        if shutdown:
            server._shutdown_at = now_ns() - 1
        else:
            server._conns[0].write_at = now_ns() - 1
        server.config.max_bytes_per_tick = 32768
        server._conns[0].reset_tick()
        server._pump_hijack(0)
        assert_true(handler.sender.value().is_cancelled())
        assert_equal(server.active_connections(), 0)
        var closed = False
        try:
            _ = handler.sender.take().take_connection()
        except error:
            closed = error.kind == NetErrorKind.closed()
        assert_true(closed)
        assert_equal(server._budget.used(), 0)
        client.close()


struct _DetachAfterHijackHandler(Handler):
    var sender: Optional[HijackSender]
    var receiver: Optional[RequestBodyReceiver]

    def __init__(out self):
        self.sender = None
        self.receiver = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        var reader = request.body_reader()
        var bytes = Array[Byte, 4](fill=0)
        assert_equal(reader.read(Span(bytes)), 4)
        assert_true(reader.is_eof())
        self.sender = writer.hijack()
        self.receiver = reader.detach()


def test_detaching_reader_after_hijack_cancels_before_transport_transfer() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    client.write_all(
        "POST / HTTP/1.1\r\nHost: local\r\nContent-Length: 4\r\n\r\nbody"
        .as_bytes(),
        Timeout.seconds(1),
    )
    var handler = _DetachAfterHijackHandler()
    _tick_n(server, handler, 30)
    assert_true(handler.sender)
    assert_true(handler.receiver)
    assert_true(handler.receiver.value().is_eof())
    assert_true(handler.sender.value().is_cancelled())
    var closed = False
    try:
        _ = handler.sender.take().take_connection()
    except error:
        closed = error.kind == NetErrorKind.closed()
    assert_true(closed)
    var bytes = Array[Byte, 512](fill=0)
    var count = client.read(Span(bytes), Timeout.seconds(1))
    assert_true(
        String(from_utf8_lossy=Span(bytes)[0:count]).startswith("HTTP/1.1 500")
    )
    client.close()


def test_peer_half_close_cancels_transfer_before_cached_readiness_updates() raises:
    var config = ServerConfig.default()
    config.max_bytes_per_tick = 64
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(String(server.local_address()), Timeout.seconds(1))
    client.write_all(
        "GET / HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    var handler = _SlowSwitchHandler()
    _until_switch(server, handler)
    client.write_all("protocol bytes".as_bytes(), Timeout.seconds(1))
    client.shutdown(False, True)
    assert_true(
        _wait_readable(
            server._conns[0].raw_fd(),
            _Deadline.from_timeout(Timeout.seconds(1)),
        )
    )
    assert_false(server._conns[0].peer_hangup)
    assert_false(server._conns[0].read_eof)
    server.config.max_bytes_per_tick = 32768
    server._conns[0].reset_tick()
    server._pump_hijack(0)
    assert_true(handler.sender.value().is_cancelled())
    assert_equal(server.active_connections(), 0)
    client.close()


def test_short_request_and_immediate_half_close_never_publish_raw_owner() raises:
    for switching in [False, True]:
        var server = Server(ServerConfig.default())
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var client = dial_tcp(
            String(server.local_address()), Timeout.seconds(1)
        )
        client.write_all(
            "GET / HTTP/1.1\r\nHost: local\r\n\r\nsurplus".as_bytes(),
            Timeout.seconds(1),
        )
        client.shutdown(False, True)
        var handler = _RawHandler(switching)
        _tick_n(server, handler, 30)
        if handler.sender:
            assert_true(handler.sender.value().is_cancelled())
        assert_equal(server.active_connections(), 0)
        client.close()


struct _ShutdownAfterHijackHandler(Handler):
    var control: ServerControl
    var sender: Optional[HijackSender]

    def __init__(out self, var control: ServerControl):
        self.control = control^
        self.sender = None

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        self.sender = writer.hijack()
        self.control.request_shutdown()


def test_shutdown_requested_during_handler_applies_grace_before_handoff() raises:
    for expires in [False, True]:
        var config = ServerConfig.default()
        config.shutdown_grace = Timeout.nanoseconds(
            0
        ) if expires else Timeout.seconds(1)
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var client = dial_tcp(
            String(server.local_address()), Timeout.seconds(1)
        )
        client.write_all(
            "GET / HTTP/1.1\r\nHost: local\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        var handler = _ShutdownAfterHijackHandler(server.control.copy())
        _tick_n(server, handler, 30)
        assert_true(handler.sender)
        assert_equal(handler.sender.value().is_cancelled(), expires)
        if not expires:
            var connection = handler.sender.take().take_connection()
            connection^.close()
        assert_equal(server.active_connections(), 0)
        client.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
