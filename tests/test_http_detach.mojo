from std.ffi import c_int, c_size_t, c_ulong, external_call
from std.sys import size_of
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net._sys.common import EINTR
from net.error import NetErrorKind
from net.http._buffer import SharedBufferBudget
from net.http import (
    Handler,
    Headers,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.http._detach import (
    DetachMessage,
    MSG_KIND_ABORT,
    MSG_KIND_CHUNK,
    MSG_KIND_FINISH,
    MSG_KIND_RESPOND,
    MSG_KIND_START,
    _create_detach_state,
    _DetachedBatch,
    _take_batch,
    _release_detach_state,
    _SharedDetachState,
)
from tests.support import _join_thread
from tests.test_http_server import _drain_head_error_to_eof


def _move_sender(var sender: ResponseSender) -> ResponseSender:
    return sender^


def test_state_charge_stays_until_last_reference() raises:
    comptime state_size = size_of[_SharedDetachState]()
    var exact = SharedBufferBudget(state_size + 5)
    assert_true(exact.try_reserve(5))
    var writer = ResponseWriter(32)
    writer._set_body_budget(exact.copy())
    var sender = writer.detach()
    var charged = exact.used()
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    var moved = _move_sender(sender^)
    var held = exact.used()
    _ = moved^
    assert_equal(exact.used(), 5)
    assert_equal(charged, state_size + 5)
    assert_equal(held, state_size + 5)


def test_state_admission_preserves_foreign_reservations_and_writer_failure() raises:
    comptime state_size = size_of[_SharedDetachState]()
    var denied_budget = SharedBufferBudget(state_size + 4)
    assert_true(denied_budget.try_reserve(5))
    var denied_writer = ResponseWriter(32)
    denied_writer._set_body_budget(denied_budget.copy())
    var rejected = False
    try:
        _ = denied_writer.detach()
    except e:
        rejected = e.kind == NetErrorKind.invalid_argument()
    if denied_writer.is_detached():
        _release_detach_state(
            denied_writer._detach_state_addr, from_sender=False
        )
    assert_true(rejected)
    assert_false(denied_writer.is_detached())
    assert_equal(denied_writer._detach_state_addr, 0)
    assert_equal(denied_budget.used(), 5)
    denied_budget.release(5)
    var retried = denied_writer.detach()
    _release_detach_state(denied_writer._detach_state_addr, from_sender=False)
    assert_equal(denied_budget.used(), state_size)
    _ = retried^
    assert_equal(denied_budget.used(), 0)


@fieldwise_init
struct _StateAdmissionContext(Movable):
    var budget: SharedBufferBudget
    var addr: Int
    var rejected: Bool
    var coherent: Bool
    var observed: Int


def _state_admission_thread(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_StateAdmissionContext]()
    var writer = ResponseWriter(0)
    writer._set_body_budget(context[].budget.copy())
    try:
        var sender = writer.detach()
        context[].addr = sender._take()
    except e:
        context[].rejected = e.kind == NetErrorKind.invalid_argument()
        context[].coherent = (
            not writer.is_detached() and writer._detach_state_addr == 0
        )
    context[].observed = context[].budget.used()
    return arg


def test_pthread_state_admission_has_one_joint_winner() raises:
    comptime state_size = size_of[_SharedDetachState]()
    var budget = SharedBufferBudget(state_size + 5)
    assert_true(budget.try_reserve(5))
    var contexts: Array[_StateAdmissionContext, 2] = [
        _StateAdmissionContext(budget.copy(), 0, False, False, 0),
        _StateAdmissionContext(budget.copy(), 0, False, False, 0),
    ]
    var handles = Array[UInt64, 2](fill=0)
    for i in range(2):
        var rc = external_call["pthread_create", c_int](
            Pointer(to=handles[i]),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _state_admission_thread,
            Pointer(to=contexts[i]).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(rc), 0)
    for i in range(2):
        _join_thread(handles[i])
    var successes = 0
    var rejections = 0
    var coherent = True
    var held = budget.used()
    for i in range(2):
        assert_true(contexts[i].observed <= budget.total())
        if contexts[i].addr != 0:
            successes += 1
            var sender = ResponseSender(contexts[i].addr)
            _release_detach_state(contexts[i].addr, from_sender=False)
            _ = sender^
        else:
            rejections += Int(contexts[i].rejected)
            coherent = coherent and contexts[i].coherent
    assert_equal(budget.used(), 5)
    assert_equal(successes, 1)
    assert_equal(rejections, 1)
    assert_true(coherent)
    assert_equal(held, state_size + 5)


def test_response_sender_is_movable() raises:
    var writer = ResponseWriter(1024)
    var sender = writer.detach()
    assert_true(writer.is_detached())
    assert_true(sender.is_active())

    var moved = _move_sender(sender^)
    assert_true(moved.is_active())
    assert_false(moved.is_cancelled())
    _release_detach_state(writer._detach_state_addr, from_sender=False)


def test_response_writer_detach_once() raises:
    var writer = ResponseWriter(1024)
    _ = writer.detach()
    assert_true(writer.is_detached())

    # Second detach must fail with invalid_state.
    var failed = False
    try:
        _ = writer.detach()
    except e:
        if e.kind == NetErrorKind.invalid_state():
            failed = True
    assert_true(failed)
    _release_detach_state(writer._detach_state_addr, from_sender=False)


@fieldwise_init
struct _ThreadProbeContext:
    var sender_addr: Int
    var status_to_send: Int
    var executed: Bool


def _thread_sender_entry(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx_ptr = arg.unsafe_bitcast[_ThreadProbeContext]()
    var sender = ResponseSender(ctx_ptr[].sender_addr)
    try:
        var h = Headers()
        var body = List[Byte]()
        body.append(Byte(ord("o")))
        body.append(Byte(ord("k")))
        sender.respond(ctx_ptr[].status_to_send, h^, body^)
        ctx_ptr[].executed = True
    except:
        ctx_ptr[].executed = False
    return arg


def test_response_sender_callable_from_pthread() raises:
    # Compile probe & runtime verification that ResponseSender can be transferred
    # to and invoked from an external pthread created outside the Mojo runtime.
    var state_addr = _create_detach_state(slot=0, generation=1)
    assert_true(state_addr != 0)

    var ctx = _ThreadProbeContext(
        sender_addr=state_addr,
        status_to_send=201,
        executed=False,
    )
    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _thread_sender_entry,
        Pointer(to=ctx).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    _join_thread(handle)
    assert_true(ctx.executed)

    # Server side inspects the message queue
    var s_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    ).unsafe_bitcast[_SharedDetachState]()
    s_ptr[].mutex.lock()
    assert_equal(len(s_ptr[].messages), 1)
    assert_equal(s_ptr[].messages[0].kind, MSG_KIND_RESPOND)
    assert_equal(s_ptr[].messages[0].status, 201)
    assert_equal(len(s_ptr[].messages[0].body), 2)
    assert_equal(s_ptr[].messages[0].body[0], Byte(ord("o")))
    assert_equal(s_ptr[].messages[0].body[1], Byte(ord("k")))
    s_ptr[].mutex.unlock()

    # Server releases its reference to complete deallocation
    _release_detach_state(state_addr, from_sender=False)


def test_detach_state_lifecycle_and_cleanup() raises:
    var state_addr = _create_detach_state(slot=1, generation=42)
    assert_true(state_addr != 0)

    var sender = ResponseSender(state_addr)
    assert_false(sender.is_cancelled())

    # Cancel connection from server side
    var s_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    ).unsafe_bitcast[_SharedDetachState]()
    s_ptr[].mutex.lock()
    s_ptr[].cancelled = True
    s_ptr[].mutex.unlock()

    # Sender must observe cancellation
    assert_true(sender.is_cancelled())
    var respond_failed = False
    var h = Headers()
    var b = List[Byte]()
    try:
        sender.respond(200, h^, b^)
    except e:
        if e.kind == NetErrorKind.closed():
            respond_failed = True
    assert_true(respond_failed)

    # Releasing both sides must not leak or crash
    # Server side releases:
    _release_detach_state(state_addr, from_sender=False)
    # sender deinit releases other ref upon exit


