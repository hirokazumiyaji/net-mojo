from std.ffi import c_int, external_call
from std.time import perf_counter_ns, sleep
from std.testing import assert_raises
from net.http._detach import (
    _take_batch,
    _detach_state,
    _consume_detach_bytes,
    _release_detach_state,
    MSG_KIND_CHUNK,
    MSG_KIND_FINISH,
    MSG_KIND_ABORT,
)
from net.http.fileserver import _prepare_file, _launch_file_job
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.http import (
    Headers,
    HttpVersion,
    Request,
    ResponseWriter,
    ServeMux,
    split_path_query,
)
from net.http.fileserver import (
    FileETagMode,
    FileServer,
    FileServerConfig,
    file_server,
    serve_file,
)
from net.http._filesystem import FileSystem
from net._sys.file import _AT_FDCWD
from tests.test_http_filesystem import _Fixture
from tests.support import _count_open_fds


def _request(target: StringSlice, method: StringSlice = "GET") -> Request:
    var path, query = split_path_query(target)
    return Request(
        String(method), String(target), path^, query^, HttpVersion.http11()
    )


def _body(writer: ResponseWriter) -> String:
    return String(from_utf8_lossy=Span(writer.body))


def _mtime(
    fixture: _Fixture,
    relative: StringSlice,
    seconds: Int64 = 784111777,
    nanos: Int64 = 123456789,
) raises:
    var path = fixture.root + "/" + String(relative)
    var times: Array[Int64, 4] = [seconds, nanos, seconds, nanos]
    assert_equal(
        external_call["utimensat", c_int](
            c_int(_AT_FDCWD),
            path.as_c_string_span().ptr(),
            Pointer(to=times).unsafe_bitcast[Int64](),
            c_int(0),
        ),
        0,
    )


def test_file_server_get_metadata_and_head_representation() raises:
    var fixture = _Fixture()
    fixture.write("hello.txt", "hello file")
    _mtime(fixture, "hello.txt")
    var handler = file_server(fixture.root)
    var req = _request("/hello.txt")
    var writer = ResponseWriter(65536)
    handler.handle(req, writer)
    assert_equal(writer.status, 200)
    assert_equal(_body(writer), "hello file")
    assert_equal(
        writer.headers.get_first("Content-Type").value(),
        "text/plain; charset=utf-8",
    )
    assert_equal(writer.headers.get_first("Content-Length").value(), "10")
    assert_equal(
        writer.headers.get_first("ETag").value(), 'W/"784111777123456789-10"'
    )
    assert_equal(
        writer.headers.get_first("Last-Modified").value(),
        "Sun, 06 Nov 1994 08:49:37 GMT",
    )
    assert_equal(writer.headers.get_first("Accept-Ranges").value(), "bytes")
    var head = _request("/hello.txt", "HEAD")
    var head_writer = ResponseWriter(65536, is_head=True)
    handler.handle(head, head_writer)
    assert_equal(head_writer.status, 200)
    assert_equal(len(head_writer.body), 0)
    for name in [
        "Content-Type",
        "Content-Length",
        "ETag",
        "Last-Modified",
        "Accept-Ranges",
    ]:
        assert_equal(
            head_writer.headers.get_first(name).value(),
            writer.headers.get_first(name).value(),
        )
    _ = fixture.root


def test_method_not_found_and_file_size_limit() raises:
    var fixture = _Fixture()
    fixture.write("file", "content")
    var cfg = FileServerConfig(max_file_size=6)
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    var post = _request("/file", "POST")
    var writer = ResponseWriter(65536)
    handler.handle(post, writer)
    assert_equal(writer.status, 405)
    assert_equal(writer.headers.get_first("Allow").value(), "GET, HEAD")
    var missing = _request("/missing")
    var missing_writer = ResponseWriter(65536)
    handler.handle(missing, missing_writer)
    assert_equal(missing_writer.status, 404)
    var too_large = _request("/file")
    var large_writer = ResponseWriter(65536)
    handler.handle(too_large, large_writer)
    assert_equal(large_writer.status, 404)
    _ = fixture.root


