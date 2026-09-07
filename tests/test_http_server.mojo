from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import (
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
)


struct _HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.method == "GET" and req.path == "/hello":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _EchoHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/echo":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/octet-stream")
            )
            for i in range(len(req.body)):
                writer.body.append(req.body[i])
        elif req.path == "/hello":
            writer.set_status(200)
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _JsonHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/json":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/json")
            )
            for i in range(1024):
                writer.body.append(Byte(ord("a") + (i % 26)))
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _BigJsonHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/json":
            writer.set_status(200)
            for i in range(262144):
                writer.body.append(Byte(ord("j") + (i % 8)))
        elif req.path == "/hello":
            writer.set_status(200)
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")


struct _BoomHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        raise Error("boom")


struct _HugeHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(200)
        writer.write_string(String("a") * (1024 * 1024 + 1))


struct _DirectHugeHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        # Bypasses write()/write_string() on purpose: the server must
        # still enforce the cap after the handler returns.
        writer.set_status(200)
        for i in range(1024 * 1024 + 1):
            writer.body.append(Byte(ord("z")))


struct _TwoHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/one":
            writer.set_status(200)
            writer.write_string("ONE")
        elif req.path == "/two":
            writer.set_status(200)
            writer.write_string("TWO")
        else:
            writer.set_status(404)
            writer.write_string("missing")


def _bytes_of(data: StringSlice) -> List[Byte]:
    var out = List[Byte]()
    var bytes = data.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _tick_n[H: Handler](mut server: Server, mut handler: H, n: Int) raises:
    for _ in range(n):
        _ = server.tick(handler, Timeout.nanoseconds(0))


def _header_end(buf: List[Byte]) -> Int:
    var i = 0
    while i + 3 < len(buf):
        if (
            buf[i] == Byte(ord("\r"))
            and buf[i + 1] == Byte(ord("\n"))
            and buf[i + 2] == Byte(ord("\r"))
            and buf[i + 3] == Byte(ord("\n"))
        ):
            return i + 4
        i += 1
    return -1


