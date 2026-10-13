from std.testing import assert_equal, assert_true
from proptest import Settings, TestCase, for_all, integers, bytes, lists
from net.http import ServerConfig, ResponseWriter
from net.http._encoder import encode_chunk, encode_chunk_end, encode_response
from net.http._parser import parse_one, _scan_chunked


def _chunked_roundtrip(mut tc: TestCase) raises:
    var payloads = tc.draw(lists(bytes(max_size=64), max_size=8), "chunks")
    var expected = List[Byte]()
    var chunks = List[Byte]()
    for payload in payloads:
        expected.extend(Span(payload))
        var encoded = encode_chunk(Span(payload))
        chunks.extend(Span(encoded))
    var terminal = encode_chunk_end()
    chunks.extend(Span(terminal))
    var head = (
        "POST /body HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding:"
        " chunked\r\n\r\n"
    )
    var wire = List[Byte]()
    wire.extend(head.as_bytes())
    wire.extend(Span(chunks))
    var config = ServerConfig.default()
    var chunk_wire = 0
    var metadata = 0
    var decoded = 0
    var accumulated = List[Byte]()
    var offset = 0
    while offset < len(chunks):
        var width = tc.draw(integers(1, 32), "fragment-width")
        var end = min(offset + width, len(chunks))
        accumulated.extend(Span(chunks)[offset:end])
        offset = end
        var scan = _scan_chunked(
            Span(accumulated), config, chunk_wire, metadata, decoded
        )
        if offset < len(chunks):
            assert_true(scan.is_need_more())
        else:
            assert_true(scan.is_complete())
            assert_equal(scan.consumed, len(chunks))
            assert_equal(scan.decoded, len(expected))
    var parsed = parse_one(Span(wire), config)
    assert_true(parsed.is_complete())
    assert_equal(parsed.consumed, len(wire))
    assert_equal(len(parsed.request.body), len(expected))
    for i in range(len(expected)):
        assert_equal(parsed.request.body[i], expected[i])
    wire.extend("GET /next HTTP/1.1\r\nHost: example.test\r\n\r\n".as_bytes())
    var pipelined = parse_one(Span(wire), config)
    assert_true(pipelined.is_complete())
    assert_equal(pipelined.consumed, parsed.consumed)


def _response_reparse(mut tc: TestCase) raises:
    var body = tc.draw(bytes(max_size=128), "response-body")
    var status = tc.draw(integers(200, 203), "status")
    var writer = ResponseWriter(256)
    writer.set_status(status)
    writer.headers.add("x-property", "roundtrip")
    writer.write(Span(body))
    var wire = encode_response(
        writer, False, "Thu, 01 Jan 1970 00:00:00 GMT", 100, 32768
    )
    var line_end = 0
    while wire[line_end] != Byte(ord("\r")):
        line_end += 1
    var status_line = String(from_utf8_lossy=Span(wire)[0:line_end])
    assert_true(status_line.startswith("HTTP/1.1 " + String(status) + " "))
    var request_wire = List[Byte]()
    request_wire.extend(
        "POST /response HTTP/1.1\r\nHost: example.test\r\n".as_bytes()
    )
    request_wire.extend(Span(wire)[line_end + 2 :])
    var parsed = parse_one(Span(request_wire), ServerConfig.default())
    assert_true(parsed.is_complete())
    assert_equal(parsed.consumed, len(request_wire))
    assert_equal(
        parsed.request.headers.get_first("x-property").value(), "roundtrip"
    )
    assert_equal(len(parsed.request.body), len(body))
    for i in range(len(body)):
        assert_equal(parsed.request.body[i], body[i])


def main() raises:
    for_all(_chunked_roundtrip, Settings(name="net-http1-chunked-roundtrip"))
    for_all(_response_reparse, Settings(name="net-http1-response-reparse"))
