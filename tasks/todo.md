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

- Support receiving multiple concurrent streams and resuming buffered responses as peer flow-control credit arrives.

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

- Add per-connection QUIC packet receive/send and timeout operations to the quiche provider and exercise them with a local UDP integration test.
