from std.testing import assert_equal, assert_false, assert_true, TestSuite

from net.error import NetErrorKind
from net.http.router import Pattern


def test_literals_and_subtrees() raises:
    var exact = Pattern("/items")
    assert_true(exact.matches("GET", "/items").matched)
    assert_false(exact.matches("GET", "/items/1").matched)
    assert_false(exact.matches("GET", "/items/").matched)
    var subtree = Pattern("/items/")
    assert_true(subtree.matches("GET", "/items/").matched)
    assert_true(subtree.matches("POST", "/items/a/b").matched)
    assert_false(subtree.matches("GET", "/items").matched)
    var root = Pattern("/")
    assert_true(root.matches("GET", "/").matched)
    assert_true(root.matches("GET", "/a/b").matched)
    var end = Pattern("/items/{$}")
    assert_true(end.matches("GET", "/items/").matched)
    assert_false(end.matches("GET", "/items/a").matched)


def test_parameters_and_methods() raises:
    var item = Pattern("GET /items/{id}")
    var result = item.matches("HEAD", "/items/a%2Fb")
    assert_true(result.matched)
    assert_equal(result.params[0][0], "id")
    assert_equal(result.params[0][1], "a%2Fb")
    assert_false(item.matches("POST", "/items/1").matched)
    assert_false(item.matches("GET", "/items/").matched)
    var rest = Pattern("/static/{path...}")
    var rest_result = rest.matches("GET", "/static/a/b")
    assert_equal(rest_result.params[0][1], "a/b")
    assert_true(rest.matches("GET", "/static/").matched)
    assert_false(rest.matches("GET", "/static").matched)
    assert_true(rest.matches("GET", "/static/../x").matched)


def test_specificity_and_conflicts() raises:
    var generic = Pattern("/items/{id}")
    var literal = Pattern("/items/new")
    assert_true(literal.more_specific_than(generic))
    assert_false(literal.conflicts_with(generic))
    var get = Pattern("GET /items/{id}")
    var head = Pattern("HEAD /items/{name}")
    assert_true(head.more_specific_than(get))
    assert_true(get.more_specific_than(generic))
    assert_false(head.conflicts_with(get))
    var post = Pattern("POST /items/{id}")
    assert_false(post.conflicts_with(get))
    var duplicate = Pattern("/items/{name}")
    assert_true(duplicate.conflicts_with(generic))
    var cross_a = Pattern("/a/{x}")
    var cross_b = Pattern("/{x}/b")
    assert_true(cross_a.conflicts_with(cross_b))
    var method_path_cross = Pattern("GET /{x}/b")
    assert_true(method_path_cross.conflicts_with(cross_a))
    var subtree = Pattern("/a/")
    var rest = Pattern("/a/{tail...}")
    assert_true(subtree.conflicts_with(rest))
    var end = Pattern("/a/{$}")
    var one = Pattern("/a/{x}")
    assert_false(end.conflicts_with(one))
    assert_true(end.more_specific_than(subtree))


def test_invalid_patterns() raises:
    var cases: List[String] = [
        "",
        "items",
        "GET",
        "GET items",
        "G ET /x",
        "/{x",
        "/x}",
        "/{}",
        "/{a}/{a}",
        "/{a...}/b",
        "/{a b}",
        "/a?b",
        "/a#b",
        "/a//b",
        "/a/./b",
        "/a/../b",
        "/{$}/b",
    ]
    for pattern in cases:
        var failed = False
        try:
            var parsed = Pattern(pattern)
            _ = parsed
        except error:
            failed = True
            assert_equal(error.kind, NetErrorKind.invalid_argument())
        assert_true(failed, "accepted invalid pattern: " + pattern)


def _reject_pattern(pattern: String) raises:
    var rejected = False
    try:
        var parsed = Pattern(pattern)
        _ = parsed
    except error:
        assert_equal(error.kind, NetErrorKind.invalid_argument())
        rejected = True
    assert_true(rejected)


def test_registration_limits() raises:
    var long = String("/")
    for _ in range(1023):
        long += "a"
    var accepted = Pattern(long)
    assert_equal(accepted.raw.byte_length(), 1024)
    long += "a"
    _reject_pattern(long)
    var many = String("")
    for _ in range(32):
        many += "/a"
    var max_segments = Pattern(many)
    assert_equal(len(max_segments.segments), 32)
    many += "/a"
    _reject_pattern(many)
    var names = String("")
    for i in range(16):
        names += "/{v" + String(i) + "}"
    var max_names = Pattern(names)
    assert_equal(len(max_names.segments), 16)
    names += "/{extra}"
    _reject_pattern(names)


def test_conflict_symmetry_and_disjoint_paths() raises:
    var patterns: List[String] = [
        "/",
        "/{$}",
        "/a",
        "/a/",
        "/a/{$}",
        "/a/{x}",
        "/a/{tail...}",
        "/{x}/b",
        "GET /a/{x}",
        "HEAD /a/{x}",
        "POST /a/{x}",
        "/b/",
    ]
    for left_raw in patterns:
        var left = Pattern(left_raw)
        for right_raw in patterns:
            var right = Pattern(right_raw)
            assert_equal(left.conflicts_with(right), right.conflicts_with(left))
            assert_false(
                left.more_specific_than(right)
                and right.more_specific_than(left)
            )
    var left = Pattern("/a/{tail...}")
    var right = Pattern("/b/")
    assert_false(left.conflicts_with(right))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