def test_sender_drop_without_respond_records_abort_without_array_growth() raises:
    var state_addr = _create_detach_state(slot=2, generation=10)
    assert_true(state_addr != 0)

    # Create and immediately drop sender without calling respond()
    var s_ptr = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    ).unsafe_bitcast[_SharedDetachState]()
    s_ptr[].mutex.lock()
    assert_equal(len(s_ptr[].messages), 0)
    s_ptr[].mutex.unlock()

    var sender = ResponseSender(state_addr)
    # Sender is dropped at block exit:
    _ = sender._take()  # manually simulate dropping with cleanup
    _release_detach_state(state_addr, from_sender=True)

    s_ptr[].mutex.lock()
    assert_equal(len(s_ptr[].messages), 0)
    assert_equal(s_ptr[].messages.capacity(), 0)
    assert_equal(s_ptr[].terminal_kind, MSG_KIND_ABORT)
    s_ptr[].mutex.unlock()

    # Server side releases remaining ref
    _release_detach_state(state_addr, from_sender=False)


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


def _body_of(buf: List[Byte]) -> String:
    var end = _header_end(buf)
    if end < 0:
        return ""
    var len_val = _content_length_of(buf)
    if len_val < 0 or end + len_val > len(buf):
        return String(from_utf8_lossy=Span(buf)[end:])
    return String(from_utf8_lossy=Span(buf)[end : end + len_val])


def _response_complete(buf: List[Byte], expect_body: Bool = True) -> Bool:
    var end = _header_end(buf)
    if end < 0:
        return False
    if not expect_body:
        return True
    var length = _content_length_of(buf)
    if length < 0:
        return True
    return len(buf) >= end + length


def _split_responses(buf: List[Byte]) -> List[List[Byte]]:
    var res = List[List[Byte]]()
    var offset = 0
    while offset < len(buf):
        var sub = List[Byte]()
        for i in range(offset, len(buf)):
            sub.append(buf[i])
        var end = _header_end(sub)
        if end < 0:
            break
        var length = _content_length_of(sub)
        if length < 0:
            res.append(sub^)
            break
        var total = end + length
        if len(sub) < total:
            break
        var single = List[Byte]()
        for i in range(total):
            single.append(sub[i])
        res.append(single^)
        offset += total
    return res^


def _tick_until_detached[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    box: Pointer[Int, MutUntrackedOrigin],
    max_ticks: Int = 20,
) raises:
    for _ in range(max_ticks):
        if box[] != 0:
            break
        _ = server.tick(handler, Timeout.nanoseconds(0))


def _tick_and_read[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    mut client: TCPConn,
    max_ticks: Int = 100,
    expect_body: Bool = True,
) raises -> List[Byte]:
    var out = List[Byte]()
    var tmp = Array[Byte, 8192](fill=0)
    for _ in range(max_ticks):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _response_complete(out, expect_body):
                break
        except e:
            if e.kind == NetErrorKind.timeout():
                pass
            elif e.kind == NetErrorKind.closed():
                break
            else:
                raise e
        sleep(0.002)
    return out^


def _chunked_response_complete(buf: List[Byte]) -> Bool:
    var end = _header_end(buf)
    if end < 0:
        return False
    var s = String(from_utf8_lossy=Span(buf)[end:])
    return s.find("0\r\n\r\n") >= 0


def _tick_and_read_chunked[
    H: Handler
](
    mut server: Server,
    mut handler: H,
    mut client: TCPConn,
    max_ticks: Int = 100,
) raises -> List[Byte]:
    var out = List[Byte]()
    var tmp = Array[Byte, 8192](fill=0)
    for _ in range(max_ticks):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                break
            for i in range(n):
                out.append(tmp[i])
            if _chunked_response_complete(out):
                break
        except e:
            if e.kind == NetErrorKind.timeout():
                pass
            elif e.kind == NetErrorKind.closed():
                break
            else:
                raise e
        sleep(0.002)
    return out^


struct _DeferredHandler(Handler):
    var sender_box: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self, box: Pointer[Int, MutUntrackedOrigin]):
        self.sender_box = box

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if (
            req.path == "/deferred"
            or req.path == "/stream"
            or req.path == "/stream-204"
        ):
            var s = writer.detach()
            self.sender_box[] = s._take()
        elif req.path == "/second":
            writer.set_status(200)
            writer.write_string("second-response")
        else:
            writer.set_status(404)
            writer.write_string("not-found")


struct _FailingDetachedStreamHandler(Handler):
    var sender_addr: Int

    def __init__(out self):
        self.sender_addr = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var sender = writer.detach()
        var headers = Headers()
        headers.add(String("X-Fail"), String("too large"))
        sender.start(200, headers^)
        _ = sender.send("chunk".as_bytes())
        sender.finish()
        self.sender_addr = sender._take()


def test_detached_start_failure_drops_remaining_batch() raises:
    var config = ServerConfig.default()
    config.max_response_headers_bytes = 1
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var handler = _FailingDetachedStreamHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    var response = _tick_and_read(server, handler, client)
    assert_equal(_status_of(response), 500)
    assert_equal(_body_of(response), "500 Internal Server Error")
    assert_equal(
        len(response), _header_end(response) + _content_length_of(response)
    )
    assert_equal(len(_split_responses(response)), 1)
    var sender = ResponseSender(handler.sender_addr)
    assert_true(sender.is_cancelled())

    client.close()


def test_detached_respond_success_and_keep_alive() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)
    var handler = _DeferredHandler(box)

    client.write_all(
        "GET /deferred HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)
    var headers = Headers()
    headers.add(String("Content-Type"), String("text/plain"))
    var body = List[Byte]()
    var msg = "deferred-body".as_bytes()
    for i in range(len(msg)):
        body.append(msg[i])
    sender.respond(200, headers^, body^)

    var resp1 = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp1), 200)
    assert_equal(_body_of(resp1), "deferred-body")

    client.write_all(
        "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    var resp2 = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-response")

    client.close()
    external_call["free", NoneType](box)


struct _DropSenderHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/drop":
            _ = writer.detach()
            # Dropped without calling respond() or start()
        else:
            writer.set_status(200)
            writer.write_string("ok")


def test_detached_sender_drop_without_respond_closes_connection() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )

    var handler = _DropSenderHandler()

    client.write_all(
        "GET /drop HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    var resp = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp), 500)
    var resp_str = String(from_utf8_lossy=Span(resp))
    assert_true(
        resp_str.find("connection: close") >= 0
        or resp_str.find("Connection: close") >= 0,
        "500 response on abort must advertise Connection: close",
    )
    var eof_seen = False
    var tmp = Array[Byte, 256](fill=0)
    for _ in range(20):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n == 0:
                eof_seen = True
                break
        except e:
            if e.kind == NetErrorKind.closed():
                eof_seen = True
                break
        sleep(0.002)
    assert_true(
        eof_seen, "server must close socket after aborted detached response"
    )

    client.close()


struct _PipelineDeferredHandler(Handler):
    var sender_box: Pointer[Int, MutUntrackedOrigin]
    var second_called: Pointer[Bool, MutUntrackedOrigin]

    def __init__(
        out self,
        box: Pointer[Int, MutUntrackedOrigin],
        second_called: Pointer[Bool, MutUntrackedOrigin],
    ):
        self.sender_box = box
        self.second_called = second_called

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/first":
            var s = writer.detach()
            self.sender_box[] = s._take()
        elif req.path == "/second":
            self.second_called[] = True
            writer.set_status(200)
            writer.write_string("SECOND")
        else:
            writer.set_status(404)


def test_detached_pipeline_order_preserved() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var second_called = external_call[
        "malloc", Pointer[Bool, MutUntrackedOrigin]
    ](c_size_t(size_of[Bool]()))
    assert_true(Int(second_called) != 0)
    second_called.unsafe_write(False)

    var handler = _PipelineDeferredHandler(box, second_called)

    var reqs = (
        "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n"
        + "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )
    client.write_all(reqs.as_bytes(), Timeout.seconds(2))

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    assert_false(second_called[])

    var sender = ResponseSender(sender_addr)
    var headers = Headers()
    var body = List[Byte]()
    var msg = "FIRST".as_bytes()
    for i in range(len(msg)):
        body.append(msg[i])
    sender.respond(200, headers^, body^)

    var all_bytes = List[Byte]()
    var tmp = Array[Byte, 8192](fill=0)
    for _ in range(100):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        try:
            var n = client.try_read(Span(tmp))
            if n > 0:
                for i in range(n):
                    all_bytes.append(tmp[i])
                var parts = _split_responses(all_bytes)
                if len(parts) >= 2:
                    break
        except e:
            if e.kind == NetErrorKind.closed():
                break
        sleep(0.002)

    var parts = _split_responses(all_bytes)
    assert_equal(len(parts), 2)
    assert_equal(_status_of(parts[0]), 200)
    assert_equal(_body_of(parts[0]), "FIRST")
    assert_true(second_called[])
    assert_equal(_status_of(parts[1]), 200)
    assert_equal(_body_of(parts[1]), "SECOND")

    client.close()
    external_call["free", NoneType](box)
    external_call["free", NoneType](second_called)


struct _TimeoutDeferredHandler(Handler):
    var sender_box: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self, box: Pointer[Int, MutUntrackedOrigin]):
        self.sender_box = box

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var s = writer.detach()
        self.sender_box[] = s._take()


def test_detached_response_timeout_503_and_cancelled() raises:
    var config = ServerConfig.default()
    config.detached_response_timeout = Timeout.milliseconds(50)
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _TimeoutDeferredHandler(box)

    client.write_all(
        "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)
    assert_false(sender.is_cancelled())

    sleep(0.08)

    var resp = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp), 503)

    assert_true(sender.is_cancelled())
    var respond_failed = False
    var h = Headers()
    var b = List[Byte]()
    try:
        sender.respond(200, h^, b^)
    except e:
        if e.kind == NetErrorKind.closed():
            respond_failed = True
    assert_true(respond_failed)

    client.close()
    external_call["free", NoneType](box)


