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
send, and terminal cleanup removes their queued keys.

Application response driving uses a separate bounded deduplicated connection
queue. Successful response admission, receive processing, actual transport
timeouts and local stream cancellation mark only their affected connection
with pending responses. Each drive drains one queued round; a blocked response
waits for another event instead of retrying on every emitted transport packet.
Only pending streams on those touched connections are visited. Completion,
expiry and reset remove a queued key once no response remains; terminal removal
also deletes its key. Unexpected send errors
retain their affected ready work while preserving error propagation.

Transport deadlines use an ordered index with at most one absolute entry per
live connection. Receive, send, transport timeout and close outcomes refresh the
entry; terminal removal deletes it directly. Only due transport keys are
visited for quiche timeout dispatch.

Terminal checks follow affected receive, send, native timeout and explicit close
outcomes instead of sweeping idle connections on each timeout. Immediate
receive errors release already closed transports before propagating the error.
Closing and draining connections remain owned until quiche reports closure;
their native draining deadline schedules the final check and cleanup.

CID-route teardown removes the accepted Initial destination alias and native
server source-ID aliases directly. The Initial destination ID is stored per
connection because it is distinct from the server's native source ID. This
provider does not allocate additional source IDs, and quiche retains its last
source ID across retirement errors and closure; no global CID ownership scan
or additional ownership map is needed.

Completed request routes have a per-connection set of owned IDs. Handler
delivery retains ownership until response completion, cancellation, rejection
or expiry. Connection teardown removes only those IDs from the global route
map; the set holds one entry per live route.

Each initial shutdown stage broadcasts to live connections once. Subsequent
GOAWAY driving uses a bounded deduplicated queue of connections with unfinished
flags, refreshed by receive, native timeout and local cancellation events.
Blocked control frames wait for actual credit instead of retrying on unrelated
packet sends; an incomplete handshake resumes after receive processing creates
HTTP/3 state. The maximum-ID GOAWAY must succeed before the final last+4 ID is
sent, preserving nonincreasing IDs even when only the smaller final frame fits.
Unexpected errors retain affected readiness and propagate; terminal removal
deletes both queue storage and membership.

Request deadlines use one indexed minimum per incomplete stream across header,
body and request-idle phases. Receive processing refreshes only streams touched
by readable headers or HTTP/3 events, including errors. Completion, reset,
expiration and connection removal directly remove their entries; resets also
clear incomplete-header state.

Response write deadlines also use one immutable indexed entry per queued
response. Completion, reset, expiry and connection removal delete it directly;
expiry visits only due entries. Connection-idle deadlines are indexed only
while no incomplete request, readable header or queued response exists. Busy
connections retain their original idle timestamp without scheduling it; clearing
the busy phase restores that timestamp, including an already expired deadline.
This prevents expired idle timers from causing zero waits during active work.
Deadline queries read index minima and idle expiry visits only due connections.

Peer STOP_SENDING during response headers or body sending cancels only that
queued response. The exact quiche error `TransportError(StreamStopped(_))`
uses the existing completion cleanup to release its body budget, route and
write deadline, while keeping transport output ready. Other HTTP/3 errors
remain errors. In pinned quiche 0.29.3, capacity/writability checks collect the
stopped transport stream and send errors remove HTTP/3 stream state when the
request receive side has finished; queued provider responses satisfy that
completed-request condition. Sibling streams and subsequent requests continue.

Initial shutdown broadcasts still visit every live connection, and actual
connection teardown still scans the completed-request FIFO. The
full server loop is not yet proportional only to ready or due work.

### Canceled HTTP/3 request state

Transport shutdown alone does not release incomplete request state in quiche
0.29.3. The provider uses a focused source patch with an explicit
`h3::Connection::cancel_request()` API: shut down both request directions,
remove partial field/body parsing state and queued Finished events, and ignore
priority updates that could recreate canceled state before peer final size.
Peer resets consumed by either `poll()` or `recv_body()`, header/body deadlines
and response aborts share this cleanup. Unexpected cancellation errors propagate
or close the connection; they are not treated as an already-canceled request.
QPACK table capacity and blocked-stream limits remain explicitly zero.

`scripts/prepare_quiche_source.sh` verifies the exact Cargo.lock version and
public crate SHA-256, stages fresh source, and applies the small patch before
both build and test entry points. Cargo's same-graph `paths` override preserves
the upstream lockfile. The generated source retains the upstream BSD license;
[patch maintenance notes](../../net/quic/provider/patches/README.md) record the
checksum, license copy and upstream issue. Dependency updates must replace the
pin and checksum together, rebase or retire the patch against a supported
upstream API, and rerun its reset/body-read/Finished/priority contracts. Do not
reuse staged source as an alternative pin.

Run `pixi run -e tls-http3 quic-suite` to reproduce the API contracts and the
10,000-reset allocation regression, plus header/body/response deadline churn.
The real live scenario can be repeated after building and starting
`benchmarks/http3_server.mojo` with its generated test certificate:

