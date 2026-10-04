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

### 0-RTT / early data

Provider config construction (`apply_provider_quic_transport_settings` in
`net/quic/provider/src/lib.rs`) explicitly keeps TLS early data disabled
([PR #73](https://github.com/hirokazumiyaji/net-mojo/pull/73)). Quiche only
exposes `Config::enable_early_data()` as an opt-in and has no `disable_*`
setter; the provider never calls that API (`PROVIDER_ENABLE_EARLY_DATA` is
false). Session tickets may still be issued for resumption, but connections
must not enter early data / 0-RTT.

### Packet stress (duplicate / reorder / NAT rebinding)

Provider Rust tests ([PR #74](https://github.com/hirokazumiyaji/net-mojo/pull/74))
drive an in-memory quiche client against `QuicServer::recv_datagram` / `send` /
`on_timeout` without a UDP socket:

- Duplicate client datagrams must still complete an HTTP/3 request.
- Swapped consecutive handshake or 1-RTT datagrams must recover via
  loss-detection timers.
- Mid-connection change of the observed client UDP address must either continue
  serving or idle/timeout-clean without leaking CID `routes` or connection maps.
  Full path migration beyond quiche’s built-in behavior is out of scope.

### Transport memory and UDP send backpressure

Soft transport-memory admission
([PR #75](https://github.com/hirokazumiyaji/net-mojo/pull/75)) refuses new
connections when `connections.len() × 256 KiB` would exceed
`ServerConfig.quic_max_transport_memory_bytes`. UDP send saturation under
sustained would-block
([PR #76](https://github.com/hirokazumiyaji/net-mojo/pull/76)) must preserve
pending datagrams and retry when the socket becomes writable — no
drop-without-retry.

quiche's `SendInfo.at` crosses the provider ABI as a non-negative nanosecond
pacing delay. The UDP endpoint retains an absolute monotonic send time with its
pending datagram and disables writable interest until that time. Reactor waits
use the earlier of the pacing time and the transport timeout; only the transport
timeout drives quiche's `on_timeout`. UDP would-block retains the bytes and
original send time, then waits for writable readiness without a zero-timer spin.

Transport packet sends use a deduplicated ready-connection queue. Receive,
response, timeout and shutdown work mark the affected connection; successful
sends rotate it after one packet. Idle connections are not probed for every
send, and terminal cleanup removes their queued keys. Response-stream driving
and global deadline selection still use scans pending separate scheduler work.

Transport deadlines use an ordered index with at most one absolute entry per
live connection. Receive, send, transport timeout and close outcomes refresh the
entry; terminal removal deletes it directly. Only due transport keys are
visited for quiche timeout dispatch. Application deadline selection/expiration
and the terminal sweep still scan their state, so overall timeout work is not
yet proportional only to due connections.

Still deferred: enabling 0-RTT and full path migration. macOS Mojo end-to-end
HTTP/3 is covered in CI (`http3` job on `macos-14`, `http3-client-test` against
the Mojo fixture); only packaged-artifact distribution verification remains
optional.

## Source material

- [quiche README](https://github.com/cloudflare/quiche): QUIC and HTTP/3 implementation, low-level I/O model, Rust requirement, BoringSSL build, and C API.
- [quiche C API](https://github.com/cloudflare/quiche/blob/master/quiche/include/quiche.h): C transport and HTTP/3 interfaces.
- [ngtcp2 README](https://github.com/ngtcp2/ngtcp2/blob/main/README.rst): QUIC library, TLS backends, and nghttp3 integration.
- [MsQuic README](https://github.com/microsoft/msquic/blob/main/README.md) and [platform support](https://github.com/microsoft/msquic/blob/main/docs/Platforms.md): transport scope and supported TLS platforms.
