"""Bounded method/path patterns for protocol-independent HTTP routing.

Paths and captures retain their wire spelling; no percent decoding or path
cleaning is performed. Specificity compares the sets of requests matched by
each pattern, including GET's implicit HEAD match.
"""

from net.error import NetError, NetErrorKind
from std.memory import OwnedPointer

from .headers import _is_tchar
from .handler import Handler
from .request import Request
from .response import ResponseWriter


comptime _EQUAL = 0
comptime _GENERAL = 1
comptime _SPECIFIC = 2
comptime _DISJOINT = 3
comptime _OVERLAP = 4


@fieldwise_init
struct _Segment(Copyable, Movable):
    var text: String
    var wildcard: Bool
    var rest: Bool


@fieldwise_init
struct _Match(Movable):
    var matched: Bool
    var params: List[Tuple[String, String]]


def _pattern_error(message: String) -> NetError:
    return NetError(
        NetErrorKind.invalid_argument(), "route pattern", None, message
    )


def _combine(left: Int, right: Int) -> Int:
    if left == _DISJOINT or right == _DISJOINT:
        return _DISJOINT
    if left == _EQUAL:
        return right
    if right == _EQUAL or left == right:
        return left
    return _OVERLAP


def _segment_relationship(left: _Segment, right: _Segment) -> Int:
    if left.rest:
        return _EQUAL if right.rest else _GENERAL
    if right.rest:
        return _SPECIFIC
    if left.wildcard and right.wildcard:
        return _EQUAL
    if left.wildcard:
        return _DISJOINT if right.text == "/" else _GENERAL
    if right.wildcard:
        return _DISJOINT if left.text == "/" else _SPECIFIC
    return _EQUAL if left.text == right.text else _DISJOINT


