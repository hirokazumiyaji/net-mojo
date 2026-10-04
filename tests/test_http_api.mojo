from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns

from net import Timeout
from net._actor import PthreadMutex
from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    HttpError,
    HttpVersion,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
    has_body_for_status,
    maybe_inject_alt_svc,
    split_path_query,
)
from net.http._encoder import encode_response
from net.http._buffer import BufferBudget, SharedBufferBudget, _reserve_capacity
from tests.support import _join_thread


def test_shared_budget_copy_keeps_one_exact_admission_counter() raises:
    var owner = SharedBufferBudget(16)
    var handle = owner.copy()
    assert_true(owner.try_reserve(7))
    assert_false(handle.try_reserve(10))
    assert_false(handle.try_reserve(-1))
    assert_equal(handle.used(), 7)
    assert_equal(handle.remaining(), 9)
    assert_true(handle.try_reserve(9))
    assert_equal(owner.used(), 16)
    handle.release(9)
    assert_equal(owner.remaining(), 9)
    owner.release(7)
    assert_equal(handle.used(), 0)
    assert_equal(handle.total(), 16)


def _surviving_budget_handle() -> SharedBufferBudget:
    var owner = SharedBufferBudget(16)
    _ = owner.try_reserve(7)
    return owner.copy()


def test_shared_budget_handle_survives_creator_destruction() raises:
    var handle = _surviving_budget_handle()
    assert_equal(handle.used(), 7)
    handle.release(7)
    assert_true(handle.try_reserve(16))
    assert_false(handle.try_reserve(1))
    handle.release(16)
    assert_equal(handle.remaining(), 16)


def test_shared_budget_growth_preserves_foreign_charge_and_peak() raises:
    for total in [21, 25]:
        var budget = SharedBufferBudget(total)
        var foreign = budget.copy()
        assert_true(foreign.try_reserve(5))
        var bytes = List[Byte]()
        var reservation = 0
        assert_true(_reserve_capacity(bytes, budget, 8, reservation))
        bytes.append(42)
        if total == 21:
            assert_false(_reserve_capacity(bytes, budget, 9, reservation))
            assert_equal(bytes.capacity(), 8)
            assert_equal(foreign.used(), 13)
        else:
            assert_true(_reserve_capacity(bytes, budget, 9, reservation))
            assert_equal(bytes.capacity(), 12)
            assert_equal(foreign.used(), 17)
        assert_equal(bytes[0], 42)
        var capacity = bytes.capacity()
        _ = bytes^
        budget.release(capacity)
        assert_equal(foreign.used(), 5)
        foreign.release(5)
        assert_equal(budget.used(), 0)


struct _BudgetWorker:
    var budget: SharedBufferBudget
    var gate: PthreadMutex
    var ready: Bool
    var start: Bool
    var admitted: Int
    var timed_out: Bool

    def __init__(out self, var budget: SharedBufferBudget):
        self.budget = budget^
        self.gate = PthreadMutex._uninitialized()
        self.ready = False
        self.start = False
        self.admitted = 0
        self.timed_out = False

    def __deinit__(deinit self):
        self.gate.destroy()


def _wait_budget_flag(mut worker: _BudgetWorker, start: Bool) -> Bool:
    var deadline = perf_counter_ns() + 2_000_000_000
    while True:
        worker.gate.lock()
        var ready = worker.ready
        if start:
            ready = worker.start
        worker.gate.unlock()
        if ready:
            return True
        if perf_counter_ns() >= deadline:
            return False


