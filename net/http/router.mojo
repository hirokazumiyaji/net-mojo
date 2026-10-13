"""Bounded method/path patterns for protocol-independent HTTP routing.

Paths and captures retain their wire spelling; no percent decoding or path
cleaning is performed. Specificity compares the sets of requests matched by
each pattern, including GET's implicit HEAD match.
"""

from net.error import NetError, NetErrorKind

from .headers import _is_tchar


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
