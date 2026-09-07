"""Shared request semantics for HTTP/1.1, HTTP/2, and HTTP/3.

The wire format stays protocol-specific (`_parser` for HTTP/1.1,
`_http2/` and `_http3/` later), but every protocol adapts into this
shape before calling the handler:

- `method` is the raw token (`GET`, `POST`, custom tokens allowed).
- `target` is the raw request target, `path` and `query` split on the
  first `?` with no percent decoding applied.
- `scheme` and `authority` carry the HTTP/2 and HTTP/3 pseudo-header
  values. HTTP/1.1 adapters fill `authority` from the absolute-form
  authority or the `Host` header, and leave `scheme` as `"http"`.
- `trailers` are kept separate from `headers` and never affect
  framing or routing.
"""

from .headers import Headers


@fieldwise_init
struct HttpVersion(Copyable, Equatable, Writable):
    var value: UInt8

    @staticmethod
    def http10() -> Self:
        return Self(value=0)

    @staticmethod
    def http11() -> Self:
        return Self(value=1)

    def is_supported(self) -> Bool:
        return self.value == 1

    def write_to[W: Writer](self, mut writer: W):
        if self.value == 0:
            writer.write("HTTP/1.0")
        else:
            writer.write("HTTP/1.1")


struct Request(Movable):
    """Borrowed request views, valid only for the handler call.

    The server owns the receive buffer and never moves, grows, or
    reuses it while the handler runs. Copy out anything to keep.
    The full bounded body is received before the handler runs; there
    is no request streaming in this phase.
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


def split_path_query(
    target: StringSlice,
) -> Tuple[String, String]:
    """Splits `path?query` on the first `?` without percent decoding."""
    var bytes = target.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("?")):
            var path = String(from_utf8_lossy=bytes[0:i])
            var query = String(from_utf8_lossy=bytes[i + 1 : len(bytes)])
            return path^, query^
    return String(target), String("")