def test_conditional_get_precedence_and_head() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "hello")
    _mtime(fixture, "file.txt")
    var handler = file_server(fixture.root)
    var req = _request("/file.txt")
    req.headers.add("If-None-Match", '"784111777123456789-5"')
    var writer = ResponseWriter(65536)
    handler.handle(req, writer)
    assert_equal(writer.status, 304)
    assert_equal(len(writer.body), 0)
    assert_false(writer.headers.get_first("Content-Length"))
    var unmatched = _request("/file.txt")
    unmatched.headers.add("If-None-Match", '"other"')
    unmatched.headers.add("If-Modified-Since", "Sun, 06 Nov 1994 08:49:37 GMT")
    var unmatched_writer = ResponseWriter(65536)
    handler.handle(unmatched, unmatched_writer)
    assert_equal(unmatched_writer.status, 200)
    var precondition = _request("/file.txt")
    precondition.headers.add("If-Match", '"784111777123456789-5"')
    var precondition_writer = ResponseWriter(65536)
    handler.handle(precondition, precondition_writer)
    assert_equal(precondition_writer.status, 412)
    var head = _request("/file.txt", "HEAD")
    head.headers.add("If-Modified-Since", "Sun, 06 Nov 1994 08:49:37 GMT")
    var head_writer = ResponseWriter(65536, is_head=True)
    handler.handle(head, head_writer)
    assert_equal(head_writer.status, 304)
    _ = fixture.root


def test_get_single_ranges_and_head_ignores_range() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "0123456789")
    var handler = file_server(fixture.root)
    for value, status, expected in [
        ("bytes=2-4", 206, "234"),
        ("bytes=-3", 206, "789"),
        ("bytes=7-", 206, "789"),
        ("bytes=0-100", 206, "0123456789"),
        ("bytes=1-2,4-5", 200, "0123456789"),
        ("items=1-2", 200, "0123456789"),
        ("bytes=10-", 416, ""),
    ]:
        var req = _request("/file.txt")
        req.headers.add("Range", String(value))
        var writer = ResponseWriter(65536)
        handler.handle(req, writer)
        assert_equal(writer.status, status)
        assert_equal(_body(writer), expected)
        if status == 416:
            assert_equal(
                writer.headers.get_first("Content-Range").value(), "bytes */10"
            )
    var head = _request("/file.txt", "HEAD")
    head.headers.add("Range", "bytes=2-4")
    var head_writer = ResponseWriter(65536, is_head=True)
    handler.handle(head, head_writer)
    assert_equal(head_writer.status, 200)
    assert_equal(head_writer.headers.get_first("Content-Length").value(), "10")
    assert_equal(len(head_writer.body), 0)
    _ = fixture.root


def test_if_range_requires_strong_etag_or_matching_date() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "0123456789")
    _mtime(fixture, "file.txt")
    var handler = file_server(fixture.root)
    for value, status in [
        ('W/"784111777123456789-10"', 200),
        ('"784111777123456789-10"', 200),
        ("Sun, 06 Nov 1994 08:49:37 GMT", 206),
        ("Sun, 06 Nov 1994 08:49:38 GMT", 200),
        ("invalid", 200),
    ]:
        var req = _request("/file.txt")
        req.headers.add("Range", "bytes=2-4")
        req.headers.add("If-Range", String(value))
        var writer = ResponseWriter(65536)
        handler.handle(req, writer)
        assert_equal(writer.status, status)
        assert_equal(_body(writer), "234" if status == 206 else "0123456789")
    _ = fixture.root


def test_directory_index_and_listing_policy() raises:
    var fixture = _Fixture()
    fixture.mkdir("index")
    fixture.write("index/index.html", "<html>index</html>")
    fixture.mkdir("empty")
    var handler = file_server(fixture.root)
    var req = _request("/index/")
    var writer = ResponseWriter(65536)
    handler.handle(req, writer)
    assert_equal(writer.status, 200)
    assert_equal(_body(writer), "<html>index</html>")
    assert_equal(
        writer.headers.get_first("Content-Type").value(),
        "text/html; charset=utf-8",
    )
    var empty = _request("/empty/")
    var empty_writer = ResponseWriter(65536)
    handler.handle(empty, empty_writer)
    assert_equal(empty_writer.status, 404)
    _ = fixture.root


def test_listing_enabled_returns_escaped_plaintext_and_bounded_names() raises:
    var fixture = _Fixture()
    fixture.mkdir("dir")
    fixture.write("dir/line\nbreak", "x")
    fixture.write("dir/tab\tname", "x")
    var cfg = FileServerConfig(allow_directory_listing=True)
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    var req = _request("/dir/")
    var writer = ResponseWriter(65536)
    handler.handle(req, writer)
    assert_equal(writer.status, 200)
    var body = _body(writer)
    assert_true(body.find("line\\nbreak\n") >= 0)
    assert_true(body.find("tab\\tname\n") >= 0)
    assert_equal(
        writer.headers.get_first("Content-Type").value(),
        "text/plain; charset=utf-8",
    )
    _ = fixture.root


