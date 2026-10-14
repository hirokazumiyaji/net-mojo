from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)

from net.http import (
    CompressionConfig,
    CompressionHandler,
    Handler,
    Headers,
    HttpVersion,
    Request,
    ResponseWriter,
)
from net.http._buffer import SharedBufferBudget


@fieldwise_init
struct _BodyHandler(Handler):
    var body: List[Byte]
    var status: Int
    var headers: Headers

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(self.status)
        writer.headers.add("X-Method", req.method)
        for i in range(len(self.headers)):
            var value = self.headers.value_bytes_at(i)
            writer.headers.add_bytes(self.headers.name_at(i), Span(value))
        writer.write(Span(self.body))


def _body_handler() raises -> _BodyHandler:
    var headers = Headers()
    headers.add("Content-Type", "text/plain; charset=utf-8")
    return _BodyHandler(List[Byte](length=8192, fill=97), 200, headers^)


def _request(
    method: StringSlice = "GET", path: StringSlice = "/"
) raises -> Request:
    var req = Request(
        String(method), String(path), String(path), "", HttpVersion.http11()
    )
    req.headers.add("Accept-Encoding", "gzip")
    return req^


def _gzip(var inner: _BodyHandler) raises -> CompressionHandler[_BodyHandler]:
    return CompressionHandler[_BodyHandler](
        inner^,
        CompressionConfig.default(),
        Optional[String](String("build/compression/libnet_zlib")),
    )


def test_buffered_gzip_replaces_body_and_stale_length() raises:
    var inner = _body_handler()
    inner.headers.add("Content-Length", "8192")
    var app = _gzip(inner^)
    var req = _request()
    var writer = ResponseWriter(16384)
    app.handle(req, writer)
    assert_equal(writer.headers.get_first("Content-Encoding").value(), "gzip")
    assert_equal(writer.headers.get_first("X-Method").value(), "GET")
    assert_equal(writer.headers.count("Content-Length"), 0)
    assert_equal(writer.headers.get_first("Vary").value(), "Accept-Encoding")
    assert_true(len(writer.body) < 8192)
    assert_equal(writer.body[0], Byte(0x1F))
    assert_equal(writer.body[1], Byte(0x8B))


def test_vary_merge_preserves_existing_values_and_tokens() raises:
    for value in ["Origin", "Origin, aCcEpT-EnCoDiNg", "*"]:
        var inner = _body_handler()
        inner.headers.add("Vary", value)
        var app = _gzip(inner^)
        var req = _request()
        var writer = ResponseWriter(16384)
        app.handle(req, writer)
        assert_equal(writer.headers.get_first("Vary").value(), value)
        assert_equal(
            writer.headers.count("Vary"), 2 if value == "Origin" else 1
        )


def test_qzero_identity_keeps_body_and_adds_vary() raises:
    var app = _gzip(_body_handler())
    var req = Request("GET", "/", "/", "", HttpVersion.http11())
    req.headers.add("Accept-Encoding", "gzip;q=0, *")
    var writer = ResponseWriter(16384)
    app.handle(req, writer)
    assert_equal(len(writer.body), 8192)
    assert_equal(writer.headers.count("Content-Encoding"), 0)
    assert_equal(writer.headers.get_first("Vary").value(), "Accept-Encoding")


def test_multiple_accept_encoding_fields_are_negotiated() raises:
    var app = _gzip(_body_handler())
    var req = Request("GET", "/", "/", "", HttpVersion.http11())
    req.headers.add("Accept-Encoding", "deflate")
    req.headers.add("Accept-Encoding", "gzip")
    var writer = ResponseWriter(16384)
    app.handle(req, writer)
    assert_equal(writer.headers.get_first("Content-Encoding").value(), "gzip")


