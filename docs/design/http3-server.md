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
field-section limit. Pending response field and body bytes are capped at 64 MiB
across the provider; a stream that exceeds this queue budget is reset with
`H3_EXCESSIVE_LOAD`. Quiche transport memory is estimated separately (see
limits below; [PR #75](https://github.com/hirokazumiyaji/net-mojo/pull/75)) and
does not share those 64 MiB application queue caps.

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
second GOAWAY after a short interval advertising the first rejected request
stream (`last_accepted + 4`, or `0` when none were accepted). Streams at or
above that final boundary receive `H3_REQUEST_REJECTED`. The server keeps the
UDP endpoint active during the configured grace period, sends a QUIC close with
`H3_NO_ERROR` when the period ends, and continues driving transport timers and
packets until the provider reports the connections closed or the drain cap
expires.

## Remaining protocol work

The QUIC engine supplies HTTP/3 control and QPACK behavior; the application does
not implement duplicate control streams or a second QPACK implementation.
Interoperability coverage currently uses aioquic 1.3.0 and quiche. Issue #42
remaining PRs close the previously open gaps on sibling branches (not all
present in every worktree tip):

| Item | Status |
| --- | --- |
| Duplicate / reorder / NAT rebinding stress | Done — [PR #74](https://github.com/hirokazumiyaji/net-mojo/pull/74) |
| Soft quiche transport-memory admission | Done — [PR #75](https://github.com/hirokazumiyaji/net-mojo/pull/75) |
| UDP send would-block preserves pending datagrams | Done — [PR #76](https://github.com/hirokazumiyaji/net-mojo/pull/76) |
| Opt-in HTTPS `Alt-Svc` + same-origin TCP/UDP docs | Done — [PR #77](https://github.com/hirokazumiyaji/net-mojo/pull/77) + this ops PR |
| Application datagram reorder + reset-storm siblings | Done — [PR #78](https://github.com/hirokazumiyaji/net-mojo/pull/78) |
| Measured H2/H3 / multiplex benches | Done — [PR #79](https://github.com/hirokazumiyaji/net-mojo/pull/79)–[#81](https://github.com/hirokazumiyaji/net-mojo/pull/81) |

Still deferred / out of scope for #42: server push, CONNECT, enabling 0-RTT,
broader independent-client matrices beyond aioquic/quiche, and CI workflow edits.
(macOS end-to-end Mojo HTTP/3 validation already runs in CI via the `http3`
job on macos-14 with `http3-client-test`.)

Closed or timed-out QUIC connections are removed with their connection-ID
routes, pending request routes, and queued completed requests. New connections
are capped by `ServerConfig.max_connections`. Request-body buffering and
pending response fields and bodies each have a 64 MiB aggregate provider cap.
Quiche does not expose allocator-backed transport memory in `stats()`, so the
provider reports a soft estimate of `connections.len() × 256 KiB` and refuses
new Initial packets when accepting another connection would exceed
`ServerConfig.quic_max_transport_memory_bytes` (default 2,621,440,000 bytes = 10,000 × 256 KiB, aligned with
10,000 connections; [PR #75](https://github.com/hirokazumiyaji/net-mojo/pull/75)).
Existing connections continue to drain normally when the budget is exhausted.