def test_http_canonical_redirects_preserve_queries() raises:
    var fixture = _Fixture()
    fixture.mkdir("dir")
    fixture.write("dir/file", "x")
    var handler = file_server(fixture.root)
    for path, location in [
        ("/dir?x=1", "/dir/?x=1"),
        ("/dir/file/?x=1", "/dir/file?x=1"),
        ("//dir//file?x=1", "/dir/file?x=1"),
        ("/dir?", "/dir/?"),
    ]:
        var req = _request(path)
        var writer = ResponseWriter(65536)
        handler.handle(req, writer)
        assert_equal(writer.status, 301)
        assert_equal(writer.headers.get_first("Location").value(), location)
    _ = fixture.root


def test_path_traversal_is_refused_before_redirect_and_percent_is_literal() raises:
    var fixture = _Fixture()
    fixture.write("%2e%2e", "literal")
    var handler = file_server(fixture.root)
    for path in [
        "/../file",
        "/a/../file",
        "/./file",
        "//../file",
        "/file\x00x",
    ]:
        var req = _request(path)
        var writer = ResponseWriter(65536)
        handler.handle(req, writer)
        assert_equal(writer.status, 404)
        assert_false(writer.headers.get_first("Location"))
    var literal = _request("/%2e%2e")
    var writer = ResponseWriter(65536)
    handler.handle(literal, writer)
    assert_equal(writer.status, 200)
    assert_equal(_body(writer), "literal")
    _ = fixture.root


def test_config_etag_disable_cache_control_and_custom_index() raises:
    var fixture = _Fixture()
    fixture.mkdir("dir")
    fixture.write("dir/home.txt", "custom")
    var cfg = FileServerConfig(
        index_files=["home.txt"],
        cache_control="public, max-age=60",
        etag_mode=FileETagMode.disabled(),
    )
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    var req = _request("/dir/")
    var writer = ResponseWriter(65536)
    writer.headers.add("X-Middleware", "preserved")
    handler.handle(req, writer)
    assert_equal(writer.status, 200)
    assert_equal(_body(writer), "custom")
    assert_false(writer.headers.get_first("ETag"))
    assert_equal(
        writer.headers.get_first("Cache-Control").value(), "public, max-age=60"
    )
    assert_equal(writer.headers.get_first("X-Middleware").value(), "preserved")
    _ = fixture.root


def test_serve_file_explicit_path_and_sniff_prefix_range_reuse() raises:
    var fixture = _Fixture()
    fixture.write("asset.unknown", "<html>0123456789</html>")
    var fs = FileSystem.dir(fixture.root)
    var req = _request("/download")
    req.headers.add("Range", "bytes=6-9")
    var writer = ResponseWriter(65536)
    serve_file(req, writer, fs, "asset.unknown")
    assert_equal(writer.status, 206)
    assert_equal(_body(writer), "0123")
    assert_equal(
        writer.headers.get_first("Content-Type").value(),
        "text/html; charset=utf-8",
    )
    _ = fixture.root


def _callback(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string("callback")


def test_one_line_mux_handler_registration_and_existing_callbacks() raises:
    var fixture = _Fixture()
    fixture.write("hello.txt", "mounted")
    var mux = ServeMux()
    mux.handle("GET /static/{path...}", file_server(fixture.root))
    mux.handle("GET /callback", _callback)
    var req = _request("/static/hello.txt")
    var writer = ResponseWriter(65536)
    mux.handle(req, writer)
    assert_equal(writer.status, 200)
    assert_equal(_body(writer), "mounted")
    var callback_req = _request("/callback")
    var callback_writer = ResponseWriter(65536)
    mux.handle(callback_req, callback_writer)
    assert_equal(_body(callback_writer), "callback")
    _ = fixture.root


def test_last_modified_pre_epoch_nanosecond_uses_floor_seconds() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "x")
    _mtime(fixture, "file.txt", -1, 999999999)
    var handler = file_server(fixture.root)
    var req = _request("/file.txt")
    var writer = ResponseWriter(65536)
    handler.handle(req, writer)
    assert_equal(
        writer.headers.get_first("Last-Modified").value(),
        "Wed, 31 Dec 1969 23:59:59 GMT",
    )
    _ = fixture.root


