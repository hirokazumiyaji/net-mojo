# Issue #42 implementation progress

- [x] Expose negotiated HTTP/2 peer SETTINGS as an immutable snapshot.
- [x] Add a post-bootstrap HTTP/2 control-frame dispatcher with continuation sequencing and bounded frame parsing.
- [x] Add a bounded incremental reader for post-bootstrap HTTP/2 frames.
- [x] Preserve HEADERS metadata across CONTINUATION for request assembly.
- [x] Assemble HTTP/2 connection frames into bounded shared Request values.
- [x] Defer optional HPACK loading until the first request headers arrive.
- [x] Connect ALPN `h2` to the server's shared handler path.
- [x] Respect HTTP/2 connection and stream receive flow-control windows; cap responses to available outbound credit.
- [x] Integrate concurrent HTTP/2 request streams, flow control, and response scheduling.
- [x] Build an optional quiche dependency and validate its C/Mojo FFI entry points.
- [x] Exercise an HTTP/3 TLS handshake across in-memory QUIC packet exchange.
- [x] Integrate QUIC packet I/O, timers, HTTP/3 streams, and the shared handler with the server.
- [ ] Complete protocol interoperability, docs, CI, and performance validation.

## Review

- The SETTINGS snapshot is committed as `d21563b` and passed the 90-test HTTP/2 suite on x86_64 and aarch64.
- The frame-dispatch slice passed 93 HTTP/2 tests on Linux x86_64 and aarch64 and is committed as `11fee1b`.
- The incremental frame-reader slice passed 95 HTTP/2 tests on Linux x86_64 and aarch64 and is committed as `a93c81b`.
- The connection-input slice passed 97 HTTP/2 tests on Linux x86_64 and aarch64.
- TLS server bootstrap over ALPN `h2` and HTTP/1.1 passed the TLS suite on Linux x86_64 and aarch64.
- HTTP/1.1 server suite passed 27 tests, and HTTP/2 suite passed 97 tests on Linux x86_64 and aarch64 after connection routing.
- The QUIC packet handshake test passed on Linux x86_64. `quic-suite` now includes this Rust test alongside the C and Mojo provider smoke tests.
- HTTP/2 requests now reach the shared handler and return encoded responses; the TLS integration client verifies request DATA, receive WINDOW_UPDATE frames, response HEADERS/DATA, and a zero peer stream window on x86_64 and aarch64.
- Flow-control slice passed TLS, HPACK (21/21), HTTP/2 (97/97), HTTP server (27/27), Python syntax, and diff checks on Linux x86_64 and aarch64.
- HTTP/2 stream-level outbound WINDOW_UPDATE resumes responses independently; fair scheduling and two-stream TLS integration are committed in `c5902c0`.
- The HTTP/3 shared-handler integration test passed and is committed in `a296c53` and `6c5ae90`; same-connection concurrent request coverage is committed in `e0d0e24`.

## Current slice

- Attach `QuicUDPEndpoint` to `net.http.Server`, drive QUIC timers and HTTP/3 control/request streams, and route completed requests to the shared handler.

## QUIC connection capacity slice

- [x] Add a Rust test that refuses a new Initial packet once the configured connection cap is reached.
- [x] Enforce the connection cap before allocating a QUIC connection or CID routes.
- [x] Pass `ServerConfig.max_connections` through the Mojo endpoint to the provider.
- [x] Run QUIC provider and HTTP server suites, inspect the diff, and commit this slice.

## HTTP/2 oversized request stream slice

- [x] Add a regression test proving an oversized DATA frame resets only its stream and a later stream still completes.
- [x] Return connection-level receive credit and emit a stream reset for the oversized request.
- [x] Run HPACK/HTTP/2 suites, inspect the diff, and commit this slice.

## HTTP/3 provider CI slice

- [x] Add a Linux x86_64 and aarch64 CI job for the QUIC provider suite.
- [x] Validate workflow syntax and confirm the existing local suite passes.
- [x] Inspect the diff and commit this slice.

## HTTP/2 stream limit configuration slice