struct _MultiDetachHandler(Handler):
    var box1: Pointer[Int, MutUntrackedOrigin]
    var box2: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self,
        b1: Pointer[Int, MutUntrackedOrigin],
        b2: Pointer[Int, MutUntrackedOrigin],
    ):
        self.box1 = b1
        self.box2 = b2

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/c1":
            var s = writer.detach()
            self.box1[] = s._take()
        elif req.path == "/c2":
            var s = writer.detach()
            self.box2[] = s._take()


def test_detached_concurrent_connections_no_spurious_untracking() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box1 = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box1) != 0)
    box1.unsafe_write(0)

    var box2 = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box2) != 0)
    box2.unsafe_write(0)

    var handler = _MultiDetachHandler(box1, box2)

    var client1 = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client1.write_all(
        "GET /c1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        .as_bytes(),
        Timeout.seconds(2),
    )

    var client2 = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client2.write_all(
        "GET /c2 HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    for _ in range(30):
        if box1[] != 0 and box2[] != 0:
            break
        _ = server.tick(handler, Timeout.nanoseconds(0))
        sleep(0.002)

    assert_true(box1[] != 0)
    assert_true(box2[] != 0)

    var s1 = ResponseSender(box1[])
    var h1 = Headers()
    var b1 = List[Byte]()
    var msg1 = "resp1".as_bytes()
    for i in range(len(msg1)):
        b1.append(msg1[i])
    s1.respond(200, h1^, b1^, should_close=True)

    var resp1 = _tick_and_read(server, handler, client1)
    assert_equal(_status_of(resp1), 200)
    assert_equal(_body_of(resp1), "resp1")
    client1.close()

    var s2 = ResponseSender(box2[])
    var h2 = Headers()
    var b2 = List[Byte]()
    var msg2 = "resp2".as_bytes()
    for i in range(len(msg2)):
        b2.append(msg2[i])
    s2.respond(200, h2^, b2^)

    var resp2 = _tick_and_read(server, handler, client2)
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "resp2")
    client2.close()

    external_call["free", NoneType](box1)
    external_call["free", NoneType](box2)


struct _RaisingDetachHandler(Handler):
    var box: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self, b: Pointer[Int, MutUntrackedOrigin]):
        self.box = b

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var s = writer.detach()
        self.box[] = s._take()
        raise Error("test error after detach")


def test_detached_handler_exception_cancels_and_cleans_up() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _RaisingDetachHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /fail HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    var resp = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp), 500)
    assert_equal(_body_of(resp), "500 Internal Server Error")
    assert_equal(server.active_connections(), 0)
    assert_equal(server._budget.used(), size_of[_SharedDetachState]())

    var sender_addr = box[]
    assert_true(sender_addr != 0)
    var sender = ResponseSender(sender_addr)
    assert_true(sender.is_cancelled())
    _ = sender^
    assert_equal(server._budget.used(), 0)

    client.close()
    external_call["free", NoneType](box)


struct _HeadDetachHandler(Handler):
    var box: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self, b: Pointer[Int, MutUntrackedOrigin]):
        self.box = b

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var s = writer.detach()
        self.box[] = s._take()


def test_detached_head_request_omits_body() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _HeadDetachHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "HEAD /head HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)
    var h = Headers()
    var b = List[Byte]()
    var msg = "body-should-not-be-sent".as_bytes()
    for i in range(len(msg)):
        b.append(msg[i])
    sender.respond(200, h^, b^)

    var resp = _tick_and_read(server, handler, client, expect_body=False)
    assert_equal(_status_of(resp), 200)
    assert_equal(_content_length_of(resp), len(msg))
    assert_equal(_body_of(resp), "")

    client.close()
    external_call["free", NoneType](box)


@fieldwise_init
struct _WorkerRespondContext:
    var sender_addr: Int
    var done: Bool


def _worker_respond_thread(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx = arg.unsafe_bitcast[_WorkerRespondContext]()
    sleep(0.03)
    var sender = ResponseSender(ctx[].sender_addr)
    var h = Headers()
    var b = List[Byte]()
    var s = "threaded-worker-reply".as_bytes()
    for i in range(len(s)):
        b.append(s[i])
    try:
        sender.respond(200, h^, b^)
        ctx[].done = True
    except:
        ctx[].done = False
    return arg


struct _BudgetedWorkerHandler(Handler):
    var context: Pointer[_WorkerRespondContext, MutUntrackedOrigin]
    var budget: SharedBufferBudget
    var body_charge: Int
    var thread: UInt64
    var started: Bool

    def __init__(
        out self,
        context: Pointer[_WorkerRespondContext, MutUntrackedOrigin],
        var budget: SharedBufferBudget,
    ):
        self.context = context
        self.budget = budget^
        self.body_charge = -1
        self.thread = 0
        self.started = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.write_string("handler-local body")
        self.body_charge = self.budget.used()
        var sender = writer.detach()
        self.context[].sender_addr = sender._take()
        var rc = external_call["pthread_create", c_int](
            Pointer(to=self.thread),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _worker_respond_thread,
            self.context.unsafe_bitcast[Byte](),
        )
        assert_equal(Int(rc), 0)
        self.started = True


def test_writer_body_charge_returns_when_handler_starts_detached_worker() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 512 + size_of[_SharedDetachState]()
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    var context = external_call[
        "malloc", Pointer[_WorkerRespondContext, MutUntrackedOrigin]
    ](c_size_t(size_of[_WorkerRespondContext]()))
    assert_true(Int(context) != 0)
    context.unsafe_write(_WorkerRespondContext(sender_addr=0, done=False))
    var handler = _BudgetedWorkerHandler(context, server._budget.copy())
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    for _ in range(20):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if handler.started:
            break
    assert_true(handler.started)
    _join_thread(handler.thread)
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=server._conns[0].detach_state_addr
    )
    assert_equal(
        server._budget.used(),
        size_of[_SharedDetachState]()
        + state[].messages.capacity() * size_of[DetachMessage]()
        + state[].messages[0].body.capacity(),
    )
    var response = _tick_and_read(server, handler, client)
    assert_true(context[].done)
    assert_equal(_body_of(response), "threaded-worker-reply")
    assert_equal(server._budget.used(), 0)
    client.close()
    external_call["free", NoneType](context)
    assert_equal(handler.body_charge, 18)


struct _MailboxHandler(Handler):
    var addr: Int

    def __init__(out self):
        self.addr = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var sender = writer.detach()
        self.addr = sender._take()


def _wait_mailbox_handler(
    mut server: Server, mut handler: _MailboxHandler
) raises:
    var deadline = perf_counter_ns() + 2_000_000_000
    while handler.addr == 0 and perf_counter_ns() < deadline:
        _ = server.tick(handler, Timeout.milliseconds(1))
    assert_true(handler.addr != 0)


struct _StateAdmissionHandler(Handler):
    var called: Bool
    var addr: Int
    var rejected: Bool
    var coherent: Bool

    def __init__(out self):
        self.called = False
        self.addr = 0
        self.rejected = False
        self.coherent = True

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.called = True
        try:
            var sender = writer.detach()
            self.addr = sender._take()
        except e:
            self.rejected = e.kind == NetErrorKind.invalid_argument()
            self.coherent = (
                not writer.is_detached() and writer._detach_state_addr == 0
            )
            writer.set_status(204)


