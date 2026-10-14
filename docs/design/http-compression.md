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
Detached responses are unchanged by the middleware; explicit streaming compression uses `detach_compressed` below.

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

## Detached streams

```mojo
var sender = writer.detach_compressed(
    req, CompressionConfig.default(),
    Optional[String]("build/compression/libnet_zlib"),
)
sender.start(200, headers^)
```

The returned `CompressingSender` is movable and owns the request path, method decision, and encoding negotiation snapshot.
It retains no borrowed request body, headers, or writer reference.
It can be moved to a producer thread; sockets and protocol adapters remain on the server actor.

`start` applies the same response status, content type, extension, existing encoding, and request negotiation rules.
An absent provider passes through headers and source bytes.
Known source lengths below `min_size` stay identity.
Explicit unknown-length streams opt into gzip regardless of their eventual total size, because that size is unavailable when headers commit.
A selected gzip stream removes source Content-Length from its wire headers and validates the declared source count independently.
Compressed wire length remains unknown, allowing normal HTTP/1.1 chunking or HTTP/2 and HTTP/3 DATA framing with trailers.
A known source length can accompany gzip trailers because it is not retained as wire Content-Length.

Each selected gzip sender reserves one input buffer and one output buffer of `buffer_size` bytes before allocating them.
Both stay charged while source or compressed bytes remain pending.
The native libz state is a separate bounded provider allocation.
Successful finish, abort, cancellation observation, or sender destruction releases the buffers.

`send(source)` accepts at most `buffer_size` source bytes for gzip.
`True` means the source has been copied into owned storage, including when its compressed output is still pending.
`False` means the new source was not accepted; retry that same source after the actor makes progress.
The sender drains prior input and output before accepting another chunk, and splits compressed output to the underlying queue limit.
Identity pass-through uses the existing `ResponseSender.try_send` contract, so its source chunks must fit the underlying queue.
Check `is_cancelled()` when send returns False.

`finish(trailers)` returns False while footer bytes await queue capacity and True once the footer and terminal trailers have been queued.
Supply trailers only on the first call; retry with `finish()`.
No new source is accepted after the first finish attempt.
The source count must exactly match a declared length before finish begins.
Invalid length, provider errors, or forbidden trailers abort the response.
`abort()` cancels pending producer output through the existing detached actor.

The encoder can retain source internally until it has enough data to emit a deflate block.
`send` does not promise a per-chunk flush; `finish` completes the gzip member.
