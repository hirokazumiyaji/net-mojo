# QUIC provider selection

- [x] Check the HTTP server roadmap requirements.
- [x] Compare maintained QUIC provider options and official integration interfaces.
- [x] Record an initial provider recommendation, dependencies, and verification gates.
- [x] Review and commit the design slice as `f9667e1`.
- [x] Pin quiche and add the optional Pixi provider build environment.
- [x] Build and smoke the static and dynamic provider on Linux x86_64 and aarch64.
- [x] Verify an HTTP/3 TLS handshake over exchanged in-memory QUIC packets.
- [x] Review and commit the provider build slice.

## Review

- quiche provides a C API and a combined QUIC/HTTP/3 implementation, with Rust and BoringSSL build requirements.
- ngtcp2 requires a separate HTTP/3 library and TLS backend selection.
- MsQuic provides QUIC transport but not the HTTP/3/QPACK layer.
- quiche 0.29.3 builds with Rust 1.98.1 and BoringSSL under the optional Pixi feature on Linux x86_64 and aarch64.
- C smoke tests create and free an HTTP/3 server config. Mojo smoke tests load the dynamic library and exercise the same config ownership API.
- macOS C provider smoke passed. Mojo execution could not be validated natively because that environment crashes on a minimal standalone program.
- The in-memory client/server QUIC packet exchange completed TLS with ALPN `h3` on Linux x86_64. This checks provider handshake behavior without UDP or server integration.
- `pixi run -e tls-http3 quic-suite` passed, including the Rust handshake test, C config smoke, and Mojo FFI smoke. `cargo fmt --check`, shell syntax, and `git diff --check` passed.
- Remaining provider qualification includes macOS Mojo/runtime packaging and macOS artifact delivery.