- [x] Add a `ServerConfig` limit for concurrent streams on each HTTP/2 connection.
- [x] Advertise that limit in server SETTINGS and enforce the same value in admission.
- [x] Test the configured SETTINGS value and stream refusal, then run HTTP/2 suites and HTTPS client interoperability.
- [x] Inspect the diff and commit this slice.

## Independent HTTP/3 client interoperability slice

- [x] Add a pinned aioquic client test against the existing Mojo HTTP/3 fixture.
- [x] Run it in the HTTP/3 CI job and confirm request and trailer behavior.
- [x] Inspect the dependency, lockfile, and diff, then commit this slice.

## HTTP/3 cancel interoperability slice

- [x] Reset a partially sent request stream from an independent aioquic client.
- [x] Confirm two later requests on the same connection still receive their expected responses.
- [x] Inspect the test and commit this slice.

## QUIC handshake packet-loss slice

- [x] Drop the first server handshake datagram in the localhost UDP provider test.
- [x] Drive client and server QUIC timers until the HTTP/3 ALPN handshake completes.
- [x] Inspect the test and commit this slice.

## HTTP/2 idle stream reset conformance slice

- [x] Add request-session tests for future peer IDs and server-initiated idle IDs.
- [x] Reject both forms of idle-stream reset while preserving closed peer-stream cancellation.
- [x] Run HPACK/HTTP/2 suites, inspect the diff, and commit this slice.

## HTTP/2 graceful shutdown session slice

- [x] Add a request-session test for a successful GOAWAY carrying the highest admitted peer stream ID.
- [x] Add a request-session test that shutdown prevents later peer streams from being admitted.
- [x] Implement session shutdown signaling and reject new streams after GOAWAY.
- [x] Run HPACK and HTTP/2 suites, inspect the diff, and commit this slice locally.

## Review

- The session GOAWAY slice passed `hpack-mojo-test` (29/29) and `test-http2` (97/97) in the Linux x86_64 `tls-http2` environment. `git diff --check` passed.

## HTTP/2 server graceful shutdown slice

- [x] Add independent TLS client coverage for server shutdown GOAWAY and a fully drained response.
- [x] Start HTTP/2 session shutdown when the server receives its shutdown request.
- [x] Queue GOAWAY behind pending connection output and retain the existing grace deadline.
- [x] Run TLS, HTTPS interoperability, HPACK, and HTTP/2 suites; inspect the diff.

## Review

- The HTTP/2 shutdown session slice is committed as `44d9c9d`.
- Server graceful shutdown passed `tls-suite`, including independent TLS interoperability; HPACK passed 29/29, HTTP/2 passed 97/97, Python syntax validation and `git diff --check` passed on Linux x86_64.

## HTTP/3 graceful shutdown provider slice

- [x] Add provider-level HTTP/3 shutdown state and GOAWAY retry behavior.
- [x] Verify GOAWAY delivery while retaining a completed request for response handling.
- [x] Run the QUIC provider suite and commit the provider slice locally.

## Review

- The QUIC provider suite passed 4/4 tests on Linux x86_64, including a client receiving the provider's shutdown GOAWAY. The C/Rust provider build also passed.

## HTTP/3 server graceful shutdown integration slice

- [x] Expose provider shutdown through Mojo and notify it when Server shutdown starts.
- [x] Keep the UDP endpoint registered through the configured grace period and continue QUIC close draining until connections close or the drain cap expires.
- [x] Verify GOAWAY delivery after accepted responses complete with an independent client.
- [x] Verify the final GOAWAY boundary, post-GOAWAY rejection, and graceful QUIC close with an independent client.
- [x] Run the QUIC provider, independent HTTP/3 client, and HTTP Server suites; inspect the diff.
- [x] Run HTTP/2 and TLS suites.
- [x] Commit this server integration slice locally as `4cec08a`.

## HTTP/3 final GOAWAY and QUIC close drain slice

- [x] Extend the independent client to require a final GOAWAY at the last accepted request stream ID.
- [x] Reject streams above that final boundary with `H3_REQUEST_REJECTED`.
- [x] Send `H3_NO_ERROR` QUIC close at the shutdown deadline and keep driving the connection until closed or the drain cap.
- [x] Run provider, HTTP/3, HTTP Server, HTTP/2, and TLS suites; inspect the diff.
- [x] Commit this final GOAWAY and QUIC close drain slice locally.

