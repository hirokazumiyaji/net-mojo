from std.memory import ArcPointer
from std.time import sleep
from std.testing import assert_equal, assert_true, TestSuite

from net.http import HttpVersion, Request, ResponseWriter, RouteHandler
from net.http.handler import Handler
from net.http.middleware import (
    LogSink,
    LoggingHandler,
    MiddlewareFn,
    RecoverHandler,
    TimeoutHandler,
    apply_middleware,
)
from net.http._buffer import SharedBufferBudget
from net import Timeout


def _request() -> Request:
    return Request("GET", "/", "/", "", HttpVersion.http11())


@fieldwise_init
struct _CountingHandler(Handler):
    var calls: ArcPointer[Int]

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.calls[] += 1
        writer.set_status(201)
        writer.write_string("final")


def test_apply_middleware_preserves_outermost_first_order() raises:
    var events = ArcPointer(List[String]())

    def outer(
        req: Request, mut writer: ResponseWriter, mut next: RouteHandler
    ) raises {var events}:
        events[].append("outer before")
        next.handle(req, writer)
        events[].append("outer after")

    def inner(
        req: Request, mut writer: ResponseWriter, mut next: RouteHandler
    ) raises {var events}:
        events[].append("inner before")
        next.handle(req, writer)
        events[].append("inner after")

    def final(req: Request, mut writer: ResponseWriter) raises {var events}:
        events[].append("final")
        writer.set_status(202)
        writer.write_string("body")

    var layers = List[MiddlewareFn]()
    layers.append(MiddlewareFn(outer^))
    layers.append(MiddlewareFn(inner^))
    var handler = apply_middleware(RouteHandler(final^), layers^)
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(len(events[]), 5)
    assert_equal(events[][0], "outer before")
    assert_equal(events[][1], "inner before")
    assert_equal(events[][2], "final")
    assert_equal(events[][3], "inner after")
    assert_equal(events[][4], "outer after")
    assert_equal(writer.status, 202)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "body")


def _deny(
    req: Request, mut writer: ResponseWriter, mut next: RouteHandler
) raises:
    writer.set_status(401)
    writer.write_string("denied")


def test_middleware_can_short_circuit_next() raises:
    var calls = ArcPointer(0)
    var layers = List[MiddlewareFn]()
    layers.append(MiddlewareFn(_deny))
    var handler = apply_middleware(
        RouteHandler.from_handler(_CountingHandler(calls)), layers^
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(calls[], 0)
    assert_equal(writer.status, 401)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "denied")