def test_retained_cancelled_states_are_bounded_across_connection_slot_reuse() raises:
    var config = ServerConfig.default()
    config.max_connections = 1
    config.total_buffer_budget = 1024
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _StateAdmissionHandler()
    var senders = List[ResponseSender]()
    var rejected = False
    var coherent = True
    for _ in range(16):
        handler.called = False
        handler.addr = 0
        var client = dial_tcp(
            String("127.0.0.1:") + String(server.local_address().port),
            Timeout.seconds(1),
        )
        client.write_all(
            "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
        )
        var deadline = perf_counter_ns() + 2_000_000_000
        while not handler.called and perf_counter_ns() < deadline:
            _ = server.tick(handler, Timeout.milliseconds(1))
        assert_true(handler.called)
        if handler.addr != 0:
            for i in range(len(senders)):
                assert_true(handler.addr != senders[i]._addr)
            senders.append(ResponseSender(handler.addr))
        else:
            rejected = rejected or handler.rejected
            coherent = coherent and handler.coherent
        client.close()
        server._close_conn(0)
        assert_equal(server._active_conns, 0)
        assert_equal(len(server._conns), 1)
        assert_true(server._budget.used() <= server._budget.total())
    for i in range(len(senders)):
        assert_true(senders[i].is_cancelled())
        var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
            unsafe_from_address=senders[i]._addr
        )
        assert_equal(state[].ref_count, 1)
    var retained = len(senders) * size_of[_SharedDetachState]()
    var charged = server._budget.used()
    _ = senders^
    assert_equal(server._budget.used(), 0)
    assert_equal(charged, retained)
    assert_true(rejected)
    assert_true(coherent)
    handler.addr = 0
    handler.called = False
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    var deadline = perf_counter_ns() + 2_000_000_000
    while not handler.called and perf_counter_ns() < deadline:
        _ = server.tick(handler, Timeout.milliseconds(1))
    assert_true(handler.called)
    assert_true(handler.addr != 0)
    var sender = ResponseSender(handler.addr)
    client.close()
    server._close_conn(0)
    _ = sender^
    assert_equal(server._budget.used(), 0)


def test_cancelled_state_charge_survives_server_and_budget_owner_drop() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var observer = server._budget.copy()
    assert_true(observer.try_reserve(5))
    var handler = _MailboxHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    _wait_mailbox_handler(server, handler)
    var sender = ResponseSender(handler.addr)
    client.close()
    server._close_conn(0)
    _ = server^
    assert_true(sender.is_cancelled())
    var moved = _move_sender(sender^)
    var held = observer.used()
    _ = moved^
    assert_equal(observer.used(), 5)
    assert_equal(held, size_of[_SharedDetachState]() + 5)


def test_detached_mailbox_array_capacity_uses_the_shared_budget() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 4096
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _MailboxHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    _wait_mailbox_handler(server, handler)
    var sender = ResponseSender(handler.addr)
    sender.start()
    assert_true(sender.send("a".as_bytes()))
    assert_true(sender.send("b".as_bytes()))
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=handler.addr
    )
    var capacity = state[].messages.capacity()
    var charged = server._budget.used()
    client.close()
    server._close_conn(0)
    _ = sender^
    assert_equal(capacity, 4)
    assert_equal(
        charged,
        size_of[_SharedDetachState]() + 4 * size_of[DetachMessage]() + 2,
    )
    assert_equal(server._budget.used(), 0)


@fieldwise_init
struct _MailboxRefillContext:
    var sender_addr: Int
    var sent: Bool
    var failed: Bool


def _check_detached_response_wire_boundary(is_head: Bool) raises:
    comptime state_size = size_of[_SharedDetachState]()
    comptime element = size_of[DetachMessage]()
    var wire_size = 97 if is_head else 6097
    for admitted in [False, True]:
        var config = ServerConfig.default()
        config.total_buffer_budget = (
            state_size + element + 6000 + 5 + wire_size - Int(not admitted)
        )
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var handler = _MailboxHandler()
        var address = String("127.0.0.1:") + String(server.local_address().port)
        var client = dial_tcp(address, Timeout.seconds(1))
        var method = String("HEAD") if is_head else String("GET")
        client.write_all(
            (method + " / HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
            Timeout.seconds(1),
        )
        _wait_mailbox_handler(server, handler)
        assert_true(server._budget.try_reserve(5))
        var sender = ResponseSender(handler.addr)
        var body = List[Byte](capacity=6000)
        for _ in range(6000):
            body.append(Byte(ord("a")))
        sender.respond(200, Headers(), body^, should_close=True)
        assert_equal(server._budget.used(), state_size + element + 6000 + 5)
        var response = _drain_head_error_to_eof(server, handler, client)
        assert_equal(server.active_connections(), 0)
        assert_equal(server._budget.used(), state_size + 5)
        client.close()
        _ = sender^
        assert_equal(server._budget.used(), 5)
        var status = _status_of(response)
        var length = _content_length_of(response)
        var response_body = _body_of(response)
        handler.addr = 0
        var sibling = dial_tcp(address, Timeout.seconds(1))
        sibling.write_all(
            "GET /next HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(),
            Timeout.seconds(1),
        )
        _wait_mailbox_handler(server, handler)
        var next_sender = ResponseSender(handler.addr)
        next_sender.respond(204, Headers(), List[Byte](), should_close=True)
        var next_response = _drain_head_error_to_eof(server, handler, sibling)
        sibling.close()
        _ = next_sender^
        assert_equal(_status_of(next_response), 204)
        assert_equal(_body_of(next_response), "")
        assert_equal(server._budget.used(), 5)
        server._budget.release(5)
        if is_head and not admitted:
            assert_equal(status, -1)
            assert_equal(length, -1)
            assert_equal(len(response), 0)
        else:
            assert_equal(status, 200 if admitted else 500)
            assert_equal(length, 6000 if admitted else 25)
        if is_head:
            assert_equal(response_body, "")
        elif admitted:
            assert_equal(response_body.byte_length(), 6000)
            for i in range(len(response_body.as_bytes())):
                assert_equal(response_body.as_bytes()[i], Byte(ord("a")))
        else:
            assert_equal(response_body, "500 Internal Server Error")


def test_detached_get_wire_admits_exact_capacity_while_body_remains_charged() raises:
    _check_detached_response_wire_boundary(False)


def test_detached_head_wire_keeps_full_body_charge_but_only_encodes_headers() raises:
    _check_detached_response_wire_boundary(True)


def test_respond_admits_body_capacity_with_foreign_and_array_charges() raises:
    comptime state_size = size_of[_SharedDetachState]()
    comptime element = size_of[DetachMessage]()
    for available in [63, 64 + element - 1, 64 + element]:
        var admitted = available == 64 + element
        var budget = SharedBufferBudget(state_size + 17 + available)
        assert_true(budget.try_reserve(17))
        var addr = _create_detach_state(
            slot=0, generation=1, budget=budget.copy()
        )
        var sender = ResponseSender(addr)
        var body = List[Byte](capacity=64)
        body.append(Byte(ord("a")))
        var rejected = False
        try:
            sender.respond(200, Headers(), body^)
        except e:
            rejected = e.kind == NetErrorKind.invalid_argument()
        var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
            unsafe_from_address=addr
        )
        var charged = budget.used()
        var queued = len(state[].messages)
        var cancelled = sender.is_cancelled()
        if queued:
            assert_equal(state[].messages[0].body.capacity(), 64)
            assert_equal(len(state[].messages[0].body), 1)
        _release_detach_state(addr, from_sender=False)
        _ = sender^
        assert_equal(budget.used(), 17)
        assert_equal(rejected, not admitted)
        assert_equal(cancelled, not admitted)
        assert_equal(queued, Int(admitted))
        assert_equal(charged, state_size + 17 + (64 + element) * Int(admitted))


def test_send_reserves_body_before_full_old_new_array_peak() raises:
    comptime state_size = size_of[_SharedDetachState]()
    comptime element = size_of[DetachMessage]()
    for admitted in [False, True]:
        var budget = SharedBufferBudget(
            state_size + 17 + 64 + 3 * element - Int(not admitted)
        )
        assert_true(budget.try_reserve(17))
        var addr = _create_detach_state(
            slot=0, generation=1, budget=budget.copy()
        )
        var sender = ResponseSender(addr)
        sender.start()
        var data = Array[Byte, 64](fill=Byte(ord("a")))
        var rejected = False
        try:
            _ = sender.send(Span(data))
        except e:
            rejected = e.kind == NetErrorKind.invalid_argument()
        var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
            unsafe_from_address=addr
        )
        var charged = budget.used()
        var queued = state[].queued_bytes
        var count = len(state[].messages)
        var capacity = state[].messages.capacity()
        _release_detach_state(addr, from_sender=False)
        _ = sender^
        assert_equal(budget.used(), 17)
        assert_equal(rejected, not admitted)
        assert_equal(queued, 64 * Int(admitted))
        assert_equal(count, 1 + Int(admitted))
        assert_equal(capacity, 1 + Int(admitted))
        assert_equal(
            charged, state_size + 17 + element + (64 + element) * Int(admitted)
        )


