from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)

from net.compress.zlib import GzipEncoder


def test_partial_output_preserves_input_progress_and_footer() raises:
    var encoder = GzipEncoder("build/compression/libnet_zlib", 5)
    var input = String("abcdefghijklmnopqrstuvwxyz") * 1024
    var bytes = input.as_bytes()
    var output = Array[Byte, 7](fill=0)
    var compressed = List[Byte]()
    var offset = 0
    var finished = False
    while not finished:
        var progress = encoder.process(
            bytes[offset : len(bytes)], Span(output), finish=True
        )
        assert_true(
            progress.consumed > 0 or progress.produced > 0 or progress.finished
        )
        offset += progress.consumed
        compressed.extend(Span(output)[0 : progress.produced])
        finished = progress.finished
    assert_equal(offset, len(bytes))
    assert_true(len(compressed) < len(bytes))
    assert_equal(compressed[0], Byte(0x1F))
    assert_equal(compressed[1], Byte(0x8B))
    with assert_raises():
        _ = encoder.process(bytes[0:0], Span(output), finish=True)


def test_nonfinal_input_then_empty_finish() raises:
    var encoder = GzipEncoder("build/compression/libnet_zlib", 5)
    var input = String("body") * 100
    var output = Array[Byte, 32768](fill=0)
    var first = encoder.process(input.as_bytes(), Span(output))
    assert_equal(first.consumed, input.byte_length())
    assert_false(first.finished)
    var done = encoder.process(input.as_bytes()[0:0], Span(output), finish=True)
    assert_true(done.finished)
    assert_true(done.produced > 0)


def test_empty_body_and_bound() raises:
    var encoder = GzipEncoder("build/compression/libnet_zlib", 5)
    assert_true(encoder.bound(0) >= 20)
    var input = String("")
    var output = Array[Byte, 32](fill=0)
    var result = encoder.process(input.as_bytes(), Span(output), finish=True)
    assert_true(result.finished)
    assert_equal(result.consumed, 0)
    assert_equal(result.produced, 20)


def test_invalid_level_fails_before_library_loading() raises:
    with assert_raises():
        var encoder = GzipEncoder("unused-library-path", 0)
        _ = encoder^
    with assert_raises():
        var encoder = GzipEncoder("unused-library-path", 10)
        _ = encoder^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
