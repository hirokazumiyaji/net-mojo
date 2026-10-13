from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.http import ServerConfig
from net.http._body_decoder import _BodyDecoder
from net.http._body_pipe import _BodyPipe
from net.http._buffer import SharedBufferBudget


def _check_split(
    wire: String, expected: String, chunked: Bool, split: Int
) raises:
    var config = ServerConfig.default()
    config.max_body_bytes = 3
    var pipe = _BodyPipe(3, SharedBufferBudget(4096))
    var decoder = _BodyDecoder(pipe.copy(), chunked, expected.byte_length())
    var input = List[Byte]()
    var decoded = List[Byte]()
    var read = Array[Byte, 2](fill=0)
    var offset = 0
    var done = False
    var ends: List[Int] = [split, wire.byte_length()]
    for end in ends:
        input.extend(wire.as_bytes()[offset:end])
        offset = end
        while not done:
            var result = decoder.feed(Span(input), config)
            assert_false(result.error)
            done = result.complete
            var remainder = List[Byte]()
            remainder.extend(Span(input)[result.consumed :])
            input = remainder^
            while pipe.pending_bytes() > 0:
                var count = pipe.pop(Span(read))
                decoded.extend(Span(read)[:count])
            if not result.blocked:
                break
    assert_true(done)
    assert_equal(String(from_utf8_lossy=Span(decoded)), expected)
    assert_equal(String(from_utf8_lossy=Span(input)), "NEXT")
    assert_true(pipe.is_eof())
    assert_equal(pipe.total_decoded(), expected.byte_length())
    if chunked:
        var trailers = pipe.trailers()
        assert_equal(trailers.get_first("x-end").value(), "done")


def test_every_fixed_body_boundary() raises:
    var wire = String("abcdefghijkNEXT")
    for split in range(wire.byte_length() + 1):
        _check_split(wire, "abcdefghijk", False, split)


def test_every_chunked_body_boundary() raises:
    var wire = String(
        '5;ext="value"\r\nabcde\r\n6\r\nfghijk\r\n0\r\nx-end: done\r\n\r\nNEXT'
    )
    for split in range(wire.byte_length() + 1):
        _check_split(wire, "abcdefghijk", True, split)


def test_one_byte_feeds_and_binary_body() raises:
    var config = ServerConfig.default()
    var pipe = _BodyPipe(8, SharedBufferBudget(256))
    var decoder = _BodyDecoder(pipe.copy(), True, 0)
    var wire = List[Byte]()
    wire.extend(String("4\r\n").as_bytes())
    var binary: List[Byte] = [0, 13, 10, 255]
    wire.extend(Span(binary))
    wire.extend(String("\r\n0\r\n\r\n").as_bytes())
    var pending = List[Byte]()
    var decoded = List[Byte]()
    var read = Array[Byte, 8](fill=0)
    var done = False
    for byte in wire:
        pending.append(byte)
        var result = decoder.feed(Span(pending), config)
        assert_false(result.error)
        done = result.complete
        var remainder = List[Byte]()
        remainder.extend(Span(pending)[result.consumed :])
        pending = remainder^
        if pipe.pending_bytes() > 0:
            var count = pipe.pop(Span(read))
            decoded.extend(Span(read)[:count])
    assert_true(done)
    assert_equal(len(decoded), 4)
    assert_equal(decoded[0], 0)
    assert_equal(decoded[1], 13)
    assert_equal(decoded[2], 10)
    assert_equal(decoded[3], 255)


def _reject(wire: String, config: ServerConfig, status: Int) raises:
    var pipe = _BodyPipe(config.max_body_bytes, SharedBufferBudget(4096))
    var decoder = _BodyDecoder(pipe.copy(), True, 0)
    var result = decoder.feed(wire.as_bytes(), config)
    assert_true(result.error)
    assert_equal(result.error.value().status, status)
    assert_true(pipe.is_cancelled())


def test_invalid_chunk_and_trailer_framing() raises:
    var config = ServerConfig.default()
    var cases: List[String] = [
        "1\nA",
        "g\r\n",
        "1;=bad\r\na\r\n",
        "1\r\naX",
        "1\r\na\rX",
        "0\r\nContent-Length: 1\r\n\r\n",
        "0\r\n x: y\r\n\r\n",
        "0\r\nx: bad\x00\r\n\r\n",
        "0\r\nx: y\r\n folded\r\n\r\n",
    ]
    for wire in cases:
        _reject(wire, config, 400)


