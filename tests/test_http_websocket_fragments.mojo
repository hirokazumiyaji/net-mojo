from std.testing import assert_equal, assert_true, TestSuite
from net.http._websocket_frame import (
    _FrameDecoder,
    _encode_frame,
    _UTF8Validator,
    _WebSocketFrame,
)


def _feed[
    o: ImmOrigin
](mut decoder: _FrameDecoder, input: Span[Byte, o]) raises -> Int:
    try:
        return decoder.feed(input)
    except err:
        raise Error(err.reason)


def _take(mut decoder: _FrameDecoder) raises -> _WebSocketFrame:
    try:
        return decoder.take_frame()
    except err:
        raise Error(err.reason)


def _masked(payload: StringSlice) -> List[Byte]:
    var wire: List[Byte] = [
        129,
        Byte(128 + payload.byte_length()),
        55,
        250,
        33,
        61,
    ]
    var bytes = payload.as_bytes()
    for i in range(len(bytes)):
        wire.append(bytes[i] ^ wire[2 + i % 4])
    return wire^


def test_every_split_preserves_mask_position() raises:
    var wire = _masked("Hello, WebSocket")
    for split in range(len(wire) + 1):
        var decoder = _FrameDecoder(1024)
        assert_equal(_feed(decoder, Span(wire)[0:split]), split)
        assert_equal(_feed(decoder, Span(wire)[split:]), len(wire) - split)
        assert_true(decoder.complete())
        var frame = _take(decoder)
        assert_equal(frame.opcode, 1)
        assert_true(frame.fin)
        assert_equal(
            String(from_utf8_lossy=Span(frame.payload)), "Hello, WebSocket"
        )


def test_frame_stops_before_following_frame() raises:
    var first = _masked("first")
    var second = _masked("second")
    var both = first.copy()
    both.extend(Span(second))
    var decoder = _FrameDecoder(100)
    assert_equal(_feed(decoder, Span(both)), len(first))
    var frame = _take(decoder)
    assert_equal(String(from_utf8_lossy=Span(frame.payload)), "first")
    assert_equal(_feed(decoder, Span(second)), len(second))


def test_unmasked_server_encoding() raises:
    var payload = String("Hello")
    var wire = _encode_frame(1, True, payload.as_bytes())
    assert_equal(wire[0], 129)
    assert_equal(wire[1], 5)
    assert_equal(String(from_utf8_lossy=Span(wire)[2:]), "Hello")


def test_utf8_state_crosses_fragments() raises:
    var validator = _UTF8Validator()
    var first: List[Byte] = [0xF0, 0x9F]
    var second: List[Byte] = [0x98, 0x80]
    assert_true(validator.feed(Span(first)))
    assert_equal(validator.complete(), False)
    assert_true(validator.feed(Span(second)))
    assert_true(validator.complete())
    var invalid: List[Byte] = [0xED, 0xA0, 0x80]
    validator = _UTF8Validator()
    assert_equal(validator.feed(Span(invalid)), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def _expect_protocol_error(
    var wire: List[Byte], code: UInt16, limit: Int = 1024
) raises:
    var decoder = _FrameDecoder(limit)
    var got: UInt16 = 0
    try:
        _ = decoder.feed(Span(wire))
        if decoder.complete():
            _ = decoder.take_frame()
    except err:
        got = err.code
    assert_equal(got, code)


def test_rejects_invalid_header_before_waiting_for_payload() raises:
    _expect_protocol_error([129, 0], 1002)
    _expect_protocol_error([193, 128], 1002)
    _expect_protocol_error([131, 128], 1002)
    _expect_protocol_error([9, 128], 1002)
    _expect_protocol_error([137, 254], 1002)


def test_noncanonical_and_oversized_lengths() raises:
    _expect_protocol_error([129, 254, 0, 125, 0, 0, 0, 0], 1002)
    _expect_protocol_error(
        [129, 255, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0], 1002
    )
    _expect_protocol_error(
        [129, 255, 128, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0], 1002
    )
    _expect_protocol_error([129, 254, 4, 1, 0, 0, 0, 0], 1009)


def test_close_payload_validation() raises:
    _expect_protocol_error([136, 129, 0, 0, 0, 0, 0], 1002)
    _expect_protocol_error([136, 130, 0, 0, 0, 0, 3, 237], 1002)
    _expect_protocol_error([136, 131, 0, 0, 0, 0, 3, 232, 255], 1007)
    var valid: List[Byte] = [136, 130, 0, 0, 0, 0, 3, 232]
    var decoder = _FrameDecoder(100)
    _ = _feed(decoder, Span(valid))
    var frame = _take(decoder)
    assert_equal(frame.payload[1], 232)


def test_extended_lengths_and_incremental_large_payload() raises:
    for length in [0, 125, 126, 65535, 65536]:
        var bytes = List[Byte](length=length, fill=97)
        var encoded = _encode_frame(2, True, Span(bytes))
        var header_length = len(encoded) - length
        var wire = List[Byte]()
        wire.extend(Span(encoded)[0:header_length])
        wire[1] |= 128
        var mask: List[Byte] = [1, 22, 33, 244]
        wire.extend(Span(mask))
        for i in range(length):
            wire.append(bytes[i] ^ mask[i % 4])
        var decoder = _FrameDecoder(65536)
        for i in range(header_length + 4):
            assert_equal(_feed(decoder, Span(wire)[i : i + 1]), 1)
        var at = header_length + 4
        while at < len(wire):
            var end = min(at + 4093, len(wire))
            assert_equal(_feed(decoder, Span(wire)[at:end]), end - at)
            at = end
        var frame = _take(decoder)
        assert_equal(len(frame.payload), length)
        for byte in frame.payload:
            assert_equal(byte, 97)


def test_utf8_rejects_overlong_surrogate_and_out_of_range() raises:
    var invalid: List[List[Byte]] = [
        [192, 128],
        [224, 159, 128],
        [237, 160, 128],
        [240, 143, 128, 128],
        [244, 144, 128, 128],
        [245, 128, 128, 128],
        [128],
        [255],
    ]
    for ref bytes in invalid:
        for split in range(len(bytes) + 1):
            var validator = _UTF8Validator()
            var first = validator.feed(Span(bytes)[0:split])
            var second = validator.feed(Span(bytes)[split:])
            assert_equal(first and second and validator.complete(), False)