## Review

- The independent aioquic client verified the initial maximum GOAWAY, the final last-accepted-stream GOAWAY, `H3_REQUEST_REJECTED` for a later stream, and `H3_NO_ERROR` connection close.
- QUIC provider suite passed 4/4; HTTP/3 client, HTTP Server 27/27, HTTP/2 97/97, HTTPS client, HTTPS example build, Python syntax, Rust formatting, and `git diff --check` passed on Linux x86_64.
- Follow-up `/review` fixes: model shutdown as ordered states, retry the initial GOAWAY before the final GOAWAY, continue closing other connections when one close fails, skip already draining connections, and report a null shutdown-complete handle as false. Keep `H3_REQUEST_REJECTED` at RFC 9114 value `0x10b`.
- The HTTP/3 provider caps active and queued request bodies at 64 MiB total. Its five Rust provider tests pass on macOS arm64; the Mojo endpoint fixture still crashes in this platform's Mojo runtime.

## HTTP protocol documentation correction slice

- [x] Update README and changelog to describe the implemented HTTP/2 and HTTP/3 support and optional provider environments.
- [x] Replace stale HTTP/2 and HTTP/3 design notes with verified shutdown and interoperability status.
- [x] Verify local documentation links and diff checks; commit this documentation slice locally.

## HTTP/2 provider CI slice

- [x] Add Linux x86_64 and aarch64 CI coverage for the optional HPACK provider and independent TLS HTTP/2 client.
- [x] Parse the workflow YAML, run the configured HTTP/2 tasks locally, and inspect the diff.
- [x] Commit this CI slice locally.

## HTTP/3 aggregate request memory slice

- [x] Add a provider test for aggregate request-body admission and consumption accounting.
- [x] Account request body bytes across QUIC streams until Mojo consumes each completed request.
- [x] Release budget on stream reset, body rejection, request consumption, and connection reaping.
- [x] Run provider tests, HTTP/3 integration where supported, formatting, and diff checks; review before publishing.

## HTTP/3 aggregate response memory slice

- [x] Add a provider test for aggregate response queue admission and completion accounting.
- [x] Bound queued response fields and bodies across all QUIC streams.
- [x] Release the response budget when a stream finishes, resets, or its connection is reaped.
- [x] Run provider tests and checks; review before publishing.

- Request and response queues each have a 64 MiB aggregate provider limit. The Rust suite passed 6/6 on macOS arm64; full `/review` remains pending because the configured OCR review request times out.

## Optional HTTP provider package smoke slice

- [x] Add package smoke tests for the HTTP/2 HPACK and HTTP/3 QUIC providers.
- [x] Run the smoke tasks in the Linux CI provider jobs.
- [x] Verify both packaged provider smokes locally on macOS arm64 and update package docs.

## HTTP/2 and HTTP/3 server examples slice

- [x] Add a TLS/ALPN HTTP/2 example using the shared handler.
- [x] Add a same-numbered TCP HTTPS and UDP HTTP/3 example using the shared handler.
- [x] Build both examples in the optional-provider CI jobs and document their environment requirements.

## HTTP/3 packet loss interoperability slice

- [x] Drop one client QUIC datagram while sending an HTTP/3 request.
- [x] Verify QUIC retransmission recovers the request and later streams complete on the same connection.
- [x] Run the independent aioquic HTTP/3 test and Python syntax check.

## macOS optional HTTP provider CI slice

- [x] Add macOS arm64 to the HTTP/2 and HTTP/3 provider CI matrices.
- [x] Run HTTP/2 protocol 97/97, HPACK 29/29, TLS, and independent-client suites on macOS arm64.
- [x] Confirm HTTP/3 provider and aioquic packet-loss interoperability suites on macOS arm64.

## QUIC transport review