def test_head_and_bodyless_status_skip_transform() raises:
    for status in [101, 204, 205, 304]:
        var inner = _body_handler()
        inner.status = status
        var app = _gzip(inner^)
        var req = _request()
        var writer = ResponseWriter(16384)
        app.handle(req, writer)
        assert_equal(writer.headers.count("Content-Encoding"), 0)
        assert_equal(len(writer.body), 8192)
    var app = _gzip(_body_handler())
    var req = _request("HEAD")
    var writer = ResponseWriter(16384, is_head=True)
    app.handle(req, writer)
    assert_equal(writer.headers.count("Content-Encoding"), 0)
    assert_equal(len(writer.body), 8192)


def test_small_partial_and_preencoded_skip_transform() raises:
    var req = _request()
    var small = _body_handler()
    small.body = List[Byte](length=17, fill=97)
    var small_app = _gzip(small^)
    var small_writer = ResponseWriter(16384)
    small_app.handle(req, small_writer)
    assert_equal(len(small_writer.body), 17)
    assert_equal(small_writer.headers.count("Content-Encoding"), 0)
    var partial = _body_handler()
    partial.status = 206
    var partial_app = _gzip(partial^)
    var partial_writer = ResponseWriter(16384)
    partial_app.handle(req, partial_writer)
    assert_equal(partial_writer.headers.count("Content-Encoding"), 0)
    var encoded = _body_handler()
    encoded.headers.add("Content-Encoding", "br")
    var encoded_app = _gzip(encoded^)
    var encoded_writer = ResponseWriter(16384)
    encoded_app.handle(req, encoded_writer)
    assert_equal(
        encoded_writer.headers.get_first("Content-Encoding").value(), "br"
    )
    assert_equal(len(encoded_writer.body), 8192)


def test_compressed_media_and_extensions_skip_transform() raises:
    for content_type in [
        "IMAGE/PNG",
        "video/mp4",
        "audio/mpeg",
        "application/zip; x=y",
        "font/woff2",
    ]:
        var inner = _body_handler()
        inner.headers = Headers()
        inner.headers.add("Content-Type", content_type)
        var app = _gzip(inner^)
        var req = _request()
        var writer = ResponseWriter(16384)
        app.handle(req, writer)
        assert_equal(writer.headers.count("Content-Encoding"), 0)
    for path in ["/a.gz", "/a.BR", "/a.zst"]:
        var app = _gzip(_body_handler())
        var req = _request(path=path)
        var writer = ResponseWriter(16384)
        app.handle(req, writer)
        assert_equal(writer.headers.count("Content-Encoding"), 0)


def test_raw_header_bytes_survive_transform() raises:
    var inner = _body_handler()
    var raw: List[Byte] = [Byte(255), Byte(128)]
    inner.headers.add_bytes("X-Raw", Span(raw))
    var app = _gzip(inner^)
    var req = _request()
    var writer = ResponseWriter(16384)
    app.handle(req, writer)
    var actual = writer.headers.value_bytes_at(2)
    assert_equal(actual, raw)


def test_small_output_buffers_make_progress() raises:
    var config = CompressionConfig.default()
    config.buffer_size = 1
    var app = CompressionHandler[_BodyHandler](
        _body_handler(),
        config^,
        Optional[String](String("build/compression/libnet_zlib")),
    )
    var req = _request()
    var writer = ResponseWriter(16384)
    app.handle(req, writer)
    assert_equal(writer.headers.get_first("Content-Encoding").value(), "gzip")
    assert_true(len(writer.body) < 8192)


def test_compressed_expansion_obeys_existing_body_cap() raises:
    var inner = _body_handler()
    inner.body = List[Byte](length=1024, fill=0)
    var state = UInt64(123456789)
    for i in range(len(inner.body)):
        state = state * UInt64(6364136223846793005) + 1
        inner.body[i] = Byte(state >> 56)
    var app = _gzip(inner^)
    var req = _request()
    var writer = ResponseWriter(1024)
    with assert_raises():
        app.handle(req, writer)
    assert_equal(len(writer.body), 1024)
    assert_equal(writer.headers.count("Content-Encoding"), 0)


def _charged_success(mut budget: SharedBufferBudget) raises:
    var app = _gzip(_body_handler())
    var req = _request()
    var writer = ResponseWriter(16384)
    writer._set_body_budget(budget.copy())
    app.handle(req, writer)
    assert_equal(writer._body_capacity_reserved, writer.body.capacity())
    assert_true(budget.used() >= writer.body.capacity())


