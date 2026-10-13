"""Shared request semantics for HTTP/1.1, HTTP/2, and HTTP/3.

The wire format stays protocol-specific (`_parser` for HTTP/1.1,
`_http2/` for HTTP/2, and the quiche provider for HTTP/3 — there is no
`net/http/_http3/` package), but every protocol adapts into this
shape before calling the handler:

- `method` is the raw token (`GET`, `POST`, custom tokens allowed).
- `target` is the raw request target, `path` and `query` split on the
  first `?` with no percent decoding applied.
- `scheme` and `authority` carry the HTTP/2 and HTTP/3 pseudo-header
  values. HTTP/1.1 adapters fill `authority` from the absolute-form
  authority or the `Host` header. Their `scheme` describes the local
  connection: `"http"` for plaintext and `"https"` for TLS, regardless
  of the scheme written in an absolute-form target.
- `trailers` are kept separate from `headers` and never affect
  framing or routing.
"""

from .headers import Headers
from std.memory import ArcPointer
from ._body_pipe import _BodyPipe, _copy_body_trailers
from net.error import NetError, NetErrorKind
from net import Timeout


@fieldwise_init
struct HttpVersion(Copyable, Equatable, Writable):
    var value: UInt8

    @staticmethod
    def http10() -> Self:
        return Self(value=0)

    @staticmethod
    def http11() -> Self:
        return Self(value=1)

    @staticmethod
    def http2() -> Self:
        return Self(value=2)

    @staticmethod
    def http3() -> Self:
        return Self(value=3)

    def is_supported(self) -> Bool:
        return self.value == 1 or self.value == 2 or self.value == 3

    def write_to[W: Writer](self, mut writer: W):
        if self.value == 0:
            writer.write("HTTP/1.0")
        elif self.value == 1:
            writer.write("HTTP/1.1")
        elif self.value == 2:
            writer.write("HTTP/2")
        elif self.value == 3:
            writer.write("HTTP/3")
        else:
            # Never misidentify an unsupported version as HTTP/1.1 in diagnostics.
            writer.write("HTTP/unknown")


struct RequestBodyReceiver(Movable):
    """Owned receive endpoint for one detached worker, independent of Request.
    """

    var _pipe: _BodyPipe

    def __init__(out self, var pipe: _BodyPipe):
        self._pipe = pipe^

    def __deinit__(deinit self):
        try:
            self._pipe.discard()
        except:
            pass

    def receive[
        origin: MutOrigin
    ](
        mut self,
        buffer: Span[mut=True, Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        return self._pipe.receive(buffer, timeout)

    def is_eof(self) -> Bool:
        return self._pipe.is_eof()

    def total_decoded(self) -> Int:
        return self._pipe.total_decoded()

    def trailers(self) raises NetError -> Headers:
        return self._pipe.trailers()

    def discard(mut self) raises NetError:
        self._pipe.discard()


@fieldwise_init
struct RequestBody[origin: ImmOrigin](Movable):
    """Borrowed body view; streaming reads never block the event loop.

    Buffered requests retain their existing List and expose it through buffered().
    Their read() returns EOF. Streaming views consume the shared decoded queue;
    temporary emptiness raises timeout, cancellation raises cancelled.
    """

    var _request: Pointer[Request, Self.origin]
    var _pipe: Optional[_BodyPipe]
    var _detached: Bool

    def is_streaming(self) -> Bool:
        return Bool(self._pipe)

    def is_eof(self) -> Bool:
        return not self._pipe or self._pipe.value().is_eof()

    def total_decoded(self) -> Int:
        if self._pipe:
            return self._pipe.value().total_decoded()
        return len(self._request[].body)

    def buffered(self) -> Span[Byte, origin_of(self._request[].body)]:
        return Span(self._request[].body)

    def read[
        buffer_origin: MutOrigin
    ](
        mut self, buffer: Span[mut=True, Byte, buffer_origin]
    ) raises NetError -> Int:
        if self._detached:
            raise NetError(
                NetErrorKind.invalid_state(),
                "read request body",
                None,
                "body reader was detached",
            )
        if self._pipe:
            return self._pipe.value().pop(buffer)
        return 0

    def trailers(self) raises NetError -> Headers:
        if self._pipe:
            return self._pipe.value().trailers()
        return _copy_body_trailers(self._request[].trailers)

    def detach(mut self) raises NetError -> RequestBodyReceiver:
        if self._detached or not self._pipe:
            raise NetError(
                NetErrorKind.invalid_state(),
                "detach request body",
                None,
                "body reader cannot be detached",
            )
        self._detached = True
        return RequestBodyReceiver(self._pipe.value().copy())

    def discard(mut self) raises NetError:
        if self._detached:
            raise NetError(
                NetErrorKind.invalid_state(),
                "discard request body",
                None,
                "body reader was detached",
            )
        if self._pipe:
            self._pipe.value().discard()


struct Request(Movable):
    """Owned decoded request fields, borrowed by the handler.

    Copy fields that must outlive the handler call so retained data
    does not depend on the server's request lifetime. StringSlice and
    Span views borrow their source field storage.
    Buffered requests contain the complete bounded body before the handler runs.
    Opt-in streaming requests expose decoded input through body_reader().
    """

    var method: String
    var target: String
    var path: String
    var query: String
    var scheme: String
    var authority: String
    var version: HttpVersion
    var headers: Headers
    var trailers: Headers
    var body: List[Byte]
    var _route_params: ArcPointer[List[Tuple[String, String]]]
    var _body_pipe: Optional[_BodyPipe]

    def __init__(
        out self,
        var method: String,
        var target: String,
        var path: String,
        var query: String,
        version: HttpVersion,
    ):
        self.method = method^
        self.target = target^
        self.path = path^
        self.query = query^
        self.scheme = String("http")
        self.authority = String("")
        self.version = version.copy()
        self.headers = Headers()
        self.trailers = Headers()
        self.body = List[Byte]()
        self._route_params = ArcPointer(List[Tuple[String, String]]())
        self._body_pipe = None

    def body_reader(self) raises NetError -> RequestBody[origin_of(self)]:
        if self._body_pipe:
            self._body_pipe.value().claim_reader()
        return RequestBody(Pointer(to=self), self._body_pipe.copy(), False)


def split_path_query(
    target: StringSlice,
) -> Tuple[String, String]:
    """Splits `path?query` on the first `?` without percent decoding.

    Callers pass ASCII request targets (the parser rejects non-ASCII
    target bytes with 400, since raw non-ASCII bytes are invalid in a
    request-target and must arrive percent-encoded), so the conversion
    below is lossless in practice.
    """
    var bytes = target.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("?")):
            var path = String(from_utf8_lossy=bytes[0:i])
            var query = String(from_utf8_lossy=bytes[i + 1 : len(bytes)])
            return path^, query^
    return String(target), String("")
