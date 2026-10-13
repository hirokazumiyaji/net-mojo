from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.ffi import c_int, external_call
from std.memory import OwnedPointer
from std.time import sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    Request,
    RequestBodyEndpoints,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
)
from tests.support import _header_end, _status_of
from tests.support import _join_thread
from tests.test_http_detach import _tick_and_read


struct _BodyHandler(Handler):
    var calls: Int
    var endpoints: Optional[RequestBodyEndpoints]

    def __init__(out self):
        self.calls = 0
        self.endpoints = None

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.calls += 1
        if req.path == "/next":
            writer.write_string("next")
            return
        self.endpoints = writer.detach_with_body(req)


struct _DiscardHandler(Handler):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.calls += 1
        var body = req.body_reader()
        body.discard()
        writer.write_string(req.path)


@fieldwise_init
struct _IgnoreBodyHandler(Handler):
    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.write_string("ignored")


def _connect(mut server: Server) raises -> TCPConn:
    server.add_listener(listen_tcp("127.0.0.1:0"))
    return dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )


def _wait_for_handler(mut server: Server, mut handler: _BodyHandler) raises:
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(1))
        if handler.calls > 0:
            break
    assert_equal(handler.calls, 1)
    assert_true(handler.endpoints)


def _receive_body(
    mut server: Server, mut handler: _BodyHandler
) raises -> List[Byte]:
    var body = List[Byte]()
    var buffer = Array[Byte, 3](fill=0)
    var eof = False
    for _ in range(1000):
        _ = server.tick(handler, Timeout.milliseconds(1))
        try:
            var count = handler.endpoints.value().receiver.receive(
                Span(buffer), Timeout.nanoseconds(0)
            )
            if count == 0:
                eof = True
                break
            body.extend(Span(buffer)[:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
    assert_true(eof)
    return body^


def test_header_only_dispatch_and_large_fixed_body() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 8
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 24\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    client.write_all(
        String("abcdefghijklmnopqrstuvwx").as_bytes(), Timeout.seconds(1)
    )
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), "abcdefghijklmnopqrstuvwx")
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    var response = _tick_and_read(server, handler, client)
    assert_equal(_status_of(response), 200)
    assert_equal(handler.calls, 1)
    client.write_all(
        String("GET /next HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(1),
    )
    var next = _tick_and_read(server, handler, client)
    assert_equal(_status_of(next), 200)
    assert_equal(handler.calls, 2)
    client.close()


def test_consumed_queue_restores_socket_read_interest() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabcd"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var buffer = Array[Byte, 4](fill=0)
    assert_equal(
        handler.endpoints.value().receiver.receive(
            Span(buffer), Timeout.nanoseconds(0)
        ),
        4,
    )
    for _ in range(3):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_true(server._reactor._slots[server._conns[0].token.slot].readable)
    client.write_all(String("efgh").as_bytes(), Timeout.seconds(1))
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), "efgh")
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_partial_consumption_resumes_reads_without_budget_refund() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabcd"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    for _ in range(3):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_false(server._conns[0].wants_read())
    var before = server._budget.remaining()
    var prefix = Array[Byte, 2](fill=0)
    assert_equal(
        handler.endpoints.value().receiver.receive(
            Span(prefix), Timeout.nanoseconds(0)
        ),
        2,
    )
    assert_equal(server._budget.remaining(), before)
    for _ in range(3):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_true(server._conns[0].wants_read())
    client.write_all(String("efgh").as_bytes(), Timeout.seconds(1))
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), "cdefgh")
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_early_detached_response_advertises_connection_close() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    handler.endpoints.value().sender.respond(
        200, Headers(), List[Byte]("early".as_bytes())
    )
    var wire = _tick_and_read(server, handler, client)
    assert_true(
        String(from_utf8_lossy=Span(wire)).find("Connection: close") >= 0
    )
    assert_equal(server.active_connections(), 0)
    client.close()


def test_early_detached_stream_advertises_connection_close() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    handler.endpoints.value().sender.start(200, Headers())
    assert_true(handler.endpoints.value().sender.send("early".as_bytes()))
    handler.endpoints.value().sender.finish()
    var wire = _tick_and_read(server, handler, client)
    assert_true(
        String(from_utf8_lossy=Span(wire)).find("Connection: close") >= 0
    )
    assert_equal(server.active_connections(), 0)
    client.close()