def _status_of(buf: List[Byte]) -> Int:
    if len(buf) < 12:
        return -1
    var code = 0
    for i in range(9, 12):
        var byte = buf[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return -1
        code = code * 10 + Int(byte - Byte(ord("0")))
    return code


def _content_length_of(buf: List[Byte]) -> Int:
    var end = _header_end(buf)
    if end < 0:
        return -1
    var head = String(from_utf8_lossy=Span(buf)[0:end]).lower()
    var needle = String("content-length:")
    var at = head.find(needle)
    if at < 0:
        return -1
    var value_start = at + len(needle.as_bytes())
    var value_end = value_start
    var head_bytes = head.as_bytes()
    while value_end < len(head_bytes) and (
        head_bytes[value_end] == Byte(ord(" "))
        or head_bytes[value_end] == Byte(ord("\t"))
    ):
        value_end += 1
    var digits_start = value_end
    while value_end < len(head_bytes) and (
        head_bytes[value_end] >= Byte(ord("0"))
        and head_bytes[value_end] <= Byte(ord("9"))
    ):
        value_end += 1
    if value_end == digits_start:
        return -1
    var value = 0
    for i in range(digits_start, value_end):
        value = value * 10 + Int(head_bytes[i] - Byte(ord("0")))
    return value


def _response_complete(buf: List[Byte]) -> Bool:
    var end = _header_end(buf)
    if end < 0:
        return False
    var length = _content_length_of(buf)
    if length < 0:
        return True
    return len(buf) >= end + length


def _exchange[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    client: TCPConn,
    request: String,
    max_ticks: Int = 300,
) raises -> List[Byte]:
    client.write_all(request.as_bytes(), Timeout.seconds(2))
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(max_ticks):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    return out^


def _assert_body(wire: List[Byte], expected: String) raises:
    var end = _header_end(wire)
    assert_true(end >= 0)
    var length = _content_length_of(wire)
    assert_equal(length, expected.byte_length())
    assert_equal(len(wire), end + length)
    var expected_bytes = expected.as_bytes()
    for i in range(len(expected_bytes)):
        assert_equal(wire[end + i], expected_bytes[i])


def test_hello_keep_alive_two_requests() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var first = _exchange(
        server,
        handler,
        client,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(first), 200)
    _assert_body(first, "hello")
    assert_equal(server.active_connections(), 1)
    var second = _exchange(
        server,
        handler,
        client,
        "GET /missing HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(second), 404)
    _assert_body(second, "missing")
    assert_equal(server.active_connections(), 1)
    client.close()
    _tick_n(server, handler, 50)
    assert_equal(server.active_connections(), 0)


def test_pipeline_order_preserved() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _TwoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost:"
            " x\r\nConnection: close\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
            continue
        if len(out) > 0 and _header_end(out) > 0:
            # Two small responses expected; stop once both arrived.
            var text = String(from_utf8_lossy=Span(out))
            if text.find("TWO") >= 0:
                break
    var text = String(from_utf8_lossy=Span(out))
    var one_at = text.find("ONE")
    var two_at = text.find("TWO")
    assert_true(one_at >= 0)
    assert_true(two_at >= 0)
    assert_true(one_at < two_at)
    client.close()


def test_pipelined_chain_completes_without_extra_waits() raises:
    # Six pipelined requests must all complete well before six ticks:
    # chaining parses each buffered request in the same drive instead
    # of stalling one poll wait per request. The bound is deliberately
    # loose (chaining needs two ticks: accept, then everything) so no
    # wall-clock timing is asserted, only tick counts.
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _TwoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var batch = String("")
    for _ in range(5):
        batch += String("GET /one HTTP/1.1\r\nHost: x\r\n\r\n")
    batch += String("GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    client.write_all(batch.as_bytes(), Timeout.seconds(2))
    # Drain until empty after each tick: loopback delivery lags the
    # server's kernel handoff by microseconds, and a single try_read
    # may catch only part of what was sent.
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(4):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        for _ in range(50):
            try:
                var n = client.try_read(Span(tmp))
                if n == 0:
                    break
                for i in range(n):
                    out.append(tmp[i])
            except e:
                _ = e
                break
    var text = String(from_utf8_lossy=Span(out))
    assert_equal(server.active_connections(), 0)
    var ones = 0
    var rest = text
    while True:
        var at = rest.find("ONE")
        if at < 0:
            break
        ones += 1
        var rest_bytes = rest.as_bytes()
        var tail = String(from_utf8_lossy=rest_bytes[at + 3 : len(rest_bytes)])
        rest = tail^
    assert_equal(ones, 5)
    assert_true(text.find("TWO") >= 0)
    client.close()


def test_100_continue_flow() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect:"
            " 100-continue\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    var interim = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    for _ in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                interim.append(tmp[i])
            if _header_end(interim) >= 0:
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(interim), 100)
    client.write_all(String("abc").as_bytes(), Timeout.seconds(2))
    var final = List[Byte]()
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                final.append(tmp[i])
            if _response_complete(final):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(final), 200)
    _assert_body(final, "abc")
    client.close()


def test_unknown_expectation_is_417() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        (
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect:"
            " 418-teapot\r\n\r\nabc"
        ),
    )
    assert_equal(_status_of(out), 417)
    client.close()