def _budget_worker(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var worker = arg.unsafe_bitcast[_BudgetWorker]()
    worker[].gate.lock()
    worker[].ready = True
    worker[].gate.unlock()
    if not _wait_budget_flag(worker[], True):
        worker[].timed_out = True
        return arg
    for _ in range(8192):
        if worker[].budget.try_reserve(1):
            worker[].admitted += 1
    return arg


def test_shared_budget_pthread_and_owner_cannot_over_admit() raises:
    var owner = SharedBufferBudget(97)
    var worker = _BudgetWorker(owner.copy())
    worker.gate._initialize()
    var thread: UInt64 = 0
    var result = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _budget_worker,
        Pointer(to=worker).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(result), 0)
    var ready = _wait_budget_flag(worker, False)
    worker.gate.lock()
    worker.start = True
    worker.gate.unlock()
    var admitted = 0
    for _ in range(8192):
        if owner.try_reserve(1):
            admitted += 1
    _join_thread(thread)
    assert_true(ready)
    assert_false(worker.timed_out)
    assert_equal(admitted + worker.admitted, 97)
    assert_equal(owner.used(), 97)
    assert_false(owner.try_reserve(1))
    owner.release(admitted)
    worker.budget.release(worker.admitted)
    assert_equal(owner.used(), 0)


def test_writer_body_workspace_clamps_capacity_to_growth_peak() raises:
    var writer = ResponseWriter(32)
    writer._set_body_budget(20)
    writer.write_string("12345678")
    writer.write_string("9")
    assert_equal(writer.body.capacity(), 12)
    assert_equal(writer._body_budget.value().used, 12)
    assert_equal(len(writer.body), 9)


def test_writer_body_workspace_rejects_peak_without_changing_body() raises:
    var writer = ResponseWriter(32)
    writer._set_body_budget(16)
    writer.write_string("12345678")
    var rejected = False
    try:
        writer.write_string("9")
    except e:
        assert_equal(e.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)
    writer.write_string("")
    assert_equal(writer.body.capacity(), 8)
    assert_equal(writer._body_budget.value().used, 8)
    assert_equal(len(writer.body), 8)
    assert_equal(writer.body[7], Byte(ord("8")))


def test_writer_span_move_and_drop_preserve_workspace_accounting() raises:
    var writer = ResponseWriter(32)
    writer._set_body_budget(24)
    writer.write_string("12345678")
    var moved = writer^
    moved.write(String("9").as_bytes())
    assert_equal(moved._body_budget.value().total, 24)
    assert_equal(moved._body_budget.value().used, 16)
    assert_equal(moved.body.capacity(), 16)
    moved._drop_body()
    assert_equal(moved.body.capacity(), 0)
    assert_equal(moved._body_budget.value().used, 0)


def test_writer_reconciles_direct_capacity_before_supported_growth() raises:
    var writer = ResponseWriter(32)
    writer._set_body_budget(24)
    writer.body = List[Byte](length=8, fill=42)
    writer.write_string("9")
    assert_equal(writer._body_budget.value().used, 16)
    writer.body = List[Byte](length=4, fill=43)
    assert_true(writer._reconcile_body_budget())
    assert_equal(writer._body_budget.value().used, 4)


def test_writer_rejects_direct_capacity_outside_workspace() raises:
    var writer = ResponseWriter(32)
    writer._set_body_budget(16)
    writer.body.reserve(20)
    assert_false(writer._reconcile_body_budget())
    assert_equal(writer._body_budget.value().used, 0)
    writer._drop_body()
    assert_equal(writer.body.capacity(), 0)


def test_standalone_writer_keeps_exact_reserve_behavior() raises:
    var writer = ResponseWriter(32)
    writer.write_string("12345678")
    writer.write_string("9")
    assert_false(Bool(writer._body_budget))
    assert_equal(writer.body.capacity(), 9)


def test_receive_growth_charges_capacity_and_old_new_peak() raises:
    var budget = BufferBudget(24)
    var bytes = List[Byte]()
    var reserved = 0
    assert_true(_reserve_capacity(bytes, budget, 8, reserved))
    bytes.extend(List[Byte](length=8, fill=42))
    assert_equal(bytes.capacity(), 8)
    assert_equal(budget.used, 8)
    assert_true(_reserve_capacity(bytes, budget, 9, reserved))
    assert_equal(bytes.capacity(), 16)
    assert_equal(budget.used, 16)
    assert_equal(len(bytes), 8)
    assert_equal(bytes[7], 42)