def test_send_body_denial_preserves_spare_array_and_accepted_chunk() raises:
    comptime state_size = size_of[_SharedDetachState]()
    comptime element = size_of[DetachMessage]()
    var budget = SharedBufferBudget(state_size + 3 * element + 4)
    var addr = _create_detach_state(slot=0, generation=1, budget=budget.copy())
    var sender = ResponseSender(addr)
    sender.start()
    assert_true(sender.send("a".as_bytes()))
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    _ = state[].messages.pop(0)
    var foreign = budget.remaining() - 1
    assert_true(budget.try_reserve(foreign))
    var before = budget.used()
    var rejected = False
    try:
        _ = sender.send("bc".as_bytes())
    except e:
        rejected = e.kind == NetErrorKind.invalid_argument()
    var charged = budget.used()
    var queued = state[].queued_bytes
    var count = len(state[].messages)
    var capacity = state[].messages.capacity()
    var terminal = state[].terminal_kind
    assert_equal(state[].messages[0].body[0], Byte(ord("a")))
    _release_detach_state(addr, from_sender=False)
    _ = sender^
    assert_equal(budget.used(), foreign)
    assert_true(rejected)
    assert_equal(charged, before)
    assert_equal(queued, 1)
    assert_equal(count, 1)
    assert_equal(capacity, 2)
    assert_equal(terminal, MSG_KIND_ABORT)


@fieldwise_init
struct _BodyRespondContext:
    var sender_addr: Int
    var submitted: Bool


def _body_respond_thread(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx = arg.unsafe_bitcast[_BodyRespondContext]()
    var sender = ResponseSender(ctx[].sender_addr)
    var body = List[Byte](capacity=64)
    body.append(Byte(ord("a")))
    try:
        sender.respond(200, Headers(), body^)
        ctx[].submitted = True
    except:
        ctx[].submitted = False
    ctx[].sender_addr = sender._take()
    return arg


def test_pthread_response_body_charge_survives_batch_and_server_drop() raises:
    var config = ServerConfig.default()
    config.total_buffer_budget = 4096
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var observer = server._budget.copy()
    var handler = _MailboxHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    _wait_mailbox_handler(server, handler)
    assert_true(observer.try_reserve(17))
    var ctx = _BodyRespondContext(handler.addr, False)
    var thread: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _body_respond_thread,
        Pointer(to=ctx).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)
    _join_thread(thread)
    assert_true(ctx.submitted)
    var sender = ResponseSender(ctx.sender_addr)
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=handler.addr
    )
    var original = Int(state[].messages[0].body.unsafe_ptr())
    var queued_charge = observer.used()
    var batch = _take_batch(state)
    client.close()
    server._close_conn(0)
    _ = server^
    assert_true(sender.is_cancelled())
    _ = sender^
    var batch_charge = observer.used()
    assert_equal(Int(batch.messages[0].body.unsafe_ptr()), original)
    assert_equal(batch.messages[0].body[0], Byte(ord("a")))
    _ = batch^
    assert_equal(observer.used(), 17)
    assert_equal(
        queued_charge,
        size_of[_SharedDetachState]() + size_of[DetachMessage]() + 64 + 17,
    )
    assert_equal(batch_charge, size_of[DetachMessage]() + 64 + 17)


def test_borrowed_respond_message_keeps_body_charge_through_consumer_returns() raises:
    for mode in [0, 1, 2]:
        for is_head in [False, True]:
            var config = ServerConfig.default()
            if mode == 1:
                config.max_response_body = 1
            var server = Server(config^)
            server.add_listener(listen_tcp("127.0.0.1:0"))
            var handler = _MailboxHandler()
            var client = dial_tcp(
                String("127.0.0.1:") + String(server.local_address().port),
                Timeout.seconds(1),
            )
            var method = String("HEAD") if is_head else String("GET")
            client.write_all(
                (method + " / HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes(),
                Timeout.seconds(1),
            )
            _wait_mailbox_handler(server, handler)
            assert_true(server._budget.try_reserve(5))
            var sender = ResponseSender(handler.addr)
            var headers = Headers()
            if mode == 2:
                headers.add(String("Transfer-Encoding"), String("chunked"))
            var body = List[Byte](capacity=64)
            body.append(Byte(ord("a")))
            body.append(Byte(ord("b")))
            sender.respond(200, headers^, body^)
            var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
                unsafe_from_address=handler.addr
            )
            var batch = _take_batch(state)
            var msg = batch.messages.pop(0)
            server._handle_detached_respond(0, msg)
            assert_equal(msg.body.capacity(), 0)
            var charged = server._budget.used()
            var expected = (
                size_of[_SharedDetachState]()
                + size_of[DetachMessage]()
                + 64
                + 5
                + server._conns[0].pending.capacity()
            )
            _ = msg^
            var after_message = server._budget.used()
            _ = batch^
            var response = _tick_and_read(server, handler, client)
            client.close()
            server._close_conn(0)
            _ = sender^
            assert_equal(server._budget.used(), 5)
            assert_equal(charged, expected)
            assert_equal(after_message, expected - 64)
            assert_equal(_status_of(response), 200 if mode == 0 else 500)
            assert_equal(_content_length_of(response), 2 if mode == 0 else 25)
            if is_head:
                assert_equal(_body_of(response), "")
            else:
                assert_equal(
                    _body_of(response),
                    "ab" if mode == 0 else "500 Internal Server Error",
                )


def _mailbox_refill_thread(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx = arg.unsafe_bitcast[_MailboxRefillContext]()
    var sender = ResponseSender(ctx[].sender_addr)
    try:
        ctx[].sent = sender.send("x".as_bytes())
    except:
        ctx[].failed = True
    ctx[].sender_addr = sender._take()
    return arg


def test_drained_batch_keeps_array_charge_while_pthread_refills() raises:
    comptime element = size_of[DetachMessage]()
    comptime state_size = size_of[_SharedDetachState]()
    for extra in [18, 17]:
        var config = ServerConfig.default()
        config.total_buffer_budget = state_size + 2 * element + extra
        var server = Server(config^)
        server.add_listener(listen_tcp("127.0.0.1:0"))
        var handler = _MailboxHandler()
        var client = dial_tcp(
            String("127.0.0.1:") + String(server.local_address().port),
            Timeout.seconds(1),
        )
        client.write_all(
            "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
        )
        _wait_mailbox_handler(server, handler)
        assert_true(server._budget.try_reserve(17))
        var sender = ResponseSender(handler.addr)
        sender.start()
        var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
            unsafe_from_address=handler.addr
        )
        var original = Int(state[].messages.unsafe_ptr())
        var batch = _take_batch(state)
        assert_equal(state[].messages.capacity(), 0)
        assert_equal(server._budget.used(), state_size + element + 17)
        var ctx = _MailboxRefillContext(
            sender_addr=sender._take(), sent=False, failed=False
        )
        var thread: UInt64 = 0
        var rc = external_call["pthread_create", c_int](
            Pointer(to=thread),
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _mailbox_refill_thread,
            Pointer(to=ctx).unsafe_bitcast[Byte](),
        )
        assert_equal(Int(rc), 0)
        _join_thread(thread)
        var returned = ResponseSender(ctx.sender_addr)
        var admitted = extra == 18
        assert_equal(ctx.sent, admitted)
        assert_equal(ctx.failed, not admitted)
        assert_equal(
            server._budget.used(),
            state_size + 17 + element + (element + 1) * Int(admitted),
        )
        assert_equal(Int(batch.messages.unsafe_ptr()), original)
        assert_equal(batch.messages[0].kind, MSG_KIND_START)
        if admitted:
            assert_true(Int(state[].messages.unsafe_ptr()) != original)
            assert_equal(state[].messages.capacity(), 1)
        else:
            assert_equal(state[].messages.capacity(), 0)
            assert_equal(state[].terminal_kind, MSG_KIND_ABORT)
        _ = batch^
        assert_equal(
            server._budget.used(),
            state_size + 17 + (element + 1) * Int(admitted),
        )
        client.close()
        server._close_conn(0)
        assert_true(returned.is_cancelled())
        assert_equal(server._budget.used(), state_size + 17)
        _ = returned^
        assert_equal(server._budget.used(), 17)
        server._budget.release(17)


