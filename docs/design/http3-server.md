# HTTP/3 server implementation

## Protocol boundary

`net.http.Server` owns the UDP socket and drives readiness, datagram receive and
send, and provider timers from its event loop. `QuicServer` is a Rust provider
behind the optional C ABI artifact. It owns QUIC connections and delegates HTTP/3
framing, QPACK, stream flow control, and transport recovery to quiche 0.29.3.
The provider returns a completed request record to Mojo; the HTTP server maps it
to the shared `Request`, invokes the same synchronous `Handler` used by HTTP/1.1
and HTTP/2, then queues the buffered response on the originating stream.

The provider receives datagrams with their local and remote addresses and sends
one pending datagram at a time with its destination. Mojo keeps UDP socket
ownership and retries queued output when the socket becomes writable. Provider
timeouts are exposed as microseconds and advanced by the server loop.

## Request mapping and limits

The adapter requires `:method`, `:scheme`, `:authority`, and `:path`, validates
pseudo-header ordering and uniqueness, and maps them to `Request` fields. Regular
headers and trailers remain separate. CONNECT, extended CONNECT, connection-
specific fields, and invalid `TE` values are rejected. A request body is fully
buffered before the shared handler runs.

Current limits are 100 request header fields and 32 KiB for the combined
request header sections, 1 MiB for each decoded body, and 64 MiB for request
bodies buffered across all active streams and completed requests awaiting Mojo
consumption. The aggregate request-body budget is enforced in the provider
before appending each DATA chunk; an over-budget stream is reset with
`H3_EXCESSIVE_LOAD`. Response headers are limited to 32 KiB and 100 fields, and
response bodies to 1 MiB per response. The provider configures a 32 KiB HTTP/3
field-section limit. Provider response queues and quiche's internal transport
memory do not yet have aggregate accounting. Pending response field and body
bytes are capped at 64 MiB across the provider; a stream that exceeds this
queue budget is reset with `H3_EXCESSIVE_LOAD`.

The QUIC provider uses a 10,000,000 byte connection receive limit, 1,000,000
bytes of bidirectional and unidirectional stream receive credit, an initial
limit of 100 peer-initiated bidirectional streams, and 3 unidirectional streams.
These values are currently fixed in the provider configuration.

## Current verification

The Rust provider test drives a Mojo server over localhost UDP using a separate
quiche client connection. It confirms TLS negotiation with ALPN `h3`, dispatch
to the shared handler, two concurrent request streams on one connection,
stream-specific responses, and request trailer visibility through
`Request.trailers`. A pinned aioquic client independently verifies concurrent
requests, recovery after a dropped client datagram, cancellation, trailers, and
graceful shutdown. C and Mojo FFI smoke tests exercise the provider boundary.

## Graceful shutdown

Shutdown first sends GOAWAY with the maximum request stream ID, then sends a
second GOAWAY after a short interval with the highest request stream ID already
accepted by the server. Streams above that final boundary receive
`H3_REQUEST_REJECTED`. The server keeps the UDP endpoint active during the
configured grace period, sends a QUIC close with `H3_NO_ERROR` when the period
ends, and continues driving transport timers and packets until the provider
reports the connections closed or the drain cap expires.

## Remaining protocol work

The QUIC engine supplies HTTP/3 control and QPACK behavior; the application does
not implement duplicate control streams or a second QPACK implementation.
Interoperability coverage currently uses aioquic 1.3.0 and quiche. Broader
independent-client coverage, loss and reordering stress, cancellation and reset
stress, and aggregate memory bounds remain outstanding. HTTPS Alt-Svc
advertisement and shared TCP/UDP origin setup also remain outstanding. Server
push and CONNECT are not supported.

Closed or timed-out QUIC connections are removed with their connection-ID
routes, pending request routes, and queued completed requests. New connections
are capped by `ServerConfig.max_connections`; request-body buffering and
pending response fields and bodies each have a 64 MiB aggregate provider cap.
quiche transport memory remains outside these budgets and requires separate
accounting.
