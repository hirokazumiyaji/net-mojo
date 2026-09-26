# TLS provider for `net.http`

## Decision

Use OpenSSL 3.2 or newer as the first TLS provider, behind a private C ABI
shim in `net/tls/`. Keep the dependency opt-in: importing or building the
existing `net` package must not require OpenSSL. The provider choice is limited
to TLS for TCP in this phase; a later QUIC implementation may use OpenSSL's
QUIC TLS interface, but must verify its exact requirements before depending on
it.

OpenSSL is the only candidate considered here that combines a cross-platform C
API, server-side TLS and ALPN with a documented QUIC TLS interface. Its 3.x
license is Apache 2.0. Mojo exposes both compile-time C calls and runtime
dynamic-library calls, but a small C shim is preferable for OpenSSL's opaque
types, macros, and error queue. [Mojo C FFI](https://mojolang.org/docs/manual/c-ffi/)
documents both interop paths and their linking differences.

## Alternatives

| Provider | Strengths | Why it is not selected |
| --- | --- | --- |
| OpenSSL 3.2+ | C API, broad platform availability, TLS server, ALPN, QUIC TLS APIs | External native dependency and versioned packaging must be handled explicitly |
| Apple Secure Transport | System TLS provider on macOS | Does not cover Linux targets and has no matching QUIC TLS API |
| Rustls through FFI | Modern TLS implementation and a C-facing integration path | Adds a Rust build/packaging toolchain and does not itself settle the project's QUIC engine choice |

OpenSSL's QUIC support begins in 3.2 and is specifically a TLS integration
interface; it is not an HTTP/3 implementation. [OpenSSL QUIC documentation](https://docs.openssl.org/3.3/man7/openssl-quic/)
describes the TLS 1.3 and QUIC-specific APIs. HTTP/3 still requires a QUIC
transport and HTTP/3 framing implementation or a selected engine.

## Integration boundary

- Keep OpenSSL types and headers out of Mojo's public API. Expose opaque TLS
  context and connection handles through a small C shim.
- Use the reactor-owned TCP socket. A TLS operation reports whether it needs
  socket readability or writability; it never waits on the socket itself.
- Treat `WANT_READ` and `WANT_WRITE` as interest changes, not connection
  failures. Preserve the operation across retries and retain the existing
  absolute handshake deadline.
- Configure certificate/key inputs on the server context and configure ALPN
  from the enabled HTTP protocols. A connection with no mutually supported
  protocol must fail explicitly; do not retry in plaintext.
- Close the TLS connection before releasing its socket and context. The
  connection owner remains the only code that operates on the socket.
- Do not implement cryptographic primitives in Mojo or add a silent system
  provider fallback.

## Build and distribution

The TLS-enabled target must link or package OpenSSL explicitly. Core `net`
remains usable without it. The supported build must report a clear error when
the TLS feature is enabled but the required OpenSSL version is unavailable.
The first implementation should use a pinned OpenSSL 3.x build for CI and
document how downstream builds provide the same ABI; silently loading an
arbitrary system library at runtime would make behavior depend on the host.

Before implementing the Mojo wrapper, add a compile/link probe for the chosen
OpenSSL build on macOS arm64, Linux x86_64, and Linux aarch64. The probe must
cover context creation, server ALPN selection, nonblocking handshake return
states, read/write, and orderly shutdown. That check also confirms whether the
selected package exposes QUIC TLS symbols on each target. If it does not, keep
TCP TLS on OpenSSL and select a QUIC engine with its own supported TLS
integration in Phase 8.

## Phase 6 implementation boundary

The next implementation PR should add only the C shim and Mojo TLS ownership
wrapper, then exercise it with a loopback TLS handshake over the existing
reactor. HTTP server protocol dispatch and HTTP/2 remain separate PRs. The
contract tests must cover a handshake that alternates read/write readiness,
invalid certificates or handshake bytes, ALPN selection, deadline expiry, and
resource release after close.
