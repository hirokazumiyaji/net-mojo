# HTTP/3 server implementation

## Protocol boundary

`net.http.Server` owns the UDP socket and drives readiness, datagram receive and
send, and provider timers from its event loop. `QuicServer` is a Rust provider
behind the optional C ABI artifact. It owns QUIC connections and delegates HTTP/3
framing, QPACK, stream flow control, and transport recovery to quiche 0.29.3.
The provider returns a request record to Mojo; the HTTP server maps it
to the shared `Request`, invokes the same synchronous `Handler` used by HTTP/1.1
and HTTP/2. Buffered responses and detached producer messages remain bound to
the originating request ID.

The provider receives datagrams with their local and remote addresses and sends
one pending datagram at a time with its destination. Mojo keeps UDP socket
ownership and retries queued output when the socket becomes writable. Provider
timeouts are exposed as microseconds and advanced by the server loop.

## Request mapping and limits

The adapter requires `:method`, `:scheme`, `:authority`, and `:path`, validates
pseudo-header ordering and uniqueness, and maps them to `Request` fields. Regular
headers and trailers remain separate. CONNECT, extended CONNECT, connection-
specific fields, and invalid `TE` values are rejected. By default a request body
is fully buffered before the shared handler runs.

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

## Provider request input streaming

The provider keeps full-body buffering as its default. Direct provider users
can call `QuicUDPEndpoint.set_request_streaming(True)` before the first
connection, then use `try_next_request_head()` to receive a validated head
without waiting for DATA or FIN. Head records use the same request ID and field
encoding as buffered requests, with empty body and trailer fields.

`read_body(id, output)` copies at most the caller's output capacity and returns
`QuicBodyReadResult`. Its state is `data`, `would_block`, `eof`, or `cancelled`;
only `data` has a positive count. A zero-length span with valid backing storage
probes EOF or cancellation without consuming DATA. Reads are
bounded by the per-request limit on bytes copied but not yet consumed, allowing
the total upload to exceed that limit as the application makes progress. The
provider leaves additional DATA in quiche's bounded receive pool.

DATA credit is held after the copy. The application calls
`consume_body(id, count)` after consuming or discarding those bytes. This returns
both QUIC stream and connection receive credit. HTTP framing and QPACK control
bytes retain immediate credit. A count greater than the outstanding DATA debt
is rejected without changing credit.

`body_trailers(id)` becomes available after a read reports EOF. Initial headers,
trailers, and input progress remain owned independently of the response route;
sending response FIN does not retire input. Keep the input ID until queued body
bytes have been consumed, then call `release_body(id)`. Releasing unfinished
input discards its remaining receive side through STOP_SENDING while leaving
response output available. `release_body(id, cancel=True)` cancels both sides.
Reset, STOP_SENDING on active output, invalid trailers, body timeout, and
connection teardown cancel input and refund retained metadata and DATA debt.
The body timeout advances on DATA readiness, positive reads, and consumption.

At the C boundary, `net_quic_read_body` returns positive byte counts, zero for
EOF, -1 for would-block, -2 for cancellation, and -3 for invalid arguments.
Head and trailer record functions return a negative required capacity when the
output is too small and preserve the record for retry. Configuration,
consumption, and release return 1 on success and -1 on rejection. The Mojo
wrapper converts read statuses into the typed result above.

## Server request input streaming

Set `ServerConfig.enable_request_body_streaming = True` before constructing the
server. The handler runs after validated initial headers, with empty `req.body`
and a bounded body reader. `req.detach_body()` transfers the receiver to a worker
independently of response output. Response FIN does not end an accepted upload;
a detached receiver can continue reading DATA and trailers afterward.

The server reserves body queue capacity from `max_total_buffer_bytes`, copies at
most 4 KiB per input per turn, and returns native receive credit only after the
reader consumes or discards those bytes. A full queue pauses DATA copying while
still observing EOF, resets, and body deadlines. Unclaimed input is discarded
when the handler returns. Invalid trailers or an exhausted trailer budget cancel
that stream while sibling requests continue.

