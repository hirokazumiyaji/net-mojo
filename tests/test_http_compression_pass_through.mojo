from std.testing import assert_equal, assert_false, TestSuite

from net.http import (
    CompressionConfig,
    CompressionHandler,
    Handler,
    HttpVersion,
    Request,
    ResponseWriter,
)


@fieldwise_init
struct _Handler(Handler):
    var status: Int

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(self.status)
        writer.headers.add("Content-Type", "text/plain")
        writer.headers.add("Vary", "Origin")
        writer.write_string(req.path)


def test_absent_provider_preserves_body_and_headers() raises:
    var app = CompressionHandler[_Handler](
        _Handler(201), CompressionConfig.default(), None
    )
    var req = Request("GET", "/hello", "/hello", "", HttpVersion.http11())
    req.headers.add("Accept-Encoding", "gzip")
    var writer = ResponseWriter(128)
    app.handle(req, writer)
    assert_equal(writer.status, 201)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "/hello")
    assert_equal(writer.headers.get_first("Vary").value(), "Origin")
    assert_equal(writer.headers.count("Content-Encoding"), 0)
    assert_false(writer.is_detached())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