def test_replacement_capacity_is_owned_and_refunded() raises:
    var budget = SharedBufferBudget(65536)
    _charged_success(budget)
    assert_equal(budget.used(), 0)


def _charged_failure(mut budget: SharedBufferBudget) raises:
    var app = _gzip(_body_handler())
    var req = _request()
    var writer = ResponseWriter(16384)
    writer._set_body_budget(budget.copy())
    with assert_raises():
        app.handle(req, writer)
    assert_equal(len(writer.body), 8192)
    assert_equal(writer.headers.count("Content-Encoding"), 0)
    assert_equal(writer._body_capacity_reserved, writer.body.capacity())


def test_insufficient_peak_capacity_preserves_original_and_refunds() raises:
    var budget = SharedBufferBudget(14000)
    _charged_failure(budget)
    assert_equal(budget.used(), 0)


def test_provider_failure_preserves_original() raises:
    var app = CompressionHandler[_BodyHandler](
        _body_handler(),
        CompressionConfig.default(),
        Optional[String](String("missing-provider")),
    )
    var req = _request()
    var writer = ResponseWriter(16384)
    with assert_raises():
        app.handle(req, writer)
    assert_equal(len(writer.body), 8192)
    assert_equal(writer.headers.count("Content-Encoding"), 0)


def test_invalid_source_content_length_is_not_hidden() raises:
    for value in ["bad", "1", "8192,8192"]:
        var inner = _body_handler()
        inner.headers.add("Content-Length", value)
        var app = _gzip(inner^)
        var req = _request()
        var writer = ResponseWriter(16384)
        with assert_raises():
            app.handle(req, writer)
        assert_equal(len(writer.body), 8192)
        assert_equal(writer.headers.count("Content-Encoding"), 0)


def _mailbox_success(mut budget: SharedBufferBudget) raises:
    var app = _gzip(_body_handler())
    var req = _request()
    var writer = ResponseWriter(16384)
    writer._set_mailbox_budget(budget.copy())
    app.handle(req, writer)
    assert_equal(writer._body_capacity_reserved, 0)
    assert_false(Bool(writer._body_budget))
    assert_true(len(writer.body) < 8192)


def test_mailbox_only_writer_preserves_adapter_admission_boundary() raises:
    var budget = SharedBufferBudget(65536)
    _mailbox_success(budget)
    assert_equal(budget.used(), 0)


def test_mailbox_source_ticket_survives_output_reservation() raises:
    var budget = SharedBufferBudget(14000)
    var app = _gzip(_body_handler())
    var req = _request()
    var writer = ResponseWriter(16384)
    writer._set_mailbox_budget(budget.copy())
    with assert_raises():
        app.handle(req, writer)
    assert_equal(len(writer.body), 8192)
    assert_equal(writer.headers.count("Content-Encoding"), 0)
    assert_true(budget.used() < 8192)


@fieldwise_init
struct _OversizedHandler(Handler):
    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        _ = req
        writer.body = List[Byte](length=8192, fill=Byte(65))


def test_compression_does_not_hide_oversized_source() raises:
    var app = CompressionHandler[_OversizedHandler](
        _OversizedHandler(),
        CompressionConfig.default(),
        Optional[String]("build/compression/libnet_zlib"),
    )
    var req = _request()
    var writer = ResponseWriter(4096)
    with assert_raises():
        app.handle(req, writer)
    assert_equal(len(writer.body), 8192)
    assert_equal(writer.headers.count("Content-Encoding"), 0)


def test_gzip_weakens_strong_etag_and_preserves_weak_etag() raises:
    for tag in ['"source"', 'W/"source"']:
        var inner = _body_handler()
        inner.headers.add("ETag", tag)
        var app = _gzip(inner^)
        var req = _request()
        var writer = ResponseWriter(16384)
        app.handle(req, writer)
        assert_equal(writer.headers.get_first("ETag").value(), 'W/"source"')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
