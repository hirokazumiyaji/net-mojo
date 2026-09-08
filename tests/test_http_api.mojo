from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.error import NetErrorKind
from net.http import (
    Handler,
    Headers,
    HttpError,
    HttpVersion,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
    has_body_for_status,
    split_path_query,
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
    assert_equal(String(HttpVersion(value=9)), "HTTP/unknown")
    assert_true(HttpVersion.http11().is_supported())
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
    assert_equal(config.max_accept_per_tick, 64)
    assert_equal(config.max_bytes_per_tick, 65536)
    assert_equal(config.max_requests_per_tick, 16)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
