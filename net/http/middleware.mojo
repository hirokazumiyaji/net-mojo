"""Owned middleware composition for protocol-independent HTTP handlers."""

from std.memory import OwnedPointer
from std.time import perf_counter_ns

from net.error import NetError, NetErrorKind
from net.timeout import Timeout, _Deadline

from .handler import Handler
from .request import Request
from .response import ResponseWriter
from .router import RouteHandler, _RouteDrop, _route_drop


comptime _MiddlewareCallback = def(
    Request, mut ResponseWriter, mut RouteHandler
) raises -> None
comptime _MiddlewareInvoke = def(
    Int, Request, mut ResponseWriter, mut RouteHandler
) raises thin -> None


trait _MiddlewareCallable(Movable):
    def call(
        mut self,
        req: Request,
        mut writer: ResponseWriter,
        mut next: RouteHandler,
    ) raises:
        ...


@fieldwise_init
struct _MiddlewareBox[F: Movable & Deinitable](_MiddlewareCallable):
    var callback: Self.F

    def call(
        mut self,
        req: Request,
        mut writer: ResponseWriter,
        mut next: RouteHandler,
    ) raises:
        comptime assert conforms_to(Self.F, _MiddlewareCallback)
        self.callback(req, writer, next)


def _middleware_invoke[
    B: _MiddlewareCallable
](
    address: Int,
    req: Request,
    mut writer: ResponseWriter,
    mut next: RouteHandler,
) raises:
    var pointer = Pointer[B, MutUntrackedOrigin](unsafe_from_address=address)
    pointer[].call(req, writer, next)


struct MiddlewareFn(Movable):
    """Owned before/after callback receiving a borrowed next handler.

    Captures must own their values or refer to storage that outlives the
    composed handler. Call `next.handle(req, writer)` to continue, or return
    without it to produce a response directly.
    """

    var _address: Int
    var _invoke: _MiddlewareInvoke
    var _drop: _RouteDrop

    def __init__[F: _MiddlewareCallback](out self, var callback: F):
        var owner = OwnedPointer(_MiddlewareBox[F](callback^))
        self._address = Int(owner^.unsafe_take_allocation().unsafe_leak())
        self._invoke = _middleware_invoke[_MiddlewareBox[F]]
        self._drop = _route_drop[_MiddlewareBox[F]]

    def __deinit__(deinit self):
        self._drop(self._address)

    def handle(
        mut self,
        req: Request,
        mut writer: ResponseWriter,
        mut next: RouteHandler,
    ) raises:
        self._invoke(self._address, req, writer, next)


@fieldwise_init
struct _MiddlewareLayer(Handler):
    var inner: RouteHandler
    var outer: MiddlewareFn

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.outer.handle(req, writer, self.inner)


def apply_middleware(
    var final: RouteHandler, var layers: List[MiddlewareFn]
) -> RouteHandler:
    """Consumes callbacks in outermost-first order and returns one handler.

    Exceptions propagate through the same call chain. A callback requiring
    cleanup on errors must use its own try/except around `next.handle`.
    """
    while len(layers) > 0:
        var layer = layers.pop()
        final = RouteHandler.from_handler(_MiddlewareLayer(final^, layer^))
    return final^


trait LogSink(Movable):
    def record(
        mut self,
        method: StringSlice,
        path: StringSlice,
        status: Int,
        elapsed_ns: Int,
    ):
        ...


@fieldwise_init
struct StdoutLogSink(LogSink):
    """Writes method, raw path, status and elapsed nanoseconds to stdout."""

    def record(
        mut self,
        method: StringSlice,
        path: StringSlice,
        status: Int,
        elapsed_ns: Int,
    ):
        print(method, path, status, elapsed_ns)


@fieldwise_init
struct LoggingHandler[
    Inner: Handler & Deinitable, Sink: LogSink & Deinitable = StdoutLogSink
](Handler):
    """Logs synchronous handler completion through an owned sink.

    Escaping errors are recorded as status 500 and then rethrown. A detached
    response is logged when the synchronous handler returns; its eventual
    asynchronous response status is outside this wrapper's lifetime.
    """

    var inner: Self.Inner
    var sink: Self.Sink

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var started = perf_counter_ns()
        try:
            self.inner.handle(req, writer)
        except error:
            self.sink.record(
                req.method, req.path, 500, perf_counter_ns() - started
            )
            raise error^
        self.sink.record(
            req.method, req.path, writer.status, perf_counter_ns() - started
        )


def _replace_buffered_response(
    mut writer: ResponseWriter, status: Int, body: StringSlice
) raises NetError:
    writer._drop_body()
    writer._drop_headers()
    if writer._body_budget:
        writer._set_body_budget(writer._body_budget.value().copy())
    writer.set_status(status)
    writer.write_string(body)


@fieldwise_init
struct RecoverHandler[Inner: Handler & Deinitable](Handler):
    """Replaces a failed buffered response with a bounded 500 response.

    Errors after detach propagate to the server so the response owner can
    cancel its asynchronous sender. Fatal process aborts cannot be recovered.
    """

    var inner: Self.Inner

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        try:
            self.inner.handle(req, writer)
        except error:
            if writer.is_detached():
                raise error^
            _replace_buffered_response(writer, 500, "500 Internal Server Error")


@fieldwise_init
struct TimeoutHandler[Inner: Handler & Deinitable](Handler):
    """Checks a synchronous handler's deadline before and after its call.

    This wrapper cannot interrupt blocking work. An expired successful call
    becomes a bounded 503 response after it returns. Inner errors propagate;
    detached responses are unsupported and raise invalid_state.
    """

    var inner: Self.Inner
    var timeout: Timeout

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var deadline = _Deadline.from_timeout(self.timeout)
        if not deadline.expired():
            self.inner.handle(req, writer)
        if writer.is_detached():
            raise NetError(
                NetErrorKind.invalid_state(),
                "timeout handler",
                None,
                "synchronous timeout does not support detached responses",
            )
        if deadline.expired():
            _replace_buffered_response(writer, 503, "503 Service Unavailable")
