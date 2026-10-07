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

The QUIC provider starts with 3,456,106,496 bytes of connection receive credit
and a matching maximum connection window. Each stream starts with 1,000,000
bytes of credit and may grow its receive window to 16 MiB. These are protocol
offset limits, independent of retained memory: provider-wide receive pools
admit at most 64 MiB / 65,536 request entries, 4 MiB / 131,072 control entries,
and 16 MiB / 131,072 CRYPTO entries. Initial peer stream counts remain 100
bidirectional and 3 unidirectional. These bounds do not cover all native send,
recovery, TLS or allocator memory.

## Same-origin operation

`examples/http3_hello.mojo` registers TCP HTTPS and UDP HTTP/3 on
`127.0.0.1:8443` in one `Server`, with one handler and the same certificate/key.
TCP ALPN selects `h2` or `http/1.1`; QUIC negotiates `h3`. TCP and UDP may share
the numeric port because they use separate transports. Both must be reachable
at the public origin when advertising `h3=":8443"`.

Build the optional providers before running the example:

```sh
pixi run -e tls-http2 hpack-test
pixi run -e tls-http3 tls-build
pixi run -e tls-http3 quic-build
pixi run -e tls-http3 mojo run --Werror -I . examples/http3_hello.mojo
```

The generated `build/tls/test-*.pem` inputs are loopback test material. Replace
the certificate/key paths in both `TLSContext.server` and
`QuicProvider.server_config` with deployment inputs for the same hostname.
Creating these contexts loads their certificate material; replacing files does
not reload an existing context. Create new contexts when restarting the server.

For HTTPS-only startup, omit the UDP listener, `QuicProvider` and
`add_quic_endpoint`, and leave `ServerConfig.alt_svc` empty. TLS/HTTP2 can then
run in `tls-http2` without the QUIC provider. Advertisement is application-managed:
setting `alt_svc` causes TLS responses to carry that value even without a local
QUIC endpoint. A handler-provided field takes precedence. Remove the
advertisement when withdrawing the advertised endpoint; its `ma` determines
how long clients may keep a previously advertised alternative.

`ServerConfig.max_connections` applies to endpoint admission. Request, response
and receive limits above are finite; `quic_max_transport_memory_bytes` is a
separate connection-count estimate, not an allocator-backed RSS ceiling. Set
the documented `ServerConfig` limits before registering endpoints. Drive
`tick` on the socket owner and request shutdown through `ServerControl` (or
`server.request_shutdown()` on that owner); keep ticking until it returns false.
The same server drains its TCP responses and QUIC connections, with
`shutdown_grace` defaulting to 30 seconds. See the shutdown contract below and
the [owner-loop example](../../README.md#http11-origin-server).

Dependency pins live in `pixi.toml` / `pixi.lock` and
`net/quic/provider/Cargo.toml` / `Cargo.lock`. Update the provider source checksum
and ordered patches in `scripts/prepare_quiche_source.sh` when changing quiche.
Rebuild TLS, HPACK and QUIC artifacts after changing their dependencies, then
run `tls-suite`, `hpack-mojo-test`, `quic-suite`, `http3-client-test` and the
same-origin task in their documented environments, followed by package smokes.

`pixi run -e tls-http3 http-same-origin-test` exercises real HTTPS and ALPN `h3`
on one host/port, then HTTPS-only startup with that UDP port available to another
socket. Both modes use the shared handler, verify the generated certificate,
and request cooperative shutdown after their responses. This test does not
measure performance or impose an overall process-memory bound.

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

Cancelled request uploads terminate both directions of the QUIC stream. The
provider closes its send direction when it receives a reset, including uploads
that never produced a response, so repeated cancellations return bidirectional
stream credit. An in-memory regression cancels 105 requests against the initial
100-stream allowance and then completes another request on the same connection.
This proves stream-credit and application-request-budget release; it does not
measure the QUIC engine's total retained memory.

The QUIC engine supplies HTTP/3 control and QPACK behavior; the application does
not implement duplicate control streams or a second QPACK implementation.

### QPACK: static-only, blocking impossible by design

Quiche 0.29.3's QPACK decoder has no dynamic-table support (its
`h3::qpack::decoder` module rejects every dynamic reference with
`Error::InvalidHeaderValue`, which the h3 layer converts into a connection
close with `QPACK_DECOMPRESSION_FAILED` = 0x200). The provider therefore
advertises `SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0` and
`SETTINGS_QPACK_BLOCKED_STREAMS = 0` (see
`PROVIDER_QPACK_MAX_TABLE_CAPACITY` / `PROVIDER_QPACK_BLOCKED_STREAMS` in
`net/quic/provider/src/lib.rs`): conformant peers emit only static-table
references and the server owns no QPACK dynamic-table or blocked-section
memory, so the per-connection memory estimate below does not account for a
decoder table. A peer that ignores the advertised zero capacity and emits a
dynamic-table reference triggers the quiche decoder's rejection path; the
server closes the connection with 0x200 and releases the connection state as
part of normal connection teardown. `scripts/test_http3_server.py` includes an
interop scenario that crafts a HEADERS frame referencing dynamic index 0 and
asserts the server closes the connection with 0x200. Enabling a nonzero
capacity would invite dynamic-table references the decoder cannot honor; keep
the invariant until quiche gains a dynamic-table decoder.
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
| Measured H2 / H3 benches | Done — [PR #79](https://github.com/hirokazumiyaji/net-mojo/pull/79)–[#80](https://github.com/hirokazumiyaji/net-mojo/pull/80) |
| Multiplex matrix + special scenarios | Partially done — [PR #81](https://github.com/hirokazumiyaji/net-mojo/pull/81) records the H2/H3 throughput matrix and specials for Go/aioquic. The current H3 slow/cancel/loss checks pass after reset-credit cleanup; see the 2026-10-04 validation in `benchmarks/http/README.md`. H2 Mojo specials, valid H2 loss measurements and formal full-duration comparisons remain pending |

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