def test_partial_send_byte_at_a_time() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var raw = String(
        "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    )
    var raw_bytes = raw.as_bytes()
    var out = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    for i in range(len(raw_bytes)):
        var one = Array[Byte, 1](fill=0)
        one[0] = raw_bytes[i]
        client.write_all(Span(one), Timeout.seconds(2))
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            for k in range(n):
                out.append(tmp[k])
        except e:
            _ = e
            continue
    for _ in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for k in range(n):
                out.append(tmp[k])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    client.close()


def test_eof_after_complete_responds_then_closes() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    client.shutdown(False, True)
    var out = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    var saw_eof = False
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                saw_eof = True
                break
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    _tick_n(server, handler, 50)
    assert_equal(server.active_connections(), 0)
    assert_true(saw_eof)
    client.close()


def test_eof_mid_request_closes_without_success() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nabc"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    client.shutdown(False, True)
    _tick_n(server, handler, 100)
    assert_equal(server.active_connections(), 0)
    var tmp = Array[Byte, 4096](fill=0)
    var got_bytes = False
    for _ in range(50):
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            got_bytes = True
        except e:
            _ = e
            break
    assert_false(got_bytes)
    client.close()


def test_slow_reader_does_not_block_fast_client() raises:
    var config = ServerConfig.default()
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _BigJsonHandler()
    var slow = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    # Shrink the slow client's receive window so the 256 KiB response
    # cannot fit in flight: the server must park the remainder and keep
    # serving others instead of blocking the loop.
    slow.set_read_buffer(4096)
    slow.write_all(
        String("GET /json HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    var fast = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var fast_done = False
    var fast_bytes = List[Byte]()
    for t in range(200):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var probe = Array[Byte, 4096](fill=0)
            var n = fast.try_read(Span(probe))
            for i in range(n):
                fast_bytes.append(probe[i])
            if _response_complete(fast_bytes):
                fast_done = True
                break
        except e:
            _ = e
        if t == 5:
            fast.write_all(
                String("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
                Timeout.seconds(2),
            )
    assert_true(fast_done)
    assert_equal(_status_of(fast_bytes), 200)
    # Drain the slow response to completion and verify integrity.
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(2000):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = slow.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    assert_equal(_content_length_of(out), 262144)
    assert_equal(len(out), _header_end(out) + 262144)
    slow.close()
    fast.close()


def test_malformed_request_is_400() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GARBAGE\r\n\r\n",
    )
    assert_equal(_status_of(out), 400)
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_handler_error_is_500_and_loop_continues() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var boom = _BoomHandler()
    var bad = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var out = _exchange(
        server,
        boom,
        bad,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 500)
    var text = String(from_utf8_lossy=Span(out))
    assert_true(text.find("boom") < 0)
    bad.close()
    _tick_n(server, boom, 20)
    assert_equal(server.active_connections(), 0)
    var hello = _HelloHandler()
    var good = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var second = _exchange(
        server,
        hello,
        good,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(second), 200)
    good.close()


def test_response_over_limit_is_500() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HugeHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET /big HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 500)
    client.close()


def test_direct_body_append_over_limit_is_500() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _DirectHugeHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET /big HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 500)
    client.close()


def test_admitted_body_reservation_blocks_second_client() raises:
    # The first client's missing body bytes are reserved at admission,
    # so a second client promising the same no longer fits and gets
    # 503 while the first still completes.
    var config = ServerConfig.default()
    config.total_buffer_budget = 8192
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var first = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var second = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    first.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6000\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    _tick_n(server, handler, 20)
    second.write_all(
        String(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6000\r\n\r\n"
        ).as_bytes(),
        Timeout.seconds(2),
    )
    var payload = String("b") * 6000
    first.write_all(payload.as_bytes(), Timeout.seconds(2))
    var first_out = List[Byte]()
    var second_out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(400):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = first.try_read(Span(tmp))
            for i in range(n):
                first_out.append(tmp[i])
        except e:
            _ = e
        try:
            var n = second.try_read(Span(tmp))
            for i in range(n):
                second_out.append(tmp[i])
        except e:
            _ = e
        if _response_complete(first_out) and _response_complete(second_out):
            break
    assert_equal(_status_of(first_out), 200)
    assert_equal(_content_length_of(first_out), 6000)
    assert_equal(_status_of(second_out), 503)
    first.close()
    second.close()


def test_small_budget_rejects_with_503() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 2048
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\n",
    )
    assert_equal(_status_of(out), 503)
    client.close()


def test_connection_close_roundtrip() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    )
    assert_equal(_status_of(out), 200)
    var text = String(from_utf8_lossy=Span(out)).lower()
    assert_true(text.find("connection: close") >= 0)
    _tick_n(server, handler, 50)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_head_omits_body_bytes() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        "HEAD /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 404)
    # The hello handler only answers GET; HEAD falls to 404 with an
    # empty drained body on the wire.
    assert_equal(_content_length_of(out), 7)
    assert_equal(len(out), _header_end(out))
    var hello_only = _exchange(
        server,
        handler,
        client,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(hello_only), 200)
    client.close()