def test_metadata_and_trailer_limits() raises:
    var config = ServerConfig.default()
    config.max_chunk_metadata = 4
    _reject("1\r\na\r\n0\r\n\r\n", config, 413)
    _reject("12345", config, 413)
    config.max_chunk_metadata = 64
    config.max_trailer_bytes = 6
    _reject("0\r\nx: abc\r\n\r\n", config, 431)
    _reject("0\r\nx: abcdef", config, 431)
    config.max_trailer_bytes = 64
    config.max_trailer_count = 1
    _reject("0\r\nx: a\r\ny: b\r\n\r\n", config, 431)


def test_shared_budget_blocks_without_consuming_body() raises:
    var config = ServerConfig.default()
    var budget = SharedBufferBudget(4)
    var pipe = _BodyPipe(16, budget.copy())
    var decoder = _BodyDecoder(pipe.copy(), False, 8)
    var first = decoder.feed(String("abcdefghNEXT").as_bytes(), config)
    assert_equal(first.consumed, 4)
    assert_true(first.blocked)
    var blocked = decoder.feed(String("efghNEXT").as_bytes(), config)
    assert_true(blocked.blocked)
    assert_equal(blocked.consumed, 0)
    var read = Array[Byte, 4](fill=0)
    assert_equal(pipe.pop(Span(read)), 4)
    var second = decoder.feed(String("efghNEXT").as_bytes(), config)
    assert_equal(second.consumed, 4)
    assert_true(second.complete)
    assert_equal(pipe.pop(Span(read)), 4)
    assert_equal(budget.used(), 0)


def test_empty_body_finishes_without_input() raises:
    var config = ServerConfig.default()
    var pipe = _BodyPipe(8, SharedBufferBudget(64))
    var decoder = _BodyDecoder(pipe.copy(), False, 0)
    var result = decoder.feed(String("NEXT").as_bytes(), config)
    assert_true(result.complete)
    assert_equal(result.consumed, 0)
    assert_true(pipe.is_eof())


def test_discard_drains_when_other_connections_hold_budget() raises:
    var config = ServerConfig.default()
    var budget = SharedBufferBudget(16)
    var pipe = _BodyPipe(8, budget.copy())
    var decoder = _BodyDecoder(pipe.copy(), False, 16)
    pipe.discard()
    assert_true(budget.try_reserve(16))
    var result = decoder.feed(String("abcdefghijklmnopNEXT").as_bytes(), config)
    assert_true(result.complete)
    assert_equal(result.consumed, 16)
    assert_equal(pipe.take_consumed(), 16)
    budget.release(16)


def test_trailer_limit_allows_split_terminator() raises:
    var config = ServerConfig.default()
    config.max_trailer_bytes = 6
    var pipe = _BodyPipe(8, SharedBufferBudget(256))
    var decoder = _BodyDecoder(pipe.copy(), True, 0)
    var first = decoder.feed(String("0\r\nx: y\r\n\r").as_bytes(), config)
    assert_false(first.error)
    assert_equal(first.consumed, 9)
    var last = decoder.feed(String("\r\nNEXT").as_bytes(), config)
    assert_false(last.error)
    assert_true(last.complete)
    assert_equal(last.consumed, 2)


def test_budget_blocked_eof_preserves_trailers_for_retry() raises:
    var config = ServerConfig.default()
    var budget = SharedBufferBudget(4096)
    var pipe = _BodyPipe(8, budget.copy())
    var decoder = _BodyDecoder(pipe.copy(), True, 0)
    var first = decoder.feed(String("0\r\nx-end: done\r\n").as_bytes(), config)
    assert_false(first.error)
    var held = budget.remaining()
    assert_true(budget.try_reserve(held))
    var blocked = decoder.feed(String("\r\nNEXT").as_bytes(), config)
    assert_true(blocked.blocked)
    assert_false(blocked.complete)
    assert_equal(blocked.consumed, 0)
    budget.release(held)
    var retry = decoder.feed(String("\r\nNEXT").as_bytes(), config)
    assert_true(retry.complete)
    assert_equal(retry.consumed, 2)
    var trailers = pipe.trailers()
    assert_equal(trailers.get_first("x-end").value(), "done")


def test_trailers_larger_than_total_budget_fail_instead_of_waiting() raises:
    var config = ServerConfig.default()
    var pipe = _BodyPipe(4, SharedBufferBudget(4))
    var decoder = _BodyDecoder(pipe.copy(), True, 0)
    var result = decoder.feed(String("0\r\nx: y\r\n\r\n").as_bytes(), config)
    assert_true(result.error)
    assert_equal(result.error.value().status, 503)
    assert_true(pipe.is_cancelled())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
