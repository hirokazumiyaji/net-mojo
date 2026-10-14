from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)

from net.http import CompressionConfig, negotiate_encoding


def _choose(header: StringSlice) -> Optional[String]:
    var supported: List[String] = ["gzip"]
    return negotiate_encoding(header, supported)


def test_gzip_negotiation_accepts_case_and_quality() raises:
    assert_equal(_choose("GZIP;q=0.5, deflate;q=1").value(), "gzip")
    assert_equal(_choose("*;q=0.4").value(), "gzip")


def test_specific_zero_overrides_wildcard() raises:
    assert_false(Bool(_choose("gzip;q=0, *")))
    assert_false(Bool(_choose("*;q=1, GZIP;q=0")))
    assert_false(Bool(_choose("*;q=0")))


def test_empty_unknown_and_identity_fall_back() raises:
    assert_false(Bool(_choose("")))
    assert_false(Bool(_choose("identity;q=0, gzip;q=0, *;q=0")))
    assert_false(Bool(_choose("br, deflate")))


def test_invalid_qvalues_are_not_accepted() raises:
    for value in ["-1", "1.001", "0.1234", "NaN", "2", ".5"]:
        assert_false(Bool(_choose(String("gzip;q=") + value)))
    assert_equal(_choose("gzip;q=0.001").value(), "gzip")
    assert_equal(_choose("gzip;q=1.000").value(), "gzip")


def test_supported_quality_and_header_tie_order() raises:
    var supported: List[String] = ["gzip", "br"]
    assert_equal(
        negotiate_encoding("br;q=0.9, gzip;q=0.9", supported).value(), "br"
    )
    assert_equal(
        negotiate_encoding("gzip;q=0.2, br;q=0.3", supported).value(), "br"
    )


def test_explicit_identity_quality_and_order_are_respected() raises:
    assert_false(Bool(_choose("identity;q=1, gzip;q=0.1")))
    assert_false(Bool(_choose("gzip;q=0.1, IDENTITY;q=0.9")))
    assert_false(Bool(_choose("identity;q=0.5, gzip;q=0.5")))
    assert_equal(_choose("gzip;q=0.5, identity;q=0.5").value(), "gzip")
    assert_equal(_choose("identity;q=0, gzip;q=0.1").value(), "gzip")
    assert_equal(_choose("gzip;q=0.1").value(), "gzip")
    assert_false(Bool(_choose("identity;q=1, *;q=0.1")))
    assert_equal(_choose("identity;q=NaN, gzip;q=0.1").value(), "gzip")


def test_default_configuration_and_validation() raises:
    var config = CompressionConfig.default()
    assert_equal(config.level, 5)
    assert_equal(config.min_size, 1024)
    assert_equal(config.buffer_size, 32768)
    config.validate()
    assert_true(len(config.skip_content_types) > 0)
    assert_true(len(config.skip_content_type_prefixes) > 0)
    assert_true(len(config.skip_extensions) > 0)


def test_non_http_whitespace_is_not_encoding_padding() raises:
    assert_false(Bool(_choose("\rgzip")))
    assert_false(Bool(_choose("gzip\n")))
    assert_equal(_choose(" \tGZIP\t ").value(), "gzip")


def test_invalid_configuration_rejected() raises:
    var config = CompressionConfig.default()
    config.level = 0
    with assert_raises():
        config.validate()
    config.level = 10
    with assert_raises():
        config.validate()
    config.level = 5
    config.min_size = -1
    with assert_raises():
        config.validate()
    config.min_size = 0
    config.buffer_size = 0
    with assert_raises():
        config.validate()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