def _drain_file(mut writer: ResponseWriter) raises -> String:
    var result = String("")
    var terminal: UInt8 = 0
    var expires = perf_counter_ns() + 5_000_000_000
    while terminal == 0 and perf_counter_ns() < expires:
        var batch = _take_batch(_detach_state(writer._detach_state_addr))
        for i in range(len(batch.messages)):
            ref message = batch.messages[i]
            if message.kind == MSG_KIND_CHUNK:
                result += String(from_utf8_lossy=Span(message.body))
                _consume_detach_bytes(
                    writer._detach_state_addr, len(message.body)
                )
        terminal = batch.terminal_kind
        sleep(0.001)
    if terminal != MSG_KIND_FINISH:
        writer._cancel_detach()
        assert_equal(terminal, MSG_KIND_FINISH)
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    writer._detach_state_addr = 0
    return result^


def test_worker_streaming_respects_tiny_queue_and_selected_range() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "0123456789abcdef")
    var cfg = FileServerConfig(max_in_memory_body=0)
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    var req = _request("/file.txt")
    req.headers.add("Range", "bytes=2-13")
    var writer = ResponseWriter(0, queue_limit=3)
    handler.handle(req, writer)
    assert_true(writer.is_detached())
    assert_equal(_drain_file(writer), "23456789abcd")
    _ = handler
    _ = fixture.root


def test_large_serve_file_thread_outlives_helper_and_filesystem() raises:
    var fixture = _Fixture()
    var expected = String("")
    for _ in range(5000):
        expected += "0123456789abcdef"
    fixture.write("large.txt", expected)
    var req = _request("/download")
    var writer = ResponseWriter(0, queue_limit=1024)
    serve_file(req, writer, FileSystem.dir(fixture.root), "large.txt")
    assert_true(writer.is_detached())
    assert_equal(_drain_file(writer), expected)
    _ = fixture.root


def test_file_growth_does_not_extend_selected_representation() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "original")
    var fs = FileSystem.dir(fixture.root)
    var cfg = FileServerConfig(max_in_memory_body=0)
    var req = _request("/file.txt")
    var writer = ResponseWriter(0)
    var job = _prepare_file(req, writer, fs.open("file.txt"), "file.txt", cfg)
    fixture.write("file.txt", "original-extra")
    var sender = writer.detach()
    job.value().run(sender)
    assert_equal(_drain_file(writer), "original")
    _ = fixture.root


def test_truncated_stream_aborts_after_metadata() raises:
    var fixture = _Fixture()
    var content = String("")
    for _ in range(1024):
        content += "x"
    fixture.write("file.txt", content)
    var fs = FileSystem.dir(fixture.root)
    var cfg = FileServerConfig(max_in_memory_body=0)
    var req = _request("/file.txt")
    var writer = ResponseWriter(0)
    var job = _prepare_file(req, writer, fs.open("file.txt"), "file.txt", cfg)
    fixture.write("file.txt", "")
    var sender = writer.detach()
    var failed = False
    try:
        job.value().run(sender)
    except:
        failed = True
        sender.abort()
    var batch = _take_batch(_detach_state(writer._detach_state_addr))
    assert_true(failed)
    assert_equal(batch.terminal_kind, MSG_KIND_ABORT)
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    writer._detach_state_addr = 0
    _ = fixture.root


def test_configuration_rejects_unbounded_or_invalid_inputs() raises:
    for name in ["", ".", "..", "/index", "a/b", "index\x00.html"]:
        with assert_raises():
            _ = FileServerConfig(index_files=[String(name)])
    with assert_raises():
        _ = FileServerConfig(max_in_memory_body=-1)
    with assert_raises():
        _ = FileServerConfig(max_file_size=-1)
    with assert_raises():
        _ = FileServerConfig(workers=0)
    with assert_raises():
        _ = FileServerConfig(queue_limit=-1)
    with assert_raises():
        _ = FileServerConfig(cache_control="bad\r\nvalue")


def test_mounted_directory_redirect_retains_mount_and_query() raises:
    var fixture = _Fixture()
    fixture.mkdir("dir")
    var mux = ServeMux()
    mux.handle("GET /static/{path...}", file_server(fixture.root))
    var req = _request("/static/dir?cache=1")
    var writer = ResponseWriter(65536)
    mux.handle(req, writer)
    assert_equal(writer.status, 301)
    assert_equal(
        writer.headers.get_first("Location").value(), "/static/dir/?cache=1"
    )
    _ = fixture.root