- `QuicServer` accepts Initial datagrams, routes later packets by connection ID, emits pending packets with their destination, and reports/advances connection timeouts.
- A localhost UDP test completed the HTTP/3 TLS handshake through this provider boundary and confirmed ALPN `h3` and a pending connection timeout.
- The Rust provider suite passed on Linux x86_64. The C/Mojo FFI now exposes datagram receive/send and timeout operations while keeping UDP socket ownership with Mojo.
- The TLS/HTTP/2 integration suite passed in the `tls-http2` environment after rebuilding the HPACK shim for Linux x86_64. An earlier run had loaded a stale aarch64 artifact into x86_64; the test itself passed with the correct architecture.
- The HTTP/3 environment now pins Mojo 1.0 to match the TLS/HTTP/2 environments and lockfile, avoiding two Mojo API levels for the shared networking modules.
- `QuicUDPEndpoint` now owns the UDP socket, exposes its descriptor/read-write interest and timeout, drops malformed packets, and retains outgoing packet bytes/destination across a would-block send. Reactor readability and malformed-packet handling are covered in Mojo; forced UDP send-queue saturation remains untested.

## QUIC packet I/O slice

- [x] Define the provider boundary between UDP datagrams, peer addresses, quiche connection state, and next timeout.
- [x] Add a failing localhost UDP test for server handshake packet exchange.
- [x] Implement the smallest provider API that passes that test.
- [x] Run the QUIC provider suite and record the platform and result.
- [x] Commit the packet I/O slice locally.

## Review

- The Rust test first failed to compile because `QuicServer` was absent, then passed after adding datagram receive/send, connection ID routing, and timeout accessors.
- `pixi run -e tls-http3 quic-suite` passed on Linux x86_64: C config smoke, Mojo FFI smoke, and both Rust handshake tests.
- `cargo fmt --check`, test script syntax, and `git diff --check` passed.
- The UDP socket remains caller-owned. The next slice connects these operations to `UDPConn` and the reactor and preserves pending packets across UDP backpressure.

## QUIC UDP endpoint slice

- [x] Add `QuicUDPEndpoint` to own `QuicServer` and `UDPConn` with bounded packet buffers.
- [x] Expose descriptor, write interest, receive/send attempts, and timeout hooks for a reactor owner.
- [x] Confirm reactor readability and malformed datagram handling over localhost UDP.
- [x] Run the full HTTP/3 provider suite on Linux x86_64.
- [x] Review and commit the endpoint slice locally.

## Review

- Mojo endpoint tests register the owned UDP descriptor with `Reactor`, receive and ignore a malformed packet, and confirm no output packet or write interest is pending.
- Send-buffer preservation across `would-block` is implemented, but the current suite does not saturate the local UDP send queue.
- `quic-suite`, Rust format, shell syntax, and `git diff --check` passed on Linux x86_64.

## Review

- HEADERS metadata slice committed as `a883cca`; HPACK 12/12 and HTTP/2 97/97 passed on x86_64 and aarch64.
- Request session commit: `16e95b5`; lazy HPACK initialization commit: `df18735`.
- Request session validation: HPACK 16/16 and HTTP/2 97/97 passed on x86_64 and aarch64.
- Lazy HPACK initialization validation: HPACK suite passed 17/17 on Linux aarch64, including bootstrap with a nonexistent library path.
- HTTP/2 handler and flow-control slice committed as `07ef3ce`.

## QUIC provider selection

- `docs/design/quic-transport.md` compares quiche, ngtcp2 plus nghttp3, and MsQuic; the initial recommendation is quiche because its C API covers QUIC, HTTP/3, and QPACK in one provider.
- quiche 0.29.3 is pinned in the Cargo lockfile and compiled with BoringSSL on Linux x86_64 and aarch64. Native C config and Mojo dynamic-library smoke tests passed on both targets.
- The optional `http3` Pixi feature owns the Rust/CMake/C++/libclang build dependencies; the existing default and HTTP/2 environments do not load them.
- macOS provider compilation and execution have passed through C smoke tests. Native Mojo execution crashes even on a one-line `print`, so Mojo verification for macOS remains outstanding.

## HTTP/3 concurrent request streams plan

- [x] Send two POST requests before receiving responses on one independent quiche connection.
- [x] Verify both streams reach the shared Mojo handler and their responses stay associated with the correct stream IDs.
- [x] Run Rust provider tests, rustfmt, and diff checks; commit this test slice locally.

## Review

- The independent client completed two HTTP/3 requests concurrently over one QUIC connection; both received status 200 and `handled:data` on their respective streams.
- `quic-rust-test` passed all three provider tests; `cargo fmt` and `git diff --check` passed.