def test_mailbox_growth_denial_retains_old_array_and_foreign_charge() raises:
    comptime element = size_of[DetachMessage]()
    comptime state_size = size_of[_SharedDetachState]()
    var budget = SharedBufferBudget(state_size + 3 * element + 17)
    assert_true(budget.try_reserve(17))
    var addr = _create_detach_state(slot=0, generation=1, budget=budget.copy())
    var sender = ResponseSender(addr)
    sender.start()
    var rejected = False
    try:
        _ = sender.send("x".as_bytes())
    except e:
        rejected = e.kind == NetErrorKind.invalid_argument()
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    assert_true(rejected)
    assert_equal(len(state[].messages), 1)
    assert_equal(state[].messages.capacity(), 1)
    assert_equal(state[].terminal_kind, MSG_KIND_ABORT)
    assert_equal(budget.used(), state_size + element + 17)
    _release_detach_state(addr, from_sender=False)
    _ = sender^
    assert_equal(budget.used(), 17)


def _throw_with_owned_batch(var batch: _DetachedBatch) raises:
    assert_equal(batch.messages[0].kind, MSG_KIND_START)
    raise Error("batch unwind")


def test_owned_batch_unwind_refunds_only_its_array() raises:
    comptime element = size_of[DetachMessage]()
    var budget = SharedBufferBudget(size_of[_SharedDetachState]() + element + 9)
    assert_true(budget.try_reserve(9))
    var addr = _create_detach_state(slot=0, generation=1, budget=budget.copy())
    var sender = ResponseSender(addr)
    sender.start()
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    var batch = _take_batch(state)
    _release_detach_state(addr, from_sender=False)
    _ = sender^
    assert_equal(budget.used(), element + 9)
    var threw = False
    try:
        _throw_with_owned_batch(batch^)
    except:
        threw = True
    assert_true(threw)
    assert_equal(budget.used(), 9)


def test_finish_follows_accepted_chunks_without_array_growth() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var handler = _MailboxHandler()
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(1),
    )
    client.write_all(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Timeout.seconds(1)
    )
    _wait_mailbox_handler(server, handler)
    var sender = ResponseSender(handler.addr)
    sender.start()
    assert_true(sender.send("a".as_bytes()))
    assert_true(sender.send("b".as_bytes()))
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=handler.addr
    )
    var capacity = state[].messages.capacity()
    sender.finish()
    assert_equal(state[].messages.capacity(), capacity)
    assert_equal(len(state[].messages), 3)
    assert_equal(state[].terminal_kind, MSG_KIND_FINISH)
    _ = sender^
    var response = _tick_and_read_chunked(server, handler, client)
    assert_equal(_status_of(response), 200)
    assert_equal(_body_of(response), "1\r\na\r\n1\r\nb\r\n0\r\n\r\n")
    assert_equal(server._budget.used(), 0)
    client.close()


def _apply_terminal(var sender: ResponseSender, mode: Int) raises:
    if mode == 0:
        sender.finish()
    elif mode == 1:
        sender.abort()


def test_shared_terminal_needs_no_space_after_accepted_data() raises:
    comptime element = size_of[DetachMessage]()
    for mode in [0, 1, 2]:
        var budget = SharedBufferBudget(
            size_of[_SharedDetachState]() + 3 * element + 1
        )
        var addr = _create_detach_state(
            slot=0, generation=1, budget=budget.copy()
        )
        var sender = ResponseSender(addr)
        sender.start()
        assert_true(sender.send("a".as_bytes()))
        assert_true(budget.try_reserve(element))
        assert_equal(budget.remaining(), 0)
        _apply_terminal(sender^, mode)
        var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
            unsafe_from_address=addr
        )
        assert_equal(len(state[].messages), 2)
        assert_equal(state[].messages.capacity(), 2)
        assert_equal(state[].array_ticket.amount, 2 * element)
        assert_equal(budget.remaining(), 0)
        var batch = _take_batch(state)
        _release_detach_state(addr, from_sender=False)
        assert_equal(budget.used(), 3 * element + 1)
        assert_equal(batch.messages[0].kind, MSG_KIND_START)
        assert_equal(batch.messages[1].kind, MSG_KIND_CHUNK)
        assert_equal(batch.messages[1].body[0], Byte(ord("a")))
        assert_equal(
            batch.terminal_kind,
            MSG_KIND_FINISH if mode == 0 else MSG_KIND_ABORT,
        )
        _ = batch^
        assert_equal(budget.used(), element)


def test_overflow_terminal_preserves_full_budget_and_old_batch() raises:
    comptime element = size_of[DetachMessage]()
    var budget = SharedBufferBudget(
        size_of[_SharedDetachState]() + 3 * element + 5 + 2
    )
    assert_true(budget.try_reserve(5))
    var addr = _create_detach_state(
        slot=0, generation=1, queue_limit=1, budget=budget.copy()
    )
    var sender = ResponseSender(addr)
    sender.start()
    assert_true(sender.send("a".as_bytes()))
    var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    var old = _take_batch(state)
    assert_true(sender.send("b".as_bytes()))
    assert_equal(budget.remaining(), 0)
    var rejected = False
    try:
        _ = sender.send("c".as_bytes())
    except e:
        rejected = e.kind == NetErrorKind.invalid_argument()
    assert_true(rejected)
    assert_equal(len(state[].messages), 1)
    assert_equal(state[].messages.capacity(), 1)
    assert_equal(state[].array_ticket.amount, element)
    assert_equal(budget.remaining(), 0)
    var pending = _take_batch(state)
    _release_detach_state(addr, from_sender=False)
    _ = sender^
    assert_equal(budget.used(), 3 * element + 5 + 2)
    assert_equal(old.messages[0].kind, MSG_KIND_START)
    assert_equal(old.messages[1].body[0], Byte(ord("a")))
    assert_equal(pending.messages[0].kind, MSG_KIND_CHUNK)
    assert_equal(pending.messages[0].body[0], Byte(ord("b")))
    assert_equal(pending.terminal_kind, MSG_KIND_ABORT)
    _ = old^
    assert_equal(budget.used(), element + 5 + 1)
    _ = pending^
    assert_equal(budget.used(), 5)


def test_sender_abort_and_drop_do_not_allocate_mailbox_storage() raises:
    for abort_explicitly in [False, True]:
        var addr = _create_detach_state(slot=0, generation=1)
        var sender = ResponseSender(addr)
        if abort_explicitly:
            sender.abort()
        _ = sender^
        var state = Pointer[_SharedDetachState, MutUntrackedOrigin](
            unsafe_from_address=addr
        )
        var capacity = state[].messages.capacity()
        _release_detach_state(addr, from_sender=False)
        assert_equal(capacity, 0)


def test_cross_thread_worker_respond_and_wakeup() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /deferred HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var ctx_ptr = external_call[
        "malloc", Pointer[_WorkerRespondContext, MutUntrackedOrigin]
    ](c_size_t(size_of[_WorkerRespondContext]()))
    assert_true(Int(ctx_ptr) != 0)
    ctx_ptr.unsafe_write(
        _WorkerRespondContext(sender_addr=sender_addr, done=False)
    )

    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _worker_respond_thread,
        ctx_ptr.unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)

    # Calling tick with a 2-second timeout will wake up promptly (~30ms)
    # when the worker thread signals wakeup_fd, rather than waiting 2 seconds.
    _ = server.tick(handler, Timeout.seconds(2))
    var resp = _tick_and_read(server, handler, client)
    _join_thread(handle)
    var done = ctx_ptr[].done
    external_call["free", NoneType](ctx_ptr)
    assert_true(done)
    assert_equal(_status_of(resp), 200)
    assert_equal(_body_of(resp), "threaded-worker-reply")

    client.close()
    external_call["free", NoneType](box)


def test_detached_client_disconnect_cancels_early() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /deferred HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)
    assert_false(sender.is_cancelled())

    # Client closes socket while response is detached
    client.close()

    # Server tick: _pump_read detects EOF on STATE_DETACHED and calls _close_conn
    for _ in range(20):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(
        sender.is_cancelled(),
        "early peer disconnect must mark sender cancelled",
    )
    external_call["free", NoneType](box)


def test_detached_oversized_response_body_cancels_sender() raises:
    var config = ServerConfig.default()
    config.max_response_body = 64
    var server = Server(config^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /deferred HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)
    var h = Headers()
    var b = List[Byte]()
    for _ in range(128):
        b.append(Byte(ord("x")))
    sender.respond(200, h^, b^)

    var resp = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp), 500)
    assert_true(sender.is_cancelled())

    client.close()
    external_call["free", NoneType](box)