```sh
pixi run -e tls-http3 mojo build --Werror -I . benchmarks/http3_server.mojo -o build/quic/http3-cancel-check
./build/quic/http3-cancel-check
# In another terminal:
pixi run -e tls-http3 python3 benchmarks/http/http3_scenarios.py --url https://127.0.0.1:18453/fixed --scenario cancel --siblings 8
```

The allocation test measures live Rust allocation sizes freed by dropping only
the server H3 engine, separately from application byte counters. It does not
bound total allocator or RSS usage: transport flow windows, reassembly/send
metadata and active H3 field buffers require separate accounting work. A scheduler
that indexes transport deadlines must refresh its entry whenever cancellation
closes a connection outside the receive/send paths.

### Collected transport stream history

The second pinned source patch backports merged quiche
[PR #2719](https://github.com/cloudflare/quiche/pull/2719). Completed streams
retain exact per-type sequence ranges instead of one HashSet entry per ID;
sequential completions share a range, while held active or implicitly opened
gaps remain distinguishable. No closed-stream tombstone is evicted, no stream
credit changes, and no additional GOAWAY/reconnection policy is introduced.
`quic-suite` runs the upstream membership/type/gap/credit tests and real provider
10,000/50,000-stream allocation comparisons for normal completion and resets.

### Unknown unidirectional stream retirement

The third explicit source patch returns uni stream credit after unknown H3
stream types are drained. Transport collection occurs only when the locally
shut receive direction is terminal and the opposite send direction is complete;
late FIN/RESET is collected after its final-size and connection-byte accounting.
Normal application FIN/reset delivery and unfinished bidi responses are kept.
H3 removes only the unknown stream's Drain parsing entry after successful Read
shutdown. Control and QPACK encoder/decoder streams still close the connection
when their critical stream is terminated.

With the previous source, a valid control stream plus two unknown streams
exhausted the three-uni allowance, retaining 1,200 versus 620 server H3 Rust
allocation bytes; the third unknown stream could not open. This showed bounded
retention and missing credit, rather than unlimited old memory growth. The
paired repair processes 10,000 FIN and 10,000 natural STOP_SENDING/RESET cycles,
returns peer credit after every cycle, accepts a valid GET afterwards and
retains 620 measured server H3 Rust allocation bytes. `quic-suite` reproduces
these fixtures plus all four FIN/RESET arrival orders, exact consumed byte and
same-type stream credit, pending bidi send state and critical stream errors.
This is a protocol-state allocation measurement, not a transport or RSS cap.

The fourth pinned patch compacts only trimmed default receive-buffer views
before retention. Overlap trimming can otherwise keep a full frame's Arc for
one novel byte. The authenticated equal-body diagnostic reduces overlapping
backing from 15,728,640 to 16,383 bytes and server transport Rust state from
17,874,276 to 2,269,532 bytes. It preserves offsets, FIN, exact read/reset
delivery and node counts. Untrimmed buffers, generic send buffers and partial
application reads retain their existing behavior. `quic-suite` runs the 38
existing RecvBuf contracts and eight new compaction/overlap/FIN contracts;
the live client verifies a full 1 MiB echo plus connection reuse.

These patches do not establish an allocator cap. The independent 64 MiB
request/response counters count logical field/body bytes rather than Vec
capacity, container entries or allocation overhead. Transport admission still
uses the soft 256 KiB per-connection estimate; default admission budget is
2,621,440,000 bytes. Initial receive credit is 10,000,000 connection bytes and
1,000,000 bytes per stream, with quiche's default autotuned maxima of 24 MiB
per connection and 16 MiB per stream. Out-of-order fragment metadata, native
response/retransmission copies and active H3 field buffers are outside those
application counts. Three peer uni streams permit control/QPACK, but share
connection MAX_DATA with requests; reserving control byte credit and measuring
actual allocated capacities remain separate design units.

Still deferred: enabling 0-RTT and full path migration. macOS Mojo end-to-end
HTTP/3 is covered in CI (`http3` job on `macos-14`, `http3-client-test` against
the Mojo fixture); only packaged-artifact distribution verification remains
optional.

## Source material

- [quiche README](https://github.com/cloudflare/quiche): QUIC and HTTP/3 implementation, low-level I/O model, Rust requirement, BoringSSL build, and C API.
- [quiche C API](https://github.com/cloudflare/quiche/blob/master/quiche/include/quiche.h): C transport and HTTP/3 interfaces.
- [ngtcp2 README](https://github.com/ngtcp2/ngtcp2/blob/main/README.rst): QUIC library, TLS backends, and nghttp3 integration.
- [MsQuic README](https://github.com/microsoft/msquic/blob/main/README.md) and [platform support](https://github.com/microsoft/msquic/blob/main/docs/Platforms.md): transport scope and supported TLS platforms.
