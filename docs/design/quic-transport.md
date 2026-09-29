# QUIC transport provider

## Requirements

The provider must expose a C ABI usable from Mojo, work on macOS arm64 and Linux x86_64/aarch64, integrate TLS 1.3 with QUIC, and provide the packet, timer, stream, and shutdown operations needed by an event loop. HTTP/3 and QPACK should come from the same maintained project when available. The build must be reproducible and the license compatible with this repository.

## Candidates

| Provider | QUIC and HTTP/3 | Mojo integration | TLS and build | Trade-off |
| --- | --- | --- | --- | --- |
| Cloudflare quiche | One Rust project provides QUIC, HTTP/3, and QPACK | Thin C API; builds a static library with the `ffi` feature | Rust 1.88+; builds and links BoringSSL; BSD-2-Clause | Smallest protocol surface to integrate; requires a Rust/BoringSSL build and an independent package artifact |
| ngtcp2 + nghttp3 | Separate C libraries for QUIC and HTTP/3 | Native C APIs | Requires selecting and maintaining a supported QUIC-capable TLS backend; OpenSSL backend is documented as experimental | C-native transport, but more provider and version coordination |
| MsQuic | QUIC transport library | C API table | Linux uses OpenSSL; project documents platform-specific TLS support | Mature transport API, but HTTP/3/QPACK is not included, so another implementation is needed |

## Recommendation

Use quiche through its C API for the first HTTP/3 implementation. It keeps QUIC, HTTP/3, and QPACK in one provider and exposes the low-level packet I/O model needed to integrate UDP with the existing server loop. The server remains responsible for UDP readiness, timers, and driving packet output.

Build quiche as an optional HTTP/3 artifact with a pinned source revision and Rust toolchain. Keep it separate from the existing TLS/HTTP/2 build because quiche brings its own BoringSSL dependency. Do not make core `net` depend on it. Before committing to distribution, verify static-link behavior and package smoke tests on macOS arm64, Linux x86_64, and Linux aarch64.

The recommendation is conditional on those build and packaging probes. The application must disable 0-RTT, set explicit stream and connection memory limits, and drive the provider's timeout and send APIs from the reactor. Do not treat the provider's sample server as production behavior.

## Source material

- [quiche README](https://github.com/cloudflare/quiche): QUIC and HTTP/3 implementation, low-level I/O model, Rust requirement, BoringSSL build, and C API.
- [quiche C API](https://github.com/cloudflare/quiche/blob/master/quiche/include/quiche.h): C transport and HTTP/3 interfaces.
- [ngtcp2 README](https://github.com/ngtcp2/ngtcp2/blob/main/README.rst): QUIC library, TLS backends, and nghttp3 integration.
- [MsQuic README](https://github.com/microsoft/msquic/blob/main/README.md) and [platform support](https://github.com/microsoft/msquic/blob/main/docs/Platforms.md): transport scope and supported TLS platforms.