def test_shared_budget_refund_retries_paused_input() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabcdefgh"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var buffer = Array[Byte, 4](fill=0)
    assert_equal(
        handler.endpoints.value().receiver.receive(
            Span(buffer), Timeout.nanoseconds(0)
        ),
        4,
    )
    var held = server._budget.remaining()
    assert_true(server._budget.try_reserve(held))
    for _ in range(3):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_false(server._conns[0].wants_read())
    server._budget.release(held)
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), "efgh")
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_socket_reads_leave_capacity_for_decoded_body() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 512\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var held = server._budget.remaining() - 512
    assert_true(server._budget.try_reserve(held))
    var wire = String("a") * 512
    client.write_all(wire.as_bytes(), Timeout.seconds(1))
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), wire)
    server._budget.release(held)
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_chunk_framing_reads_leave_capacity_for_decoded_body() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var held = server._budget.remaining() - 512
    assert_true(server._budget.try_reserve(held))
    var wire = String("a") * 512
    client.write_all(
        (String("200\r\n") + wire + "\r\n0\r\n\r\n").as_bytes(),
        Timeout.seconds(1),
    )
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), wire)
    server._budget.release(held)
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_one_budget_byte_pauses_input_until_refund() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 512\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var held = server._budget.remaining() - 1
    assert_true(server._budget.try_reserve(held))
    var wire = String("a") * 512
    client.write_all(wire.as_bytes(), Timeout.seconds(1))
    for _ in range(3):
        _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_false(server._conns[0].wants_read())
    server._budget.release(held)
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), wire)
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_long_chunk_extension_progresses_with_limited_budget() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4096
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var held = server._budget.remaining() - 512
    assert_true(server._budget.try_reserve(held))
    var wire = String("a") * 512
    client.write_all(
        (
            String("200;name=")
            + (String("x") * 400)
            + "\r\n"
            + wire
            + "\r\n0\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), wire)
    server._budget.release(held)
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_trailer_publication_retries_after_consumed_wire_refund() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 8
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var expected = Headers()
    expected.add(String(from_utf8_lossy=String("x-end").as_bytes()), "done")
    var held = server._budget.remaining() - expected._known_capacity() - 4
    assert_true(server._budget.try_reserve(held))
    client.write_all(
        String("0\r\nx-end: done\r\n\r\n").as_bytes(), Timeout.seconds(1)
    )
    var body = _receive_body(server, handler)
    assert_equal(len(body), 0)
    var trailers = handler.endpoints.value().receiver.trailers()
    assert_equal(trailers.get_first("x-end").value(), "done")
    server._budget.release(held)
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_chunked_body_larger_than_queue_with_trailers() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    client.write_all(
        String("10\r\nabcdefghijklmnop\r\n0\r\nx-end: yes\r\n\r\n").as_bytes(),
        Timeout.seconds(1),
    )
    var body = _receive_body(server, handler)
    assert_equal(String(from_utf8_lossy=Span(body)), "abcdefghijklmnop")
    var trailers = handler.endpoints.value().receiver.trailers()
    assert_equal(trailers.get_first("x-end").value(), "yes")
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_discard_drains_before_reusing_connection() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 4
    var server = Server(config^)
    var client = _connect(server)
    var handler = _DiscardHandler()
    client.write_all(
        String(
            "POST /first HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    assert_equal(handler.calls, 1)
    client.write_all(
        String("abcdefghijklGET /next HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(1),
    )
    var response = _tick_and_read(server, handler, client)
    assert_equal(_status_of(response), 200)
    assert_equal(
        String(from_utf8_lossy=Span(response)[_header_end(response) :]), "/next"
    )
    assert_equal(handler.calls, 2)
    client.close()


def test_unread_body_forces_connection_close() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    var client = _connect(server)
    var handler = _IgnoreBodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    var response = _tick_and_read(server, handler, client)
    assert_equal(_status_of(response), 200)
    assert_true(
        String(from_utf8_lossy=Span(response)).find("Connection: close") >= 0
    )
    assert_equal(server.active_connections(), 0)
    client.close()


def test_default_buffered_mode_still_rejects_large_length() raises:
    var config = ServerConfig.default()
    assert_false(config.enable_request_body_streaming)
    config.max_body_bytes = 4
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 413)
    assert_equal(handler.calls, 0)
    client.close()


def _assert_cancelled(mut handler: _BodyHandler) raises:
    var buffer = Array[Byte, 1](fill=0)
    var cancelled = False
    try:
        _ = handler.endpoints.value().receiver.receive(
            Span(buffer), Timeout.nanoseconds(0)
        )
    except error:
        cancelled = error.kind == NetErrorKind.cancelled()
    assert_true(cancelled)
    assert_true(handler.endpoints.value().sender.is_cancelled())


def test_premature_eof_cancels_both_endpoints() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nab"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    client.shutdown(False, True)
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(1))
        if server.active_connections() == 0:
            break
    assert_equal(server.active_connections(), 0)
    _assert_cancelled(handler)
    handler.endpoints = None
    assert_equal(server._budget.used(), 0)
    client.close()


def test_body_deadline_cancels_receiver_and_sender() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.body_deadline = Timeout.milliseconds(5)
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    sleep(0.01)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 0)
    _assert_cancelled(handler)
    handler.endpoints = None
    assert_equal(server._budget.used(), 0)
    client.close()


def test_shutdown_grace_cancels_incomplete_input() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.shutdown_grace = Timeout.milliseconds(5)
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    server.request_shutdown()
    _ = server.tick(handler, Timeout.nanoseconds(0))
    sleep(0.01)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 0)
    _assert_cancelled(handler)
    client.close()


def test_discarded_input_uses_body_deadline_after_response_finishes() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.body_deadline = Timeout.milliseconds(100)
    config.idle_timeout = Timeout.milliseconds(1)
    var server = Server(config^)
    var client = _connect(server)
    var handler = _DiscardHandler()
    client.write_all(
        String(
            "POST /first HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    sleep(0.01)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 1)
    client.write_all(
        String("bodyGET /next HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    assert_equal(handler.calls, 2)
    client.close()


def _discarded_body_completion_restores_deadline(partial_header: Bool) raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.body_deadline = Timeout.seconds(1)
    config.idle_timeout = Timeout.milliseconds(
        5
    ) if not partial_header else Timeout.seconds(1)
    config.header_deadline = Timeout.milliseconds(5)
    var server = Server(config^)
    var client = _connect(server)
    var handler = _DiscardHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    var tail = String("4\r\nbody\r\n0\r\n\r\n")
    if partial_header:
        tail += "GET /next HTTP/1.1\r\nHost:"
    client.write_all(tail.as_bytes(), Timeout.seconds(1))
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(1))
        if len(server._request_body_conns) == 0:
            break
    assert_equal(len(server._request_body_conns), 0)
    sleep(0.01)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 0)
    client.close()


def test_discarded_body_completion_restores_idle_deadline() raises:
    _discarded_body_completion_restores_deadline(False)


def test_discarded_body_completion_restores_header_deadline() raises:
    _discarded_body_completion_restores_deadline(True)


def test_discarded_incomplete_body_gets_shutdown_grace() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.shutdown_grace = Timeout.milliseconds(100)
    config.body_deadline = Timeout.seconds(1)
    var server = Server(config^)
    var client = _connect(server)
    var handler = _DiscardHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    server.request_shutdown()
    _ = server.tick(handler, Timeout.nanoseconds(0))
    sleep(0.02)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 1)
    client.write_all(String("body").as_bytes(), Timeout.seconds(1))
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(1))
        if len(server._request_body_conns) == 0:
            break
    assert_equal(len(server._request_body_conns), 0)
    sleep(0.11)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_equal(server.active_connections(), 0)
    client.close()


def test_complete_unread_body_does_not_pin_idle_connection_budget() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    var client = _connect(server)
    var handler = _IgnoreBodyHandler()
    _ = server.tick(handler, Timeout.milliseconds(1))
    var baseline = server._budget.used()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nbody"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    assert_equal(server.active_connections(), 1)
    assert_false(server._conns[0].body_pipe)
    assert_equal(server._budget.used(), baseline)
    client.close()


def test_streaming_progress_renews_body_deadline() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.body_deadline = Timeout.milliseconds(30)
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var buffer = Array[Byte, 1](fill=0)
    for byte in String("body").as_bytes():
        var one = Array[Byte, 1](fill=byte)
        client.write_all(Span(one), Timeout.seconds(1))
        var received = False
        for _ in range(100):
            _ = server.tick(handler, Timeout.milliseconds(1))
            try:
                var count = handler.endpoints.value().receiver.receive(
                    Span(buffer), Timeout.nanoseconds(0)
                )
                received = count == 1
                break
            except error:
                if error.kind != NetErrorKind.timeout():
                    raise error^
        assert_true(received)
        sleep(0.015)
        _ = server.tick(handler, Timeout.nanoseconds(0))
        assert_equal(server.active_connections(), 1)
    assert_true(handler.endpoints.value().receiver.is_eof())
    var body = List[Byte]()
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


def test_expect_continue_dispatches_before_body_arrives() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyHandler()
    client.write_all(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nExpect:"
            " 100-continue\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(1),
    )
    _wait_for_handler(server, handler)
    var buffer = Array[Byte, 128](fill=0)
    var interim = List[Byte]()
    for _ in range(100):
        _ = server.tick(handler, Timeout.milliseconds(1))
        try:
            var count = client.try_read(Span(buffer))
            interim.extend(Span(buffer)[:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
        if len(interim) == 25:
            break
    assert_equal(
        String(from_utf8_lossy=Span(interim)),
        "HTTP/1.1 100 Continue\r\n\r\n",
    )
    client.write_all(String("body").as_bytes(), Timeout.seconds(1))
    var body = _receive_body(server, handler)
    handler.endpoints.value().sender.respond(200, Headers(), body^)
    assert_equal(_status_of(_tick_and_read(server, handler, client)), 200)
    client.close()


@fieldwise_init
struct _BodyWorkerContext(Movable):
    var endpoints: RequestBodyEndpoints
    var count: Int
    var done: Bool


def _body_worker(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_BodyWorkerContext]()
    var buffer = Array[Byte, 17](fill=0)
    try:
        while True:
            var count = context[].endpoints.receiver.receive(
                Span(buffer), Timeout.seconds(1)
            )
            if count == 0:
                break
            context[].count += count
        var body = List[Byte]()
        body.extend(String(context[].count).as_bytes())
        context[].endpoints.sender.respond(200, Headers(), body^)
        context[].done = True
    except:
        context[].done = False
    return arg


struct _BodyWorkerHandler(Handler):
    var context: Optional[OwnedPointer[_BodyWorkerContext]]
    var thread: UInt64

    def __init__(out self):
        self.context = None
        self.thread = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.context = OwnedPointer(
            _BodyWorkerContext(writer.detach_with_body(req), 0, False)
        )
        var result = external_call["pthread_create", c_int](
            Pointer(to=self.thread),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _body_worker,
            Pointer(to=self.context.value()[]).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(result), 0)


def test_detached_worker_consumes_large_body_with_bounded_queue() raises:
    var config = ServerConfig.default()
    config.enable_request_body_streaming = True
    config.max_body_bytes = 32
    var server = Server(config^)
    var client = _connect(server)
    var handler = _BodyWorkerHandler()
    var request = List[Byte]()
    request.extend(
        String(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 16384\r\n\r\n"
        ).as_bytes()
    )
    request.extend(List[Byte](length=16384, fill=97))
    client.write_all(Span(request), Timeout.seconds(1))
    var response = _tick_and_read(server, handler, client, max_ticks=5000)
    _join_thread(handler.thread)
    assert_true(handler.context.value()[].done)
    assert_equal(handler.context.value()[].count, 16384)
    assert_equal(_status_of(response), 200)
    assert_equal(
        String(from_utf8_lossy=Span(response)[_header_end(response) :]), "16384"
    )
    assert_equal(server._request_body_conns.__len__(), 0)
    client.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