def test_receive_growth_clamps_to_peak_available_capacity() raises:
    var budget = BufferBudget(20)
    var bytes = List[Byte]()
    var reserved = 0
    assert_true(_reserve_capacity(bytes, budget, 8, reserved))
    assert_true(_reserve_capacity(bytes, budget, 9, reserved))
    assert_equal(bytes.capacity(), 12)
    assert_equal(budget.used, 12)


def test_receive_growth_rejects_final_fit_without_peak_space() raises:
    var budget = BufferBudget(16)
    var bytes = List[Byte]()
    var reserved = 0
    assert_true(_reserve_capacity(bytes, budget, 8, reserved))
    bytes.append(42)
    assert_false(_reserve_capacity(bytes, budget, 9, reserved))
    assert_equal(bytes.capacity(), 8)
    assert_equal(budget.used, 8)
    assert_equal(len(bytes), 1)
    assert_equal(bytes[0], 42)


def test_receive_growth_consumes_admission_and_releases_old_capacity() raises:
    var budget = BufferBudget(24)
    var bytes = List[Byte]()
    var reserved = 0
    assert_true(_reserve_capacity(bytes, budget, 8, reserved))
    assert_true(budget.try_reserve(12))
    reserved = 12
    assert_true(_reserve_capacity(bytes, budget, 9, reserved))
    assert_equal(bytes.capacity(), 16)
    assert_equal(reserved, 0)
    assert_equal(budget.used, 16)


def test_receive_growth_preserves_unused_admission() raises:
    var budget = BufferBudget(40)
    var bytes = List[Byte]()
    var reserved = 0
    assert_true(_reserve_capacity(bytes, budget, 8, reserved))
    assert_true(budget.try_reserve(20))
    reserved = 20
    assert_true(_reserve_capacity(bytes, budget, 9, reserved))
    assert_equal(bytes.capacity(), 16)
    assert_equal(reserved, 4)
    assert_equal(budget.used, 20)
    assert_true(_reserve_capacity(bytes, budget, 10, reserved))
    assert_equal(reserved, 4)
    assert_equal(budget.used, 20)


def test_receive_failed_growth_preserves_admission() raises:
    var budget = BufferBudget(16)
    var bytes = List[Byte]()
    var reserved = 0
    assert_true(_reserve_capacity(bytes, budget, 8, reserved))
    assert_true(budget.try_reserve(8))
    reserved = 8
    assert_false(_reserve_capacity(bytes, budget, 9, reserved))
    assert_equal(bytes.capacity(), 8)
    assert_equal(reserved, 8)
    assert_equal(budget.used, 16)


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
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write_string("not found")


struct _EchoPathHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        # Copies out what it needs: the request views die with the call.
        var path_copy = String(req.path)
        var query_copy = String(req.query)
        writer.set_status(200)
        writer.write_string(String(path_copy + "?" + query_copy))


def test_handler_dispatches_on_method_and_path() raises:
    var handler = _HelloHandler()
    var req = Request(
        String("GET"),
        String("/hello"),
        String("/hello"),
        String(""),
        HttpVersion.http11(),
    )
    var writer = ResponseWriter(1024)
    handler.handle(req^, writer)
    assert_equal(writer.status, 200)
    var content_type = writer.headers.get_first("content-type")
    assert_true(Bool(content_type))
    assert_equal(content_type.value(), "text/plain")
    assert_equal(len(writer.body), 5)


def test_unhandled_path_returns_404() raises:
    var handler = _HelloHandler()
    var req = Request(
        String("GET"),
        String("/missing"),
        String("/missing"),
        String(""),
        HttpVersion.http11(),
    )
    var writer = ResponseWriter(1024)
    handler.handle(req^, writer)
    assert_equal(writer.status, 404)