struct Pattern(Copyable, Movable):
    """Compiled method/path pattern with bounded registration storage.

    Limits are 1024 bytes, 32 segments and 16 named captures. A trailing slash
    matches a subtree; `{$}` matches only the final slash. Wildcard names use
    ASCII HTTP token characters and must be unique within the pattern.
    """

    var method: String
    var raw: String
    var segments: List[_Segment]
    var has_trailing_slash: Bool

    def __init__(out self, pattern: StringSlice) raises NetError:
        var data = pattern.as_bytes()
        if len(data) == 0 or len(data) > 1024:
            raise _pattern_error("pattern must contain 1..1024 bytes")
        self.raw = String(pattern)
        self.method = String("")
        self.segments = List[_Segment]()
        self.has_trailing_slash = data[len(data) - 1] == Byte(ord("/"))
        var path_start = 0
        if data[0] != Byte(ord("/")):
            while (
                path_start < len(data)
                and data[path_start] != Byte(ord(" "))
                and data[path_start] != Byte(9)
            ):
                if not _is_tchar(data[path_start]):
                    raise _pattern_error("invalid method token")
                path_start += 1
            if path_start == 0 or path_start == len(data):
                raise _pattern_error("missing method/path separator")
            self.method = String(from_utf8_lossy=data[0:path_start])
            while path_start < len(data) and (
                data[path_start] == Byte(ord(" "))
                or data[path_start] == Byte(9)
            ):
                path_start += 1
        if path_start == len(data) or data[path_start] != Byte(ord("/")):
            raise _pattern_error("path must start with /")
        for i in range(path_start, len(data)):
            if (
                data[i] < 33
                or data[i] > 126
                or data[i] == Byte(ord("?"))
                or data[i] == Byte(ord("#"))
            ):
                raise _pattern_error("invalid path byte")
        var start = path_start + 1
        var captures = 0
        while True:
            if len(self.segments) >= 32:
                raise _pattern_error("more than 32 path segments")
            if start == len(data):
                self.segments.append(_Segment(String(""), True, True))
                break
            var end = start
            while end < len(data) and data[end] != Byte(ord("/")):
                end += 1
            var segment = String(from_utf8_lossy=data[start:end])
            if segment.byte_length() == 0 or segment == "." or segment == "..":
                raise _pattern_error("pattern path is not clean")
            if segment == "{$}":
                if end != len(data):
                    raise _pattern_error("{$} must be the final segment")
                self.segments.append(_Segment(String("/"), False, False))
                break
            if data[start] == Byte(ord("{")):
                if data[end - 1] != Byte(ord("}")):
                    raise _pattern_error("unclosed wildcard")
                var name_end = end - 1
                var rest = False
                if (
                    name_end - start >= 4
                    and data[name_end - 1] == Byte(ord("."))
                    and data[name_end - 2] == Byte(ord("."))
                    and data[name_end - 3] == Byte(ord("."))
                ):
                    rest = True
                    name_end -= 3
                if name_end == start + 1:
                    raise _pattern_error("empty wildcard name")
                if rest and end != len(data):
                    raise _pattern_error(
                        "rest wildcard must be the final segment"
                    )
                for i in range(start + 1, name_end):
                    if not _is_tchar(data[i]):
                        raise _pattern_error("invalid wildcard name")
                var name = String(from_utf8_lossy=data[start + 1 : name_end])
                for existing in self.segments:
                    if existing.wildcard and existing.text == name:
                        raise _pattern_error("duplicate wildcard name")
                captures += 1
                if captures > 16:
                    raise _pattern_error("more than 16 named captures")
                self.segments.append(_Segment(name^, True, rest))
            else:
                if segment.find("{") >= 0 or segment.find("}") >= 0:
                    raise _pattern_error(
                        "wildcard must occupy a complete segment"
                    )
                self.segments.append(_Segment(segment^, False, False))
            if end == len(data):
                break
            start = end + 1

    def matches_method(self, method: StringSlice) -> Bool:
        return (
            self.method == ""
            or self.method == method
            or (self.method == "GET" and method == "HEAD")
        )

    def matches_path(self, path: StringSlice) -> Bool:
        var data = path.as_bytes()
        if len(data) == 0 or data[0] != Byte(ord("/")):
            return False
        var start = 1
        for i in range(len(self.segments)):
            var end = start
            while end < len(data) and data[end] != Byte(ord("/")):
                end += 1
            ref segment = self.segments[i]
            if segment.rest:
                return True
            if segment.text == "/":
                return start == len(data)
            if start == end:
                return False
            if (
                not segment.wildcard
                and segment.text.as_bytes() != data[start:end]
            ):
                return False
            if i == len(self.segments) - 1:
                return end == len(data)
            if end == len(data):
                return False
            start = end + 1
        return False

    def matches(self, method: StringSlice, path: StringSlice) -> _Match:
        var params = List[Tuple[String, String]]()
        if not self.matches_method(method) or not self.matches_path(path):
            return _Match(False, params^)
        var data = path.as_bytes()
        var start = 1
        for segment in self.segments:
            var end = start
            if segment.rest:
                end = len(data)
            else:
                while end < len(data) and data[end] != Byte(ord("/")):
                    end += 1
            if segment.wildcard and segment.text != "":
                params.append(
                    (
                        segment.text.copy(),
                        String(from_utf8_lossy=data[start:end]),
                    )
                )
            if segment.rest:
                break
            start = end + 1
        return _Match(True, params^)

    def _method_relationship(self, other: Self) -> Int:
        if self.method == other.method:
            return _EQUAL
        if self.method == "" or (
            self.method == "GET" and other.method == "HEAD"
        ):
            return _GENERAL
        if other.method == "" or (
            other.method == "GET" and self.method == "HEAD"
        ):
            return _SPECIFIC
        return _DISJOINT

    def _path_relationship(self, other: Self) -> Int:
        var relationship = _EQUAL
        var shared = min(len(self.segments), len(other.segments))
        for i in range(shared):
            relationship = _combine(
                relationship,
                _segment_relationship(self.segments[i], other.segments[i]),
            )
            if relationship == _DISJOINT:
                return relationship
        if len(self.segments) == len(other.segments):
            return relationship
        if (
            len(self.segments) < len(other.segments)
            and self.segments[len(self.segments) - 1].rest
        ):
            return _combine(relationship, _GENERAL)
        if (
            len(other.segments) < len(self.segments)
            and other.segments[len(other.segments) - 1].rest
        ):
            return _combine(relationship, _SPECIFIC)
        return _DISJOINT

    def _relationship(self, other: Self) -> Int:
        return _combine(
            self._method_relationship(other), self._path_relationship(other)
        )

    def more_specific_than(self, other: Self) -> Bool:
        return self._relationship(other) == _SPECIFIC

    def conflicts_with(self, other: Self) -> Bool:
        var relationship = self._relationship(other)
        return relationship == _EQUAL or relationship == _OVERLAP


comptime _Callback = def(Request, mut ResponseWriter) raises -> None
comptime _RouteInvoke = def(
    Int, Request, mut ResponseWriter
) raises thin -> None
comptime _RouteDrop = def(Int) thin -> None


@fieldwise_init
struct _CallbackHandler[F: Movable & Deinitable](Handler):
    var callback: Self.F

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        comptime assert conforms_to(Self.F, _Callback)
        self.callback(req, writer)


def _route_invoke[
    H: Handler
](address: Int, req: Request, mut writer: ResponseWriter) raises:
    var pointer = Pointer[H, MutUntrackedOrigin](unsafe_from_address=address)
    pointer[].handle(req, writer)


def _route_drop[H: Movable & Deinitable](address: Int):
    _ = OwnedPointer[H](
        unsafe_from_raw_pointer=Pointer[H, MutUntrackedOrigin](
            unsafe_from_address=address
        )
    )