Shutdown refuses new requests and lets accepted input finish during the grace
period. Expiry cancels unfinished receivers. Run the independent client cases
with `pixi run -e tls-http3 http3-request-stream-test`.

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

## Response trailers

When `ResponseWriter.trailers` is non-empty on a body-capable status, the
provider receives both the body and a trailer section. Non-empty trailer
sections flip the `fin` flag on the final `send_response` / `send_body`
call to `false`, and the provider finishes the stream by calling
`send_additional_headers(conn, stream_id, headers, is_trailer_section=true,
fin=true)` once the body has been written. Trailer field names normalize the
same way response header names do, and trailer wire bytes are reserved
against the shared `buffered_response_bytes` budget on enqueue so a
rejected or completed stream releases both sections together. HEAD and
non-body statuses drop trailers before the request reaches the provider.

## Detached responses

`ResponseWriter.detach()` gives the producer a `ResponseSender` bound to one
HTTP/3 request ID. The server loop owns the native stream. Producers may queue
one buffered `respond`, or `start`, ordered `send` chunks and `finish` with
optional trailers. No HTTP/3 DATA frame ends the stream before `finish`; HEAD
and bodyless statuses discard payload and trailers while still awaiting the
producer's explicit finish.

The shared server budget charges detached state, actor and message arrays,
header storage, serialized field sections and retained chunk capacities. A
chunk stays owned by its actor until quiche accepts every byte. Partial writes
advance an offset; accepted bytes restore `stream_queue_limit` credit, and the
capacity ticket is released when the entire chunk is dropped. A full queue
makes `send` return false, letting producers retry without changing byte order.
Native response watches, field sections and transport send storage retain their
separate provider budgets.

Trailers share the configured response header count and byte limits with the
initial fields, reject forbidden names, and are queued only after all body
chunks are accepted. Invalid initial responses become a minimal 500 when the
native response has not started. Later encoding or budget failures cancel only
the originating stream with `H3_INTERNAL_ERROR`; explicit abort, peer
cancellation and producer timeout use `H3_REQUEST_CANCELLED`.

The actor's `detached_response_timeout` refreshes on producer messages and
accepted body bytes. Native write deadlines cover pending headers and the
queued final FIN or trailer section; an open producer with no native write
pending does not inherit that deadline. The reactor wait includes producer
deadlines. Peer RESET_STREAM, STOP_SENDING, connection loss and shutdown expiry
cancel the sender and release its mailbox and owned chunks. A successful final
write releases the actor without marking its sender cancelled.

`pixi run -e tls-http3 http3-detach-test` checks concurrent deferred and sibling
responses, ordered chunks, trailers, HEAD completion, withheld stream credit,
backpressure recovery, sustained progress, cancellation before response start,
STOP_SENDING, timeout, header fallback and complete Mojo budget refund.

## Current verification

The Rust provider test drives a Mojo server over localhost UDP using a separate
quiche client connection. It confirms TLS negotiation with ALPN `h3`, dispatch
to the shared handler, two concurrent request streams on one connection,
stream-specific responses, and request trailer visibility through
`Request.trailers`. A dedicated unit test exercises `enqueue_response` with a
trailer section and verifies the aioquic client observes the trailer HEADERS
after the body. A pinned aioquic client independently verifies concurrent
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
| Multiplex matrix + special scenarios | Partially done — [PR #81](https://github.com/hirokazumiyaji/net-mojo/pull/81) records the H2/H3 throughput matrix and specials for Go/aioquic. The current H3 slow/cancel/loss checks pass after reset-credit cleanup; see the 2026-10-04 validation in `benchmarks/http/README.md`. Current-criteria Mojo H2 slow/cancel batch metrics and the netem 16×10 Go-vs-Mojo loss row are in `benchmarks/http/H2_RESULTS.md`, with the multiplex rollup in `benchmarks/http/MULTIPLEX_RESULTS.md`. Formal full-duration comparisons remain pending |

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
