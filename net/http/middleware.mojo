"""Owned middleware composition for protocol-independent HTTP handlers."""

from std.memory import OwnedPointer

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