def test_request_views_are_copied_not_retained() raises:
    var handler = _EchoPathHandler()
    var req = Request(
        String("GET"),
        String("/a/b?x=1&y=2"),
        String("/a/b"),
        String("x=1&y=2"),
        HttpVersion.http11(),
    )
    var writer = ResponseWriter(1024)
    handler.handle(req^, writer)
    assert_equal(writer.status, 200)
    # "/a/b?x=1&y=2" is 12 bytes; the writer owns the copy.
    assert_equal(len(writer.body), 12)


def test_response_writer_owns_copies_of_handler_locals() raises:
    var req = Request(
        String("GET"),
        String("/hello"),
        String("/hello"),
        String(""),
        HttpVersion.http11(),
    )
    var writer = ResponseWriter(1024)
    # A short-lived handler-local string is copied into the writer;
    # dropping it after the call must not affect the buffered bytes.
    var local = String("abc")
    writer.write_string(local)
    local = String("replaced")
    assert_equal(local, "replaced")
    assert_equal(len(writer.body), 3)
    assert_equal(writer.body[0], Byte(ord("a")))
    assert_equal(writer.body[2], Byte(ord("c")))
    assert_equal(req.path, "/hello")


def test_response_body_limit_is_enforced() raises:
    var writer = ResponseWriter(4)
    writer.write_string("ab")
    assert_equal(len(writer.body), 2)
    var rejected = False
    try:
        writer.write_string("cde")
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)
    assert_equal(len(writer.body), 2)


def test_no_body_statuses_have_no_frame_body() raises:
    assert_false(has_body_for_status(200, True))
    assert_false(has_body_for_status(204, False))
    assert_false(has_body_for_status(205, False))
    assert_false(has_body_for_status(304, False))
    assert_false(has_body_for_status(100, False))
    assert_true(has_body_for_status(200, False))
    assert_true(has_body_for_status(404, False))


def test_version_rendering_distinguishes_unsupported() raises:
    assert_equal(String(HttpVersion.http10()), "HTTP/1.0")
    assert_equal(String(HttpVersion.http11()), "HTTP/1.1")
    assert_equal(String(HttpVersion.http2()), "HTTP/2")
    assert_equal(String(HttpVersion.http3()), "HTTP/3")
    assert_equal(String(HttpVersion(value=9)), "HTTP/unknown")
    assert_true(HttpVersion.http11().is_supported())
    assert_true(HttpVersion.http2().is_supported())
    assert_true(HttpVersion.http3().is_supported())
    assert_false(HttpVersion.http10().is_supported())
    assert_false(HttpVersion(value=9).is_supported())


def test_headers_are_case_insensitive_with_duplicates() raises:
    var headers = Headers()
    headers.add(String("Content-Type"), String("text/plain"))
    headers.add(String("content-type"), String("charset=x"))
    headers.add(String("X-Custom"), String("1"))
    assert_equal(len(headers), 3)
    assert_equal(headers.count("CONTENT-TYPE"), 2)
    var first = headers.get_first("Content-Type")
    assert_true(Bool(first))
    assert_equal(first.value(), "text/plain")
    var all = headers.get_all("cOnTeNt-TyPe")
    assert_equal(len(all), 2)
    # Values are enumerated separately, never comma-joined.
    assert_equal(all[0], "text/plain")
    assert_equal(all[1], "charset=x")


def test_header_injection_is_rejected() raises:
    var headers = Headers()
    var rejected = False
    try:
        headers.add(String("X-Bad"), String("a\r\nInjected: 1"))
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)
    assert_equal(len(headers), 0)


def _assert_add_rejected(var name: String, var value: String) raises:
    var headers = Headers()
    var rejected = False
    try:
        headers.add(name^, value^)
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)
    assert_equal(len(headers), 0)


def _string_with_byte(prefix: String, byte: Byte, suffix: String) -> String:
    var raw = List[Byte]()
    var head = prefix.as_bytes()
    for i in range(len(head)):
        raw.append(head[i])
    raw.append(byte)
    var tail = suffix.as_bytes()
    for i in range(len(tail)):
        raw.append(tail[i])
    return String(from_utf8_lossy=Span(raw))