def test_streaming_lifecycle_validation() raises:
    var writer = ResponseWriter(1024)
    var sender = writer.detach()

    # send() before start() must fail
    var dummy = Array[Byte, 4](fill=0)
    var send_before_start = False
    try:
        _ = sender.send(Span(dummy))
    except e:
        if e.kind == NetErrorKind.invalid_state():
            send_before_start = True
    assert_true(send_before_start)

    # finish() before start() must fail
    var finish_before_start = False
    try:
        sender.finish()
    except e:
        if e.kind == NetErrorKind.invalid_state():
            finish_before_start = True
    assert_true(finish_before_start)

    # start() succeeds
    sender.start(200)

    # second start() must fail
    var second_start = False
    try:
        sender.start(200)
    except e:
        if e.kind == NetErrorKind.invalid_state():
            second_start = True
    assert_true(second_start)

    # respond() after start() must fail
    var respond_after_start = False
    try:
        var h = Headers()
        var b = List[Byte]()
        sender.respond(200, h^, b^)
    except e:
        if e.kind == NetErrorKind.invalid_state():
            respond_after_start = True
    assert_true(respond_after_start)

    # 0-length send is a no-op returning True
    var empty_list = List[Byte]()
    assert_true(sender.send(Span(empty_list)))

    # normal send succeeds
    assert_true(sender.send(Span(dummy)))

    # finish() succeeds
    sender.finish()

    # send() after finish() must fail
    var send_after_finish = False
    try:
        _ = sender.send(Span(dummy))
    except e:
        if e.kind == NetErrorKind.invalid_state():
            send_after_finish = True
    assert_true(send_after_finish)

    # second finish() must fail
    var second_finish = False
    try:
        sender.finish()
    except e:
        if e.kind == NetErrorKind.invalid_state():
            second_finish = True
    assert_true(second_finish)
    _release_detach_state(writer._detach_state_addr, from_sender=False)


def test_streaming_rejects_content_length() raises:
    var writer = ResponseWriter(1024)
    var sender = writer.detach()
    var h = Headers()
    h.add(String("Content-Length"), String("42"))
    var rejected = False
    try:
        sender.start(200, h^)
    except e:
        if e.kind == NetErrorKind.invalid_argument():
            rejected = True
    assert_true(rejected)
    _release_detach_state(writer._detach_state_addr, from_sender=False)


def test_streaming_queue_limit_exceeded() raises:
    var writer = ResponseWriter(1024, queue_limit=16)
    var sender = writer.detach()
    sender.start(200)

    var large_chunk = List[Byte]()
    for _ in range(32):
        large_chunk.append(Byte(ord("a")))

    var exceeded = False
    try:
        _ = sender.send(Span(large_chunk))
    except e:
        if e.kind == NetErrorKind.invalid_argument():
            exceeded = True
    assert_true(exceeded)
    assert_true(sender.is_cancelled())
    _release_detach_state(writer._detach_state_addr, from_sender=False)


def test_detached_response_streaming_chunks() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    box.unsafe_write(0)

    var sender = ResponseSender(sender_addr)
    sender.start(200)
    _ = sender.send(String("alpha").as_bytes())
    _ = sender.send(String("beta").as_bytes())
    _ = sender.send(String("gamma").as_bytes())
    sender.finish()

    var resp = _tick_and_read_chunked(server, handler, client)
    assert_equal(_status_of(resp), 200)
    var raw = String(from_utf8_lossy=Span(resp))
    assert_true(raw.find("Transfer-Encoding: chunked") >= 0)
    assert_equal(
        _body_of(resp), "5\r\nalpha\r\n4\r\nbeta\r\n5\r\ngamma\r\n0\r\n\r\n"
    )

    # Keep-alive check: subsequent request on same connection succeeds
    client.write_all(
        "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    var resp2 = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-response")

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_head_omits_chunks() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "HEAD /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    box.unsafe_write(0)

    var sender = ResponseSender(sender_addr)
    sender.start(200)
    _ = sender.send(String("hidden-payload").as_bytes())
    sender.finish()

    var resp = _tick_and_read(server, handler, client, expect_body=False)
    assert_equal(_status_of(resp), 200)
    var raw = String(from_utf8_lossy=Span(resp))
    assert_true(raw.find("Transfer-Encoding: chunked") >= 0)
    assert_equal(_body_of(resp), "")

    # Keep-alive check
    client.write_all(
        "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    var resp2 = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-response")

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_no_body_status() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream-204 HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    box.unsafe_write(0)

    var sender = ResponseSender(sender_addr)
    sender.start(204)
    _ = sender.send(String("dropped-payload").as_bytes())
    sender.finish()

    var resp = _tick_and_read(server, handler, client, expect_body=False)
    assert_equal(_status_of(resp), 204)
    var raw = String(from_utf8_lossy=Span(resp))
    # 204 must NOT emit Transfer-Encoding header
    assert_true(raw.find("Transfer-Encoding") < 0)
    assert_equal(_body_of(resp), "")

    # Keep-alive check
    client.write_all(
        "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    var resp2 = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-response")

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_client_disconnect_cancels() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    var sender = ResponseSender(sender_addr)

    sender.start(200)
    # Server flushes start headers
    _ = server.tick(handler, Timeout.nanoseconds(0))

    # Client disconnects early
    client.close()

    # Server tick observes EOF and cancels detached state
    for _ in range(10):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(sender.is_cancelled())
    assert_false(sender.send(String("chunk").as_bytes()))

    external_call["free", NoneType](box)


def test_detached_server_shutdown_cancels_live_connections() raises:
    var cfg = ServerConfig.default()
    cfg.shutdown_grace = Timeout.milliseconds(50)
    var server = Server(cfg.copy())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /deferred HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)
    assert_false(sender.is_cancelled())

    server.request_shutdown()
    for _ in range(50):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(sender.is_cancelled(), "shutdown must cancel detached sender")

    client.close()
    external_call["free", NoneType](box)


def test_detached_late_respond_after_cancellation_ignored_safely() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /deferred HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)

    var sender = ResponseSender(sender_addr)

    # Client disconnects early, cancelling the detached state
    client.close()
    for _ in range(10):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(sender.is_cancelled())

    # Late respond() must refuse and raise NetErrorKind.closed()
    var raised_closed = False
    var h = Headers()
    var b = List[Byte]()
    var msg = "late-reply".as_bytes()
    for i in range(len(msg)):
        b.append(msg[i])
    try:
        sender.respond(200, h^, b^)
    except e:
        if e.kind == NetErrorKind.closed():
            raised_closed = True

    assert_true(
        raised_closed, "late respond after cancel must raise closed error"
    )

    # Ticking server must remain healthy with zero crashes or leaks
    for _ in range(5):
        _ = server.tick(handler, Timeout.nanoseconds(0))

    external_call["free", NoneType](box)


struct _SlotReuseHandler(Handler):
    var detach_box: Pointer[Int, MutUntrackedOrigin]
    var second_served: Pointer[Bool, MutUntrackedOrigin]

    def __init__(
        out self,
        box: Pointer[Int, MutUntrackedOrigin],
        second: Pointer[Bool, MutUntrackedOrigin],
    ):
        self.detach_box = box
        self.second_served = second

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/detach-first":
            var s = writer.detach()
            self.detach_box[] = s._take()
        elif req.path == "/second-conn":
            self.second_served[] = True
            writer.set_status(200)
            writer.write_string("second-conn-ok")
        else:
            writer.set_status(404)


