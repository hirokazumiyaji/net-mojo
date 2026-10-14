from std.testing import assert_equal, assert_true
from proptest import Settings, TestCase, for_all, integers, text
from net.http._http2.hpack import Http2HpackDeflater, Http2HpackInflater
from tests.support import _append_hpack_field


def _hpack_roundtrip(mut tc: TestCase) raises:
    var deflater = Http2HpackDeflater("build/http2/libnet_hpack", 4096)
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var alphabet = String("")
    for i in range(32, 127):
        alphabet += String(chr(i))
    var previous = List[Byte]()
    var previous_count = 0
    var blocks = tc.draw(integers(2, 4), "blocks")
    for block in range(blocks):
        var table_size = tc.draw(integers(0, 4096), "table-size")
        assert_true(deflater.set_max_table_size(table_size))
        assert_true(inflater.set_max_table_size(table_size))
        var fields = List[Byte]()
        var count = tc.draw(integers(0, 16), "field-count")
        if block % 2 == 1:
            fields = previous.copy()
            count = previous_count
        else:
            for i in range(count):
                var name = tc.draw(
                    text(
                        "abcdefghijklmnopqrstuvwxyz-", min_size=1, max_size=16
                    ),
                    "name-" + String(i),
                )
                var value = tc.draw(
                    text(alphabet, max_size=32), "value-" + String(i)
                )
                _append_hpack_field(fields, name, value)
            previous = fields.copy()
            previous_count = count
        var bound = deflater.deflate_bound(Span(fields))
        assert_true(bound >= 0)
        var compressed = Array[Byte, 4096](fill=0)
        var encoded = deflater.encode(Span(fields), 4096, 16, Span(compressed))
        assert_true(encoded.is_success())
        assert_true(encoded.output_length <= bound)
        var output = Array[Byte, 4096](fill=0)
        var decoded = inflater.decode(
            Span(compressed)[0 : encoded.output_length], 4096, 16, Span(output)
        )
        assert_true(decoded.is_success())
        assert_equal(decoded.field_count, count)
        assert_equal(decoded.output_length, len(fields))
        var decoded_size = len(fields) + count * 24
        assert_equal(decoded.decoded_size, decoded_size)
        for i in range(len(fields)):
            assert_equal(output[i], fields[i])


def main() raises:
    for_all(_hpack_roundtrip, Settings(name="net-hpack-stateful-roundtrip"))