def test_header_names_must_be_valid_tokens() raises:
    _assert_add_rejected(String("Bad Header"), String("1"))
    _assert_add_rejected(String("Bad:Header"), String("1"))
    _assert_add_rejected(String("Bad\tHeader"), String("1"))
    _assert_add_rejected(String(""), String("1"))
    _assert_add_rejected(
        _string_with_byte(String("X-Bad"), Byte(127), String("")), String("1")
    )


def test_header_values_reject_control_bytes() raises:
    _assert_add_rejected(
        String("X-Bad"), _string_with_byte(String("a"), Byte(0), String("b"))
    )
    _assert_add_rejected(
        String("X-Bad"), _string_with_byte(String("a"), Byte(1), String("b"))
    )
    _assert_add_rejected(
        String("X-Bad"),
        _string_with_byte(String("a"), Byte(127), String("b")),
    )
    # HTAB and SP remain legal field-value bytes.
    var headers = Headers()
    headers.add(String("X-Ok"), String("a\tb c"))
    assert_equal(len(headers), 1)


def test_header_value_span_borrows_storage_and_owned_copy_survives_clear() raises:
    var headers = Headers()
    var raw: Array[Byte, 3] = [97, 128, 255]
    headers.add_bytes(String("X-Bin"), Span(raw))
    var owned = headers.value_bytes_at(0)
    owned[0] = 42
    var view = headers._value_bytes_span(0)
    assert_equal(len(view), 3)
    assert_equal(Int(view.unsafe_ptr()), Int(headers._values[0].unsafe_ptr()))
    assert_equal(view[0], 97)
    assert_equal(view[1], 128)
    assert_equal(view[2], 255)
    assert_true(Int(view.unsafe_ptr()) != Int(owned.unsafe_ptr()))
    headers.clear()
    assert_equal(len(owned), 3)
    assert_equal(owned[0], 42)
    assert_equal(owned[1], 128)
    assert_equal(owned[2], 255)


def test_header_values_preserve_wire_bytes() raises:
    # Legal obs-text bytes have no UTF-8 decoding: they must survive
    # storage exactly and reappear on the wire unchanged.
    var headers = Headers()
    var raw = List[Byte]()
    raw.append(Byte(ord("a")))
    raw.append(Byte(128))
    raw.append(Byte(ord("b")))
    headers.add_bytes(String("X-Bin"), Span(raw))
    assert_equal(len(headers), 1)
    var stored = headers.value_bytes_at(0)
    assert_equal(len(stored), 3)
    assert_equal(stored[0], Byte(ord("a")))
    assert_equal(stored[1], Byte(128))
    assert_equal(stored[2], Byte(ord("b")))
    assert_equal(headers.value_byte_length(0), 3)
    var found = headers.get_first("x-bin")
    assert_true(Bool(found))


def test_path_query_split_has_no_percent_decoding() raises:
    var path, query = split_path_query("/a%2Fb?x=%41")
    assert_equal(path, "/a%2Fb")
    assert_equal(query, "x=%41")
    var bare, empty = split_path_query("/plain")
    assert_equal(bare, "/plain")
    assert_equal(empty, "")


def test_server_config_defaults_match_design_table() raises:
    var config = ServerConfig.default()
    assert_equal(config.max_connections, 10000)
    assert_equal(config.quic_max_transport_memory_bytes, 2621440000)
    assert_equal(config.max_http2_streams_per_connection, 100)
    assert_equal(config.max_request_line, 8192)
    assert_equal(config.max_headers_bytes, 32768)
    assert_equal(config.max_headers_count, 100)
    assert_equal(config.max_body_bytes, 1048576)
    assert_equal(config.max_chunk_metadata, 65536)
    assert_equal(config.max_trailer_bytes, 8192)
    assert_equal(config.max_trailer_count, 32)
    assert_equal(config.max_response_body, 1048576)
    assert_equal(config.max_response_headers_bytes, 32768)
    assert_equal(config.max_response_headers_count, 100)
    assert_equal(config.total_buffer_budget, 268435456)
    assert_equal(config.tls_handshake_timeout, Timeout.seconds(10))
    assert_equal(config.detached_response_timeout, Timeout.seconds(30))
    assert_equal(config.stream_queue_limit, 1048576)
    assert_equal(config.stream_idle_timeout, Timeout.seconds(300))
    assert_equal(config.max_accept_per_tick, 64)
    assert_equal(config.max_bytes_per_tick, 65536)
    assert_equal(config.max_requests_per_tick, 16)
    assert_equal(config.hpack_library_path, String("build/http2/libnet_hpack"))
    assert_equal(config.alt_svc, String(""))


