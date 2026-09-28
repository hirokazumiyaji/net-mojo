# Issue #42 implementation progress

- [x] Expose negotiated HTTP/2 peer SETTINGS as an immutable snapshot.
- [x] Add a post-bootstrap HTTP/2 control-frame dispatcher with continuation sequencing and bounded frame parsing.
- [x] Add a bounded incremental reader for post-bootstrap HTTP/2 frames.
- [x] Preserve HEADERS metadata across CONTINUATION for request assembly.
- [x] Assemble HTTP/2 connection frames into bounded shared Request values.
- [x] Defer optional HPACK loading until the first request headers arrive.
- [x] Connect ALPN `h2` to the server's shared handler path.
- [x] Respect HTTP/2 connection and stream receive flow-control windows; cap responses to available outbound credit.
- [ ] Integrate concurrent HTTP/2 request streams, flow control, and response scheduling.
- [x] Build an optional quiche dependency and validate its C/Mojo FFI entry points.
- [x] Exercise an HTTP/3 TLS handshake across in-memory QUIC packet exchange.
- [ ] Integrate QUIC packet I/O, timers, HTTP/3 streams, and the shared handler with the server.
- [ ] Complete protocol interoperability, docs, CI, and performance validation.

## Review

- The SETTINGS snapshot is committed as `d21563b` and passed the 90-test HTTP/2 suite on x86_64 and aarch64.
- The frame-dispatch slice passed 93 HTTP/2 tests on Linux x86_64 and aarch64 and is committed as `11fee1b`.
- The incremental frame-reader slice passed 95 HTTP/2 tests on Linux x86_64 and aarch64 and is committed as `a93c81b`.
- The connection-input slice passed 97 HTTP/2 tests on Linux x86_64 and aarch64.
- TLS server bootstrap over ALPN `h2` and HTTP/1.1 passed the TLS suite on Linux x86_64 and aarch64.
- HTTP/1.1 server suite passed 27 tests, and HTTP/2 suite passed 97 tests on Linux x86_64 and aarch64 after connection routing.
- `/review` and PR publication remain pending the user's answer about uploading the code diff to the configured external reviewer.
- The QUIC packet handshake test passed on Linux x86_64. `quic-suite` now includes this Rust test alongside the C and Mojo provider smoke tests.
- HTTP/2 requests now reach the shared handler and return encoded responses; the TLS integration client verifies request DATA, receive WINDOW_UPDATE frames, response HEADERS/DATA, and a zero peer stream window on x86_64 and aarch64.
- Flow-control slice passed TLS, HPACK (21/21), HTTP/2 (97/97), HTTP server (27/27), Python syntax, and diff checks on Linux x86_64 and aarch64.
- Stream-level outbound WINDOW_UPDATE and continued responses remain outstanding; current responses are capped to the initial peer stream credit.

## Current slice

- Attach `QuicUDPEndpoint` to `net.http.Server`, drive QUIC timers and HTTP/3 control/request streams, and route completed requests to the shared handler.

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
- `/review` and PR publication remain pending explicit authorization to upload the code diff to the configured external reviewer.

## Current slice

- Integrate the Mojo `QuicServer` with `UDPConn` and the server reactor, retaining a generated QUIC packet until the nonblocking UDP send completes.