def test_symlink_policy_and_initial_response_body() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "inside")
    fixture.link("link.txt", "file.txt")
    var handler = file_server(fixture.root)
    var req = _request("/link.txt")
    var writer = ResponseWriter(65536)
    handler.handle(req, writer)
    assert_equal(writer.status, 404)
    var followed = FileServer(FileSystem.dir(fixture.root, True))
    var result = ResponseWriter(65536)
    result.write_string("prior")
    result.headers.add("Content-Type", "old")
    followed.handle(req, result)
    assert_equal(result.status, 200)
    assert_equal(_body(result), "inside")
    assert_equal(len(result.headers.get_all("Content-Type")), 1)
    _ = fixture.root


def _fail_file_thread(
    thread: Pointer[UInt64, MutUntrackedOrigin],
    context: Pointer[Byte, MutUntrackedOrigin],
) -> Int:
    return 11


def test_thread_start_failure_returns_clean_500() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "original")
    var fs = FileSystem.dir(fixture.root)
    var cfg = FileServerConfig(max_in_memory_body=0)
    var req = _request("/file.txt")
    var writer = ResponseWriter(0)
    var job = _prepare_file(req, writer, fs.open("file.txt"), "file.txt", cfg)
    _launch_file_job[_fail_file_thread](writer, job.take())
    var batch = _take_batch(_detach_state(writer._detach_state_addr))
    assert_equal(len(batch.messages), 1)
    assert_equal(batch.messages[0].status, 500)
    assert_equal(len(batch.messages[0].headers), 0)
    _release_detach_state(writer._detach_state_addr, from_sender=False)
    writer._detach_state_addr = 0
    _ = fixture.root


def test_cancelled_worker_releases_without_waiting_for_queue_credit() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "0123456789")
    var cfg = FileServerConfig(max_in_memory_body=0)
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    var req = _request("/file.txt")
    var writer = ResponseWriter(0, queue_limit=1)
    handler.handle(req, writer)
    sleep(0.01)
    writer._cancel_detach()
    var before = perf_counter_ns()
    _ = handler^
    assert_true(perf_counter_ns() - before < 1_000_000_000)
    _ = fixture.root


def test_refused_worker_admission_returns_503_and_closes_file_descriptors() raises:
    var fixture = _Fixture()
    fixture.write("file.txt", "original")
    var cfg = FileServerConfig(max_in_memory_body=0, queue_limit=0)
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    var req = _request("/file.txt")
    var before = _count_open_fds()
    for _ in range(100):
        var writer = ResponseWriter(0)
        handler.handle(req, writer)
        assert_true(writer.is_detached())
        var batch = _take_batch(_detach_state(writer._detach_state_addr))
        assert_equal(len(batch.messages), 1)
        assert_equal(batch.messages[0].status, 503)
        assert_equal(
            batch.messages[0].headers.get_first("Retry-After").value(), "1"
        )
        _release_detach_state(writer._detach_state_addr, from_sender=False)
        writer._detach_state_addr = 0
    assert_equal(_count_open_fds(), before)
    _ = handler
    _ = fixture.root


def test_backslash_paths_cannot_redirect_to_another_origin() raises:
    var fixture = _Fixture()
    var handler = file_server(fixture.root)
    for path in ["//\\evil.example/path?x=1", "/\\evil.example/path", "/a\\b/"]:
        var req = _request(path)
        var writer = ResponseWriter(65536)
        handler.handle(req, writer)
        assert_equal(writer.status, 404)
        assert_false(writer.headers.get_first("Location"))
    _ = fixture.root


def test_directory_listing_replaces_existing_body_for_get_and_head() raises:
    var fixture = _Fixture()
    fixture.mkdir("dir")
    fixture.write("dir/a", "x")
    var cfg = FileServerConfig(allow_directory_listing=True)
    var handler = FileServer(FileSystem.dir(fixture.root), cfg^)
    for method in ["GET", "HEAD"]:
        var req = _request("/dir/", method)
        var writer = ResponseWriter(65536, is_head=method == "HEAD")
        writer.write_string("prior")
        handler.handle(req, writer)
        assert_equal(writer.status, 200)
        assert_equal(writer.headers.get_first("Content-Length").value(), "2")
        assert_equal(_body(writer), "a\n" if method == "GET" else "")
    _ = fixture.root


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