## HTTP/3 server design notes

- [x] Record the current provider boundary, request mapping, fixed transport and HTTP limits, and verified integration coverage.
- [x] Identify independent interoperability, loss/cancel stress, aggregate memory bounds, GOAWAY/drain, and Alt-Svc as outstanding.
- [x] Close those outstanding items on the Issue #42 remaining stack: flood/0-RTT/packet stress/transport memory/UDP backpressure/Alt-Svc/H3 reorder-reset ([PRs #71](https://github.com/hirokazumiyaji/net-mojo/pull/71)–[#78](https://github.com/hirokazumiyaji/net-mojo/pull/78), sibling branches) and measured H2/H3 benches ([#79](https://github.com/hirokazumiyaji/net-mojo/pull/79)–[#81](https://github.com/hirokazumiyaji/net-mojo/pull/81)). Ops docs + design sync are this PR. Still deferred: server push, CONNECT, 0-RTT enablement, macOS Mojo e2e H3, CI YAML edits.

## Review

- `docs/design/http3-server.md` documents the implemented Mojo UDP ownership and Rust quiche protocol boundary, request/trailer mapping, and the limits configured in code.
- `git diff --check` passed.

## HTTP/2 stream admission refusal plan

- [x] Add a session test where an over-limit stream is reset with `REFUSED_STREAM` while an existing stream remains completable.
- [x] Consume the refused stream ID monotonically, emit a stream-scoped reset, and keep the HTTP/2 connection usable.
- [x] Run HPACK/session, HTTP/2 protocol, HTTPS state, and independent TLS client suites.

## Review

- The tests failed before the fix because the session returned a connection error, closed the stream cap when request assembly finished, and treated raced DATA as connection-fatal. They now verify `REFUSED_STREAM`, ignore trailing DATA on that reset stream, hold the admission slot until the response completes, and admit a later stream after capacity is released.
- `hpack-mojo-test` passed 25/25, `test-http2` passed 97/97, `https-state-test` passed 2/2, and `https-client-test` passed its HTTP/2 bootstrap and HTTPS roundtrips.

## QUIC connection cleanup plan

- [x] Extend the provider UDP integration test to leave a completed request queued, close the client connection, and check cleanup after the draining timeout.
- [x] Remove closed connection state, CID route aliases, pending request routes, and queued completed requests.
- [x] Run the Rust provider test suite and verify all owned state is released.

## Review

- The test failed before cleanup because the server retained the closed connection and its CID routes. After the change, all three Rust provider tests pass and the close test confirms connections, routes, request routes, and queued requests are empty.

## HTTP/3 request trailers plan

- [x] Extend the independent concurrent-stream test to send a trailer on one request and assert the handler can read it separately from regular headers.
- [x] Carry trailer fields through the QUIC provider record and construct `Request.trailers` in the shared server path.
- [x] Run QUIC provider and HTTP server suites, Rust formatting, and diff checks.

## Review

- The first test run failed as expected because the HTTP/3 adapter dropped request trailers; after the adapter change, both concurrent responses passed and the first included the handler's `:done` suffix.
- `quic-suite` passed the C provider smoke test, Mojo FFI test, and all three Rust provider tests; `test-http-server` passed 27/27.
- `cargo fmt` and `git diff --check` passed.

## Current slice

- Integrate QUIC transport with `Server.tick()`; then add HTTP/3 request streams and shared-handler dispatch.

## QUIC server reactor slice

- [x] Add an optional HTTP/3 integration test that attaches a UDP endpoint to `Server`, drives `tick`, and verifies shutdown exits the loop.
- [x] Let `Server` own one QUIC endpoint, include its timer in reactor wait time, drain bounded packet batches, and toggle writable readiness when a UDP send is pending.
- [x] Verify `quic-mojo-test` and review the diff.
- [x] Commit this server transport slice locally as `5e7adb9`.

## Review

- `quic-mojo-test` passed on Linux x86_64 under Docker after the initial quiche/BoringSSL build. Direct macOS Pixi execution is unavailable because the checked-in environment is linux-64.
- Server shutdown drops the QUIC UDP descriptor and exits when no TCP listener or active connections remain.

