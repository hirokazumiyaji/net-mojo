# HTTP response compression

Compression is opt-in. Core-only servers keep their existing response bytes and do not load libz.
Build the optional shim with `pixi run -e compression compression-build` and pass its library path to the middleware:

```mojo
var app = CompressionHandler[App](
    App(), CompressionConfig.default(),
    Optional[String]("build/compression/libnet_zlib"),
)
```

A `None` provider path passes responses through unchanged, including their headers.
An active middleware transforms buffered responses after the inner handler returns.
Detached responses are unchanged.

## Selection and metadata

Gzip is selected from all request `Accept-Encoding` fields using quality values.
An explicit `gzip;q=0` excludes gzip even if a wildcard is present.
No supported coding selects identity.
The defaults use level 5, a minimum body size of 1024 bytes, and 32768-byte encoder chunks.
HEAD, bodyless statuses, partial responses, existing content encodings, and configured compressed media types or extensions skip transformation.
Active middleware adds `Vary: Accept-Encoding` when it is absent, preserving existing values and `Vary: *`.
HEAD retains the identity representation metadata.

Before transformation, a declared Content-Length must match the source body, and cannot coexist with trailers.
The compressed representation removes that source length and adds `Content-Encoding: gzip`.
Each protocol adapter supplies its normal wire framing and compressed length; trailers remain attached to the response.
Header value bytes are preserved, except that strong ETags become weak validators for the equivalent compressed representation.
Existing weak ETags remain unchanged.

## Capacity and limits

The source and the full compression output bound are reserved together before output allocation.
The writer retains its original body until successful replacement.
HTTP/1.1 adopts the replacement reservation; HTTP/2 and HTTP/3 keep their existing adapter admission boundary.
Provider or reservation failure releases temporary capacity and preserves the original body.

The configured response body limit applies to the compressed wire body as well as the source.
An incompressible body near that limit can expand beyond it; compression then raises and the server emits its existing handler-error response.
This option does not increase response limits.

## Validation

`pixi run -e compression compression-suite` runs provider, negotiation, and buffered behavior tests.
`pixi run test-http-compression-pass-through` checks the core-only path.
`pixi run -e http-stream-sse gzip-wire-test` exercises HTTP/1.1, HTTP/2, and HTTP/3 with independent gzip decoding, trailers, lengths, skip rules, and identical compressed bytes.