def test_empty_middleware_chain_reuses_final_handler() raises:
    var calls = ArcPointer(0)
    var handler = apply_middleware(
        RouteHandler.from_handler(_CountingHandler(calls)), List[MiddlewareFn]()
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(calls[], 1)
    assert_equal(writer.status, 201)


def _owned_layer() -> MiddlewareFn:
    var suffix = String(" captured")

    def callback(
        req: Request, mut writer: ResponseWriter, mut next: RouteHandler
    ) raises {var suffix^}:
        next.handle(req, writer)
        writer.write_string(suffix)

    return MiddlewareFn(callback^)


def test_middleware_capture_survives_factory_and_repeated_calls() raises:
    var calls = ArcPointer(0)
    var layers = List[MiddlewareFn]()
    layers.append(_owned_layer())
    var handler = apply_middleware(
        RouteHandler.from_handler(_CountingHandler(calls)), layers^
    )
    var req = _request()
    for expected in range(1, 4):
        var writer = ResponseWriter(1024)
        handler.handle(req, writer)
        assert_equal(calls[], expected)
        assert_equal(
            String(from_utf8_lossy=Span(writer.body)), "final captured"
        )


def _raise_final(req: Request, mut writer: ResponseWriter) raises:
    raise Error("final failed")


def test_middleware_preserves_error_and_skips_normal_after_step() raises:
    var events = ArcPointer(List[String]())

    def layer(
        req: Request, mut writer: ResponseWriter, mut next: RouteHandler
    ) raises {var events}:
        events[].append("before")
        next.handle(req, writer)
        events[].append("after")

    var layers = List[MiddlewareFn]()
    layers.append(MiddlewareFn(layer^))
    var handler = apply_middleware(RouteHandler(_raise_final), layers^)
    var req = _request()
    var writer = ResponseWriter(1024)
    var raised = False
    try:
        handler.handle(req, writer)
    except error:
        raised = True
        assert_equal(String(error), "final failed")
    assert_true(raised)
    assert_equal(len(events[]), 1)
    assert_equal(events[][0], "before")


def _raise_layer(
    req: Request, mut writer: ResponseWriter, mut next: RouteHandler
) raises:
    raise Error("layer failed")


def test_error_before_next_does_not_invoke_final() raises:
    var calls = ArcPointer(0)
    var layers = List[MiddlewareFn]()
    layers.append(MiddlewareFn(_raise_layer))
    var handler = apply_middleware(
        RouteHandler.from_handler(_CountingHandler(calls)), layers^
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    var raised = False
    try:
        handler.handle(req, writer)
    except error:
        raised = True
        assert_equal(String(error), "layer failed")
    assert_true(raised)
    assert_equal(calls[], 0)


@fieldwise_init
struct _DropCapture(Movable):
    var drops: ArcPointer[Int]

    def __deinit__(deinit self):
        self.drops[] += 1


def _make_and_drop_layers(drops: ArcPointer[Int]) raises:
    var layers = List[MiddlewareFn]()
    for _ in range(3):
        var token = _DropCapture(drops)

        def layer(
            req: Request, mut writer: ResponseWriter, mut next: RouteHandler
        ) raises {var token^}:
            assert_equal(token.drops[], 0)
            next.handle(req, writer)

        layers.append(MiddlewareFn(layer^))
    var handler = apply_middleware(RouteHandler(_raise_final), layers^)
    var req = _request()
    var writer = ResponseWriter(1024)
    try:
        handler.handle(req, writer)
    except:
        pass


def test_middleware_captures_are_destroyed_exactly_once() raises:
    var drops = ArcPointer(0)
    _make_and_drop_layers(drops)
    assert_equal(drops[], 3)


@fieldwise_init
struct _LogRecord(Copyable):
    var method: String
    var path: String
    var status: Int
    var elapsed_ns: Int


@fieldwise_init
struct _MemoryLogSink(LogSink):
    var records: ArcPointer[List[_LogRecord]]

    def record(
        mut self,
        method: StringSlice,
        path: StringSlice,
        status: Int,
        elapsed_ns: Int,
    ):
        self.records[].append(
            _LogRecord(String(method), String(path), status, elapsed_ns)
        )


def test_logging_records_status_without_changing_response() raises:
    var calls = ArcPointer(0)
    var records = ArcPointer(List[_LogRecord]())
    var handler = LoggingHandler[_CountingHandler, _MemoryLogSink](
        _CountingHandler(calls), _MemoryLogSink(records)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(calls[], 1)
    assert_equal(writer.status, 201)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "final")
    assert_equal(len(records[]), 1)
    assert_equal(records[][0].method, "GET")
    assert_equal(records[][0].path, "/")
    assert_equal(records[][0].status, 201)
    assert_true(records[][0].elapsed_ns >= 0)


struct _FailingHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.set_status(418)
        writer.headers.add("X-Discard", "header")
        writer.add_trailer("X-Discard-Trailer", "trailer")
        writer.write_string("discarded")
        raise Error("handler failed")


def test_logging_records_failure_and_preserves_exception() raises:
    var records = ArcPointer(List[_LogRecord]())
    var handler = LoggingHandler[_FailingHandler, _MemoryLogSink](
        _FailingHandler(), _MemoryLogSink(records)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    var raised = False
    try:
        handler.handle(req, writer)
    except error:
        raised = True
        assert_equal(String(error), "handler failed")
    assert_true(raised)
    assert_equal(len(records[]), 1)
    assert_equal(records[][0].status, 500)


def test_recover_replaces_partial_response() raises:
    var handler = RecoverHandler[_FailingHandler](_FailingHandler())
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(writer.status, 500)
    assert_equal(
        String(from_utf8_lossy=Span(writer.body)), "500 Internal Server Error"
    )
    assert_equal(len(writer.headers), 0)
    assert_equal(len(writer.trailers), 0)


def test_recover_preserves_successful_response() raises:
    var calls = ArcPointer(0)
    var handler = RecoverHandler[_CountingHandler](_CountingHandler(calls))
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(writer.status, 201)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "final")


def _recover_with_budget(budget: SharedBufferBudget) raises:
    var handler = RecoverHandler[_FailingHandler](_FailingHandler())
    var req = _request()
    var writer = ResponseWriter(1024)
    writer._set_body_budget(budget.copy())
    handler.handle(req, writer)
    assert_equal(budget.used(), 17 + writer.body.capacity())
    assert_equal(
        String(from_utf8_lossy=Span(writer.body)), "500 Internal Server Error"
    )


def test_recover_refunds_discarded_buffers_and_preserves_foreign_budget() raises:
    var budget = SharedBufferBudget(8192)
    assert_true(budget.try_reserve(17))
    _recover_with_budget(budget)
    assert_equal(budget.used(), 17)
    budget.release(17)
    assert_equal(budget.used(), 0)


def test_timeout_before_call_skips_handler() raises:
    var calls = ArcPointer(0)
    var handler = TimeoutHandler[_CountingHandler](
        _CountingHandler(calls), Timeout.nanoseconds(0)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(calls[], 0)
    assert_equal(writer.status, 503)
    assert_equal(
        String(from_utf8_lossy=Span(writer.body)), "503 Service Unavailable"
    )


struct _SlowHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.headers.add("X-Discard", "slow")
        writer.write_string("discarded")
        sleep(0.01)


def test_timeout_after_call_replaces_partial_response() raises:
    var handler = TimeoutHandler[_SlowHandler](
        _SlowHandler(), Timeout.milliseconds(1)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(writer.status, 503)
    assert_equal(
        String(from_utf8_lossy=Span(writer.body)), "503 Service Unavailable"
    )
    assert_equal(len(writer.headers), 0)


def test_timeout_preserves_response_within_deadline() raises:
    var calls = ArcPointer(0)
    var handler = TimeoutHandler[_CountingHandler](
        _CountingHandler(calls), Timeout.seconds(1)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    assert_equal(calls[], 1)
    assert_equal(writer.status, 201)
    assert_equal(String(from_utf8_lossy=Span(writer.body)), "final")


def test_timeout_preserves_inner_exception() raises:
    var handler = TimeoutHandler[_FailingHandler](
        _FailingHandler(), Timeout.seconds(1)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    var raised = False
    try:
        handler.handle(req, writer)
    except error:
        raised = True
        assert_equal(String(error), "handler failed")
    assert_true(raised)


def _timeout_with_budget(budget: SharedBufferBudget) raises:
    var handler = TimeoutHandler[_SlowHandler](
        _SlowHandler(), Timeout.milliseconds(1)
    )
    var req = _request()
    var writer = ResponseWriter(1024)
    writer._set_body_budget(budget.copy())
    handler.handle(req, writer)
    assert_equal(budget.used(), 17 + writer.body.capacity())
    assert_equal(
        String(from_utf8_lossy=Span(writer.body)), "503 Service Unavailable"
    )


def test_timeout_refunds_discarded_buffers() raises:
    var budget = SharedBufferBudget(8192)
    assert_true(budget.try_reserve(17))
    _timeout_with_budget(budget)
    assert_equal(budget.used(), 17)
    budget.release(17)
    assert_equal(budget.used(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