struct RouteHandler(Handler, Movable):
    """Owned callback with runtime dispatch.

    Callbacks must own their captures; use copy or move captures rather than
    borrowing stack values that can disappear before the mux. Captured views
    must refer to storage that remains alive for the handler's lifetime.
    """

    var _address: Int
    var _invoke: _RouteInvoke
    var _drop: _RouteDrop

    def __init__[F: _Callback](out self, var callback: F):
        var owner = OwnedPointer(_CallbackHandler[F](callback^))
        self._address = Int(owner^.unsafe_take_allocation().unsafe_leak())
        self._invoke = _route_invoke[_CallbackHandler[F]]
        self._drop = _route_drop[_CallbackHandler[F]]

    def __init__(
        out self, address: Int, invoke: _RouteInvoke, drop: _RouteDrop
    ):
        self._address = address
        self._invoke = invoke
        self._drop = drop

    @staticmethod
    def from_handler[H: Handler & Deinitable](var handler: H) -> Self:
        var owner = OwnedPointer(handler^)
        return Self(
            Int(owner^.unsafe_take_allocation().unsafe_leak()),
            _route_invoke[H],
            _route_drop[H],
        )

    def __deinit__(deinit self):
        self._drop(self._address)

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self._invoke(self._address, req, writer)


@fieldwise_init
struct _Route(Movable):
    var pattern: Pattern
    var handler: RouteHandler


struct ServeMux(Handler, Movable):
    """Bounded route table shared by HTTP/1.1, HTTP/2 and HTTP/3.

    Register routes before serving. A mux belongs to one event loop and its
    owned handlers are invoked sequentially. Parameters retain raw bytes and
    are available only while a selected route runs.
    """

    var _routes: List[_Route]
    var _max_routes: Int

    def __init__(out self, max_routes: Int = 1024) raises NetError:
        if max_routes < 1:
            raise _pattern_error("route capacity must be positive")
        self._routes = List[_Route]()
        self._max_routes = max_routes

    def handle[
        F: _Callback
    ](mut self, pattern: StringSlice, var callback: F) raises NetError:
        self.register(pattern, RouteHandler(callback^))

    def handle[
        H: Handler & Deinitable
    ](mut self, pattern: StringSlice, var handler: H) raises NetError:
        self.handle_handler(pattern, handler^)

    def handle_handler[
        H: Handler & Deinitable
    ](mut self, pattern: StringSlice, var handler: H) raises NetError:
        self.register(pattern, RouteHandler.from_handler(handler^))

    def register(
        mut self, pattern: StringSlice, var handler: RouteHandler
    ) raises NetError:
        if len(self._routes) == self._max_routes:
            raise _pattern_error("route capacity exceeded")
        var compiled = Pattern(pattern)
        for index in range(len(self._routes)):
            ref route = self._routes[index]
            if compiled.conflicts_with(route.pattern):
                raise _pattern_error("ambiguous or duplicate route")
        self._routes.append(_Route(compiled^, handler^))

    @staticmethod
    def param(req: Request, name: StringSlice) -> Optional[String]:
        for entry in req._route_params[]:
            if entry[0] == name:
                return Optional(entry[1].copy())
        return None

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        var best = -1
        var path_matched = False
        for index in range(len(self._routes)):
            ref pattern = self._routes[index].pattern
            if not pattern.matches_path(req.path):
                continue
            path_matched = True
            if pattern.matches_method(req.method) and (
                best == -1
                or pattern.more_specific_than(self._routes[best].pattern)
            ):
                best = index
        if best == -1:
            if path_matched:
                writer.set_status(405)
                writer.headers.add("Allow", self._allowed_methods(req.path))
                writer.write_string("method not allowed")
            else:
                writer.set_status(404)
                writer.write_string("not found")
            return
        var matched = self._routes[best].pattern.matches(req.method, req.path)
        var previous = req._route_params[].copy()
        req._route_params[] = matched.params^
        matched.params = List[Tuple[String, String]]()
        try:
            self._routes[best].handler.handle(req, writer)
        except e:
            req._route_params[] = previous^
            raise e^
        req._route_params[] = previous^

    def _allowed_methods(self, path: StringSlice) -> String:
        var methods = List[String]()
        for index in range(len(self._routes)):
            ref route = self._routes[index]
            if route.pattern.matches_path(path):
                self._insert_method(methods, route.pattern.method)
                if route.pattern.method == "GET":
                    self._insert_method(methods, "HEAD")
        var result = String("")
        for method in methods:
            if result != "":
                result += ", "
            result += method
        return result^

    @staticmethod
    def _insert_method(mut methods: List[String], method: String):
        var index = 0
        while index < len(methods) and methods[index] < method:
            index += 1
        if index == len(methods) or methods[index] != method:
            methods.insert(index, method.copy())
