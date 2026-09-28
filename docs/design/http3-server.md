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
request header sections, 1 MiB for the decoded body, 32 KiB and 100 fields for
response headers, and 1 MiB for the response body. The provider configures a
32 KiB HTTP/3 field-section limit. These are per request or response limits;
aggregate memory accounting across QUIC connections and streams remains
outstanding.

The QUIC provider uses a 10,000,000 byte connection receive limit, 1,000,000
bytes of bidirectional and unidirectional stream receive credit, an initial
limit of 100 peer-initiated bidirectional streams, and 3 unidirectional streams.
These values are currently fixed in the provider configuration.

## Current verification

The Rust provider test drives a Mojo server over localhost UDP using a separate
quiche client connection. It confirms TLS negotiation with ALPN `h3`, dispatch
to the shared handler, two concurrent request streams on one connection,
stream-specific responses, and request trailer visibility through
`Request.trailers`. C and Mojo FFI smoke tests exercise the provider boundary.

## Remaining protocol work

The QUIC engine supplies HTTP/3 control and QPACK behavior; the application does
not implement duplicate control streams or a second QPACK implementation.
Independent-client interoperability beyond the current quiche client, loss and
reordering coverage, cancellation and reset stress, and aggregate memory bounds
remain outstanding. The server does not yet expose HTTP/3 GOAWAY or graceful
connection drain. HTTPS Alt-Svc advertisement and shared TCP/UDP origin setup
also remain outstanding. Server push and CONNECT are not supported.

Closed or timed-out QUIC connections are removed with their connection-ID
routes, pending request routes, and queued completed requests. The provider does
not yet impose a global connection or queued-request cap.