## Shared HTTP/3 request version slice

- [x] Add an HTTP/3 version value to shared request metadata and rendering.
- [x] Run the HTTP API suite and review the diff.
- [x] Commit this metadata slice locally as `7868433`.

## Review

- `test-http-api` passed 19/19 on Linux x86_64.

## HTTP/3 request and response slice

- [x] Decode bounded HTTP/3 request headers and bodies through quiche and expose completed requests through the C/Mojo provider API.
- [x] Route HTTP/3 requests through the shared `Handler` and return bounded responses through the provider.
- [x] Apply shared response status, header count, header byte, and body limits.
- [x] Verify the QUIC provider suite and HTTP server suite.
- [x] Commit this slice locally.

## Review

- `quic-suite` passed on Linux x86_64, including an HTTP/3 POST over localhost UDP, duplicate request headers, request body extraction, and a complete 200 response body.
- `test-http-server` passed 27/27 on Linux x86_64; `quic-mojo-test` compiled and passed after applying the HTTP/3 response limits.
- HTTP/3 requests have since been exercised through the Mojo `Server` and shared handler in the concurrent request and graceful shutdown slices above.

## HTTP/2 stream send credit slice

- [x] Add a regression test for independent stream-level `WINDOW_UPDATE` credit and response accounting.
- [x] Track peer send credit separately for each active response stream; apply connection and stream updates independently.
- [x] Release send-credit state after response completion and on stream reset.
- [x] Run HPACK, HTTP/2, and TLS HTTP/2 suites, then commit this slice locally.

## Review

- The first test run failed because only the stream window was increased while the connection window remained the limiting 65,535 bytes. Adding a connection `WINDOW_UPDATE` made the test isolate per-stream credit.
- HPACK passed 22/22, HTTP/2 passed 97/97, and the TLS/HTTP2 suite passed on Linux x86_64.
- Response scheduler queues, continued DATA after credit is exhausted, and connection-level read progress during blocked writes remain outstanding.

## HTTP/2 response scheduler slice plan

- [x] Add a socket-independent round-robin scheduler test with two blocked streams, bounded DATA frames, and WINDOW_UPDATE resumption.
- [x] Separate response HEADERS encoding from DATA framing while preserving HEAD and bodyless status behavior.
- [x] Queue response bodies per stream, debit connection and stream windows as DATA frames are scheduled, and retain unsent offsets.
- [x] Keep HTTP/2 reads active while queued response bytes are blocked on socket writability or flow-control credit.
- [x] Account queued body/header bytes and release them after completion or reset.
- [x] Run HPACK, HTTP/2, HTTP Server, and TLS/HTTP2 suites; commit the slice locally.

## Review

- The scheduler unit test proves round-robin DATA frames, bounded payloads, no repeated HEADERS, completion flags, per-stream credit exhaustion, and resumption after stream `WINDOW_UPDATE`.
- TLS HTTP/2 client coverage sends two requests on streams 1 and 3 before reading either response and verifies both bodies on one connection.
- The TLS HTTP/2 client also sets the initial stream window to zero, grants credit later, and verifies the buffered response body resumes.
- HPACK passed 24/24, HTTP/2 passed 97/97, HTTP Server passed 27/27, and `tls-suite` passed on Linux x86_64.
- `/review` was attempted as requested, but the auto-reviewer rejected external diff upload and session persistence outside the workspace. PR publication remains blocked pending explicit approval for that data transfer.

## HTTP/3 shared-handler integration slice plan

- [x] Start a Mojo `Server` with a QUIC UDP endpoint and a handler that validates HTTP/3 request metadata/body.
- [x] Use an independent quiche client over localhost UDP to send a request and assert the shared-handler response.
- [x] Run the HTTP/3 provider suite and record the end-to-end result; commit this slice locally.

## Review

- The independent quiche client completed TLS/ALPN negotiation, sent an HTTP/3 POST over localhost UDP, and received `handled:data` from the shared Mojo `Handler`.
- `quic-suite` passed, including the C provider smoke test, Mojo FFI test, and all three Rust provider tests.
- `cargo fmt` and `git diff --check` passed.