def test_chunked_echo_roundtrip() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var out = _exchange(
        server,
        handler,
        client,
        (
            "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding:"
            " chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        ),
    )
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    client.close()


def test_binary_body_roundtrip() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _EchoHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    var head = _bytes_of(
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n\r\n"
    )
    head.append(Byte(0))
    head.append(Byte(13))
    head.append(Byte(10))
    head.append(Byte(255))
    head.append(Byte(0))
    head.append(Byte(65))
    client.write_all(Span(head), Timeout.seconds(2))
    var out = List[Byte]()
    var tmp = Array[Byte, 65536](fill=0)
    for _ in range(300):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out):
                break
        except e:
            _ = e
            continue
    assert_equal(_status_of(out), 200)
    var end = _header_end(out)
    assert_equal(_content_length_of(out), 6)
    assert_equal(out[end + 0], Byte(0))
    assert_equal(out[end + 1], Byte(13))
    assert_equal(out[end + 2], Byte(10))
    assert_equal(out[end + 3], Byte(255))
    assert_equal(out[end + 5], Byte(65))
    client.close()


def test_max_connections_pauses_listener() raises:
    var config = ServerConfig.default()
    config.max_connections = 1
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var first = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 1)
    var second = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    _tick_n(server, handler, 20)
    # The listener is paused: the second client stays in the backlog.
    assert_equal(server.active_connections(), 1)
    var out = _exchange(
        server,
        handler,
        first,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(out), 200)
    first.close()
    for _ in range(100):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if server.active_connections() == 0:
            break
    for _ in range(100):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if server.active_connections() == 1:
            break
    assert_equal(server.active_connections(), 1)
    var accepted = _exchange(
        server,
        handler,
        second,
        "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    )
    assert_equal(_status_of(accepted), 200)
    second.close()


def test_slow_header_times_out() raises:
    var config = ServerConfig.default()
    config.header_deadline = Timeout.milliseconds(200)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        String("GET /slow HTTP/1.1\r\nHost: x\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 1)
    sleep(0.4)
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_idle_connection_times_out() raises:
    var config = ServerConfig.default()
    config.idle_timeout = Timeout.milliseconds(200)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 1)
    sleep(0.4)
    _tick_n(server, handler, 10)
    assert_equal(server.active_connections(), 0)
    client.close()


def test_shutdown_drains_in_flight_and_exits() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _HelloHandler()
    var idle = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    var busy = dial_tcp(String("127.0.0.1:") + String(port), Timeout.seconds(2))
    _tick_n(server, handler, 20)
    assert_equal(server.active_connections(), 2)
    busy.write_all(
        String("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
        Timeout.seconds(2),
    )
    server.request_shutdown()
    server.request_shutdown()
    var out = List[Byte]()
    var tmp = Array[Byte, 4096](fill=0)
    for _ in range(2000):
        var alive = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = busy.try_read(Span(tmp))
            for i in range(n):
                out.append(tmp[i])
        except e:
            _ = e
        if not alive:
            break
    assert_equal(_status_of(out), 200)
    _assert_body(out, "hello")
    assert_equal(server.active_connections(), 0)
    assert_true(server.control.is_shutdown_requested())
    server.request_shutdown()
    idle.close()
    busy.close()


def test_local_address_reports_bound_port() raises:
    var bare = Server(ServerConfig.default())
    var missing = False
    try:
        _ = bare.local_address()
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_state())
        missing = True
    assert_true(missing)
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    assert_true(server.local_address().port != 0)


def test_serve_with_control_uses_caller_handle() raises:
    var server = Server(ServerConfig.default())
    var listener = listen_tcp("127.0.0.1:0")
    var handler = _HelloHandler()
    var control = ServerControl()
    control.request_shutdown()
    server.serve_with_control(listener^, handler, control)
    assert_true(control.is_shutdown_requested())
    assert_equal(server.active_connections(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