def test_alt_svc_injects_when_configured() raises:
    var writer = ResponseWriter(1024)
    writer.write_string("ok")
    maybe_inject_alt_svc(writer, String('h3=":8443"; ma=86400'))
    var found = writer.headers.get_first("Alt-Svc")
    assert_true(Bool(found))
    assert_equal(found.value(), String('h3=":8443"; ma=86400'))
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = String(from_utf8_lossy=Span(wire))
    assert_true(text.find('Alt-Svc: h3=":8443"; ma=86400\r\n') >= 0)


def test_alt_svc_absent_when_disabled() raises:
    var writer = ResponseWriter(1024)
    writer.write_string("ok")
    maybe_inject_alt_svc(writer, String(""))
    assert_false(Bool(writer.headers.get_first("Alt-Svc")))
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var text = String(from_utf8_lossy=Span(wire))
    assert_true(text.find("Alt-Svc:") < 0)


def test_alt_svc_handler_supplied_wins() raises:
    var writer = ResponseWriter(1024)
    writer.headers.add(String("Alt-Svc"), String('h3=":9443"; ma=60'))
    writer.write_string("ok")
    maybe_inject_alt_svc(writer, String('h3=":8443"; ma=86400'))
    var found = writer.headers.get_first("Alt-Svc")
    assert_true(Bool(found))
    assert_equal(found.value(), String('h3=":9443"; ma=60'))
    assert_equal(writer.headers.count("Alt-Svc"), 1)


def test_control_shutdown_is_idempotent() raises:
    var control = ServerControl()
    assert_false(control.is_shutdown_requested())
    control.request_shutdown()
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()
    assert_true(control.is_shutdown_requested())


def test_control_after_exit_is_noop() raises:
    var control = ServerControl()
    control.mark_exited()
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()
    assert_true(control.is_shutdown_requested())


def test_server_owns_control_and_config() raises:
    var config = ServerConfig.default()
    var server = Server(config^)
    assert_false(server.is_shutdown_requested())
    server.request_shutdown()
    assert_true(server.is_shutdown_requested())
    assert_equal(server.config.max_connections, 10000)


def test_http_error_status_mapping() raises:
    var bad = HttpError.bad_request(String("bad token"))
    assert_equal(bad.status, 400)
    assert_true(bad.should_close)
    var too_large = HttpError.payload_too_large(String("body"))
    assert_equal(too_large.status, 413)
    var too_long = HttpError.uri_too_long(String("target"))
    assert_equal(too_long.status, 414)
    var header_big = HttpError.header_too_large(String("headers"))
    assert_equal(header_big.status, 431)
    var version = HttpError.version_not_supported(String("http/2"))
    assert_equal(version.status, 505)
    var failed = HttpError.expectation_failed(String("expect"))
    assert_equal(failed.status, 417)
    var internal = HttpError.internal(String("handler"))
    assert_equal(internal.status, 500)
    var busy = HttpError.unavailable(String("budget"))
    assert_equal(busy.status, 503)


def test_response_writer_detach_api() raises:
    var writer = ResponseWriter(1024)
    assert_false(writer.is_detached())
    var sender = writer.detach()
    assert_true(writer.is_detached())
    assert_true(sender.is_active())
    assert_false(sender.is_cancelled())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