def test_detached_generation_mismatch_and_slot_reuse_isolated() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var second_served = external_call[
        "malloc", Pointer[Bool, MutUntrackedOrigin]
    ](c_size_t(size_of[Bool]()))
    assert_true(Int(second_served) != 0)
    second_served.unsafe_write(False)

    var handler = _SlotReuseHandler(box, second_served)

    # Client 1 connects and detaches
    var client1 = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client1.write_all(
        "GET /detach-first HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    _tick_until_detached(server, handler, box)
    var sender1_addr = box[]
    assert_true(sender1_addr != 0)
    var sender1 = ResponseSender(sender1_addr)

    # Client 1 disconnects; server cleans up slot S
    client1.close()
    for _ in range(10):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender1.is_cancelled():
            break
        sleep(0.002)

    # Client 2 connects (reusing slot S with a new generation)
    var client2 = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client2.write_all(
        "GET /second-conn HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    # Stale sender 1 calls respond() (or abort)
    var h1 = Headers()
    var b1 = List[Byte]()
    try:
        sender1.respond(200, h1^, b1^)
    except:
        pass

    # Verify Client 2 receives its own response normally and is untouched by sender 1
    var resp2 = _tick_and_read(server, handler, client2)
    assert_true(second_served[])
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-conn-ok")

    client2.close()
    external_call["free", NoneType](box)
    external_call["free", NoneType](second_served)


def test_detached_streaming_idle_timeout_cancels() raises:
    var cfg = ServerConfig.default()
    cfg.stream_idle_timeout = Timeout.milliseconds(50)
    var server = Server(cfg^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    var sender = ResponseSender(sender_addr)

    sender.start(200)
    _ = server.tick(handler, Timeout.nanoseconds(0))
    assert_false(sender.is_cancelled())

    # Wait out the 50ms stream idle timeout
    sleep(0.08)

    # Server tick expires the idle deadline
    for _ in range(10):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(sender.is_cancelled(), "stream idle timeout must cancel sender")
    assert_false(sender.send(String("chunk").as_bytes()))

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_write_deadline_cancels() raises:
    var cfg = ServerConfig.default()
    cfg.write_deadline = Timeout.milliseconds(50)
    var server = Server(cfg^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    var sender = ResponseSender(sender_addr)

    sender.start(200)
    var chunk = List[Byte]()
    for _ in range(512):
        chunk.append(Byte(ord("x")))
    _ = sender.send(Span(chunk))

    # Process detached messages to arm write_at deadline
    _ = server.tick(handler, Timeout.nanoseconds(0))

    # Sleep past write deadline (50ms)
    sleep(0.08)

    # Server tick expires write deadline
    for _ in range(10):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(
        sender.is_cancelled(), "write deadline expiry must cancel sender"
    )
    assert_false(sender.send(String("chunk").as_bytes()))

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_graceful_shutdown_finishes_within_grace() raises:
    var cfg = ServerConfig.default()
    cfg.shutdown_grace = Timeout.milliseconds(500)
    var server = Server(cfg^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    var sender = ResponseSender(sender_addr)

    # Request shutdown while stream is detached
    server.request_shutdown()

    # Stream sends chunks and finishes cleanly within grace period
    sender.start(200)
    assert_true(sender.send(String("graceful-stream").as_bytes()))
    sender.finish()

    var resp = _tick_and_read_chunked(server, handler, client)
    assert_equal(_status_of(resp), 200)
    var raw = String(from_utf8_lossy=Span(resp))
    assert_true(raw.find("Transfer-Encoding: chunked") >= 0)
    assert_true(raw.find("graceful-stream") >= 0)

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_graceful_shutdown_exceeded_grace_cancels() raises:
    var cfg = ServerConfig.default()
    cfg.shutdown_grace = Timeout.milliseconds(50)
    var server = Server(cfg^)
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    var sender = ResponseSender(sender_addr)
    sender.start(200)
    _ = server.tick(handler, Timeout.nanoseconds(0))

    # Request shutdown and wait past the grace period (50ms) without calling finish()
    server.request_shutdown()
    sleep(0.08)

    for _ in range(20):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender.is_cancelled():
            break
        sleep(0.002)

    assert_true(
        sender.is_cancelled(), "grace expiry must cancel unfinished stream"
    )
    assert_false(sender.send(String("late-chunk").as_bytes()))

    client.close()
    external_call["free", NoneType](box)


def test_detached_streaming_slot_reuse_generation_mismatch() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var second_served = external_call[
        "malloc", Pointer[Bool, MutUntrackedOrigin]
    ](c_size_t(size_of[Bool]()))
    assert_true(Int(second_served) != 0)
    second_served.unsafe_write(False)

    var handler = _SlotReuseHandler(box, second_served)

    # Client 1 connects and detaches
    var client1 = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client1.write_all(
        "GET /detach-first HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    _tick_until_detached(server, handler, box)
    var sender1_addr = box[]
    assert_true(sender1_addr != 0)
    var sender1 = ResponseSender(sender1_addr)
    sender1.start(200)
    _ = server.tick(handler, Timeout.nanoseconds(0))

    # Client 1 disconnects early; server closes slot
    client1.close()
    for _ in range(10):
        _ = server.tick(handler, Timeout.nanoseconds(0))
        if sender1.is_cancelled():
            break
        sleep(0.002)
    assert_true(sender1.is_cancelled())

    # Client 2 connects, reusing the slot
    var client2 = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client2.write_all(
        "GET /second-conn HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    # Stale sender 1 attempts to send chunks and finish after cancellation
    assert_false(sender1.send(String("stale-chunk").as_bytes()))
    try:
        sender1.finish()
    except:
        pass

    # Verify Client 2 receives its own response completely unaffected
    var resp2 = _tick_and_read(server, handler, client2)
    assert_true(second_served[])
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-conn-ok")

    client2.close()
    external_call["free", NoneType](box)
    external_call["free", NoneType](second_served)


@fieldwise_init
struct _WorkerStreamHundredsContext:
    var sender_addr: Int
    var num_chunks: Int
    var success_count: Int
    var done: Bool


def _worker_stream_hundreds_thread(
    arg: Pointer[Byte, MutUntrackedOrigin],
) -> Pointer[Byte, MutUntrackedOrigin]:
    var ctx = arg.unsafe_bitcast[_WorkerStreamHundredsContext]()
    # Brief delay so the main thread enters tick; wakeup works whether the loop is sleeping or not
    sleep(0.04)
    var sender = ResponseSender(ctx[].sender_addr)
    var h = Headers()
    try:
        sender.start(200, h^)

        for i in range(ctx[].num_chunks):
            var chunk = String("event-") + String(i) + String("\n")
            var sent = sender.send(chunk.as_bytes())
            if not sent:
                break
            ctx[].success_count += 1

        sender.finish()
        ctx[].done = True
    except:
        ctx[].done = False
    return arg


def test_cross_thread_streaming_hundreds_chunks_and_wakeup() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var port = server.local_address().port

    var box = external_call["malloc", Pointer[Int, MutUntrackedOrigin]](
        c_size_t(size_of[Int]())
    )
    assert_true(Int(box) != 0)
    box.unsafe_write(0)

    var handler = _DeferredHandler(box)
    var client = dial_tcp(
        String("127.0.0.1:") + String(port), Timeout.seconds(2)
    )
    client.write_all(
        "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )

    _tick_until_detached(server, handler, box)
    var sender_addr = box[]
    assert_true(sender_addr != 0)
    box.unsafe_write(0)

    var num_chunks = 200
    var ctx_ptr = external_call[
        "malloc", Pointer[_WorkerStreamHundredsContext, MutUntrackedOrigin]
    ](c_size_t(size_of[_WorkerStreamHundredsContext]()))
    assert_true(Int(ctx_ptr) != 0)
    ctx_ptr.unsafe_write(
        _WorkerStreamHundredsContext(
            sender_addr=sender_addr,
            num_chunks=num_chunks,
            success_count=0,
            done=False,
        )
    )

    var handle: UInt64 = 0
    var rc = external_call["pthread_create", c_int](
        Pointer(to=handle),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _worker_stream_hundreds_thread,
        ctx_ptr.unsafe_bitcast[Byte](),
    )
    assert_equal(Int(rc), 0)

    # Calling tick with a 3-second timeout will wake up promptly (~40ms)
    # when the worker thread signals wakeup_fd for start/send, rather than waiting 3 seconds.
    _ = server.tick(handler, Timeout.seconds(3))

    # Read the full chunked stream across multiple ticks
    var resp = _tick_and_read_chunked(server, handler, client, max_ticks=500)
    _join_thread(handle)

    var done = ctx_ptr[].done
    var success_count = ctx_ptr[].success_count
    external_call["free", NoneType](ctx_ptr)

    assert_true(done)
    assert_equal(success_count, num_chunks)
    assert_equal(_status_of(resp), 200)

    var raw = String(from_utf8_lossy=Span(resp))
    assert_true(raw.find("Transfer-Encoding: chunked") >= 0)
    var body_str = _body_of(resp)

    # Verify that all hundreds of chunks arrived intact and in exact order
    var last_pos = 0
    for i in range(num_chunks):
        var expected_chunk = String("event-") + String(i) + String("\n")
        var pos = body_str.find(expected_chunk)
        assert_true(pos >= last_pos)
        last_pos = pos

    # Verify connection remains valid for keep-alive request
    client.write_all(
        "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n".as_bytes(),
        Timeout.seconds(2),
    )
    var resp2 = _tick_and_read(server, handler, client)
    assert_equal(_status_of(resp2), 200)
    assert_equal(_body_of(resp2), "second-response")

    client.close()
    external_call["free", NoneType](box)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
