from std.testing import assert_equal, assert_true
from proptest import Settings, TestCase, for_all, integers, text
from net.http import ServerConfig
from net.http._parser import parse_head, _scan_head, _RequestScan


def _head_fragmentation(mut tc: TestCase) raises:
    var methods = ["GET", "POST", "PATCH"]
    var method = methods[tc.draw(integers(0, 2), "method")].copy()
    var path = "/" + tc.draw(text("abcABC09-_", max_size=32), "path")
    var query = tc.draw(text("abc09=&", max_size=16), "query")
    var target = path + "?" + query
    var wire = method + " " + target + " HTTP/1.1\r\nHost: example.test\r\n"
    var count = tc.draw(integers(0, 8), "header-count")
    for i in range(count):
        var name = "x-" + tc.draw(
            text("abcABC09-", min_size=1, max_size=8), "name-" + String(i)
        )
        var value = tc.draw(
            text("abcABC09-_", max_size=32), "value-" + String(i)
        )
        wire += name + ": " + value + "\r\n"
    wire += "\r\n"
    var config = ServerConfig.default()
    var full = parse_head(wire.as_bytes(), config)
    assert_true(full.is_complete())
    assert_equal(full.head.method, method)
    assert_equal(full.head.target, target)
    assert_equal(full.head.path, path)
    assert_equal(full.head.query, query)
    assert_equal(len(full.head.headers), count + 1)
    var frontier = _RequestScan.start()
    var accumulated = List[Byte]()
    var bytes = wire.as_bytes()
    var offset = 0
    while offset < len(bytes):
        var width = tc.draw(integers(1, 32), "fragment-width")
        var end = min(offset + width, len(bytes))
        accumulated.extend(bytes[offset:end])
        offset = end
        var scan = _scan_head(
            Span(accumulated),
            config,
            frontier.head_wire,
            frontier.head_bytes,
            frontier.head_lines,
            frontier.in_headers,
        )
        var partial = parse_head(Span(accumulated), config)
        if offset < len(bytes):
            assert_true(scan.is_need_more())
            assert_true(partial.is_need_more())
        else:
            assert_true(scan.is_complete())
            assert_true(partial.is_complete())
            assert_equal(scan.header_end, full.head.header_end)
            assert_equal(partial.head.target, full.head.target)
            assert_equal(partial.head.method, full.head.method)
            assert_equal(partial.head.version, full.head.version)
            for i in range(len(full.head.headers)):
                assert_equal(
                    partial.head.headers.name_at(i),
                    full.head.headers.name_at(i),
                )
                assert_equal(
                    partial.head.headers.value_at(i),
                    full.head.headers.value_at(i),
                )


def main() raises:
    for_all(_head_fragmentation, Settings(name="net-http1-head-fragmentation"))
