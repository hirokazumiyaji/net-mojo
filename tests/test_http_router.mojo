from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.memory import ArcPointer

from net.error import NetErrorKind
from net.http import HttpVersion, Request, ResponseWriter
from net.http.handler import Handler
from net.http.router import Pattern, RouteHandler, ServeMux


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


def _request(method: StringSlice, path: StringSlice) -> Request:
    return Request(
        String(method), String(path), String(path), "", HttpVersion.http11()
    )


def _echo_param(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string(ServeMux.param(req, "id").value())


def _literal(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string("literal")


def test_mux_specificity_head_and_params() raises:
    var mux = ServeMux()
    mux.handle("/items/{id}", _echo_param)
    mux.handle("GET /items/new", _literal)
    var dynamic = _request("POST", "/items/a%2Fb")
    var dynamic_writer = ResponseWriter(1024)
    mux.handle(dynamic, dynamic_writer)
    assert_equal(String(from_utf8_lossy=Span(dynamic_writer.body)), "a%2Fb")
    assert_false(ServeMux.param(dynamic, "id"))
    var head = _request("HEAD", "/items/new")
    var head_writer = ResponseWriter(1024)
    mux.handle(head, head_writer)
    assert_equal(String(from_utf8_lossy=Span(head_writer.body)), "literal")


def test_mux_not_found_and_allow() raises:
    var mux = ServeMux()
    mux.handle("POST /item", _literal)
    mux.handle("GET /item", _literal)
    mux.handle("DELETE /item", _literal)
    var missing = _request("GET", "/missing")
    var missing_writer = ResponseWriter(1024)
    mux.handle(missing, missing_writer)
    assert_equal(missing_writer.status, 404)
    assert_equal(String(from_utf8_lossy=Span(missing_writer.body)), "not found")
    var wrong_method = _request("PATCH", "/item")
    var method_writer = ResponseWriter(1024)
    mux.handle(wrong_method, method_writer)
    assert_equal(method_writer.status, 405)
    assert_equal(
        method_writer.headers.get_first("allow").value(),
        "DELETE, GET, HEAD, POST",
    )


@fieldwise_init
struct _CounterHandler(Handler):
    var count: Int

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.count += 1
        writer.write_string(String(self.count))


def test_mux_heterogeneous_owned_handlers() raises:
    var mux = ServeMux()
    mux.handle_handler("/counter", _CounterHandler(0))
    var prefix = String("owned")

    def callback(req: Request, mut writer: ResponseWriter) raises {var prefix}:
        writer.write_string(prefix)

    mux.handle("/closure", callback^)
    prefix = "changed"
    assert_equal(prefix, "changed")
    for expected in range(1, 4):
        var req = _request("GET", "/counter")
        var writer = ResponseWriter(1024)
        mux.handle(req, writer)
        assert_equal(
            String(from_utf8_lossy=Span(writer.body)), String(expected)
        )
    var closure_req = _request("GET", "/closure")
    var closure_writer = ResponseWriter(1024)
    mux.handle(closure_req, closure_writer)
    assert_equal(String(from_utf8_lossy=Span(closure_writer.body)), "owned")


def _owned_callback() -> RouteHandler:
    var payload = String("retained after factory")

    def callback(
        req: Request, mut writer: ResponseWriter
    ) raises {var payload^}:
        writer.write_string(payload)

    return RouteHandler(callback^)


def test_callback_survives_factory_and_route_list_growth() raises:
    var mux = ServeMux()
    mux.register("/retained", _owned_callback())
    for index in range(64):
        mux.handle(String("/route/") + String(index), _literal)
    var req = _request("GET", "/retained")
    var writer = ResponseWriter(1024)
    mux.handle(req, writer)
    assert_equal(
        String(from_utf8_lossy=Span(writer.body)), "retained after factory"
    )


@fieldwise_init
struct _DropHandler(Handler, Movable):
    var drops: ArcPointer[Int]

    def __deinit__(deinit self):
        self.drops[] += 1

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.write_string("drop")


def _make_and_drop_mux(drops: ArcPointer[Int]) raises:
    var mux = ServeMux()
    mux.handle_handler("/drop", _DropHandler(drops))


def test_handlers_are_destroyed_once() raises:
    var drops = ArcPointer(0)
    _make_and_drop_mux(drops)
    assert_equal(drops[], 1)


def test_mux_registration_failure_is_atomic() raises:
    var mux = ServeMux(2)
    mux.handle("/items/{id}", _echo_param)
    var rejected = False
    try:
        mux.handle("/items/{name}", _literal)
    except:
        rejected = True
    assert_true(rejected)
    mux.handle("/other", _literal)
    rejected = False
    try:
        mux.handle("/third", _literal)
    except:
        rejected = True
    assert_true(rejected)
    var req = _request("GET", "/items/42")
    var writer = ResponseWriter(1024)
    mux.handle(req, writer)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "42")


def _raise_after_param(req: Request, mut writer: ResponseWriter) raises:
    assert_equal(ServeMux.param(req, "id").value(), "42")
    raise Error("handler failed")


def test_mux_clears_params_when_handler_raises() raises:
    var mux = ServeMux()
    mux.handle("/items/{id}", _raise_after_param)
    var req = _request("GET", "/items/42")
    var writer = ResponseWriter(1024)
    var raised = False
    try:
        mux.handle(req, writer)
    except:
        raised = True
    assert_true(raised)
    assert_false(ServeMux.param(req, "id"))


@fieldwise_init
struct _NestedMuxHandler(Handler):
    var inner: ServeMux

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        assert_equal(ServeMux.param(req, "outer").value(), "42")
        try:
            self.inner.handle(req, writer)
        except:
            pass
        assert_true(ServeMux.param(req, "outer"))
        assert_equal(ServeMux.param(req, "outer").value(), "42")
        assert_false(ServeMux.param(req, "id"))


def test_nested_mux_restores_outer_params_on_return_and_error() raises:
    for should_raise in range(2):
        var inner = ServeMux()
        if should_raise:
            inner.handle("/items/{id}", _raise_after_param)
        else:
            inner.handle("/items/{id}", _echo_param)
        var outer = ServeMux()
        outer.handle_handler("/items/{outer}", _NestedMuxHandler(inner^))
        var req = _request("GET", "/items/42")
        var writer = ResponseWriter(1024)
        outer.handle(req, writer)
        assert_false(ServeMux.param(req, "outer"))
        assert_false(ServeMux.param(req, "id"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
