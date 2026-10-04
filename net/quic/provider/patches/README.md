# Pinned quiche resource cleanup patches

quiche 0.29.3 retains HTTP/3 stream state when a request is aborted before the
local send direction finishes. This also affects incomplete field sections and
resets consumed by `recv_body()`. The upstream issue is
[cloudflare/quiche#2524](https://github.com/cloudflare/quiche/issues/2524);
[PR #2709](https://github.com/cloudflare/quiche/pull/2709) remains incomplete.

The source-only patch adds `h3::Connection::cancel_request()` to shut down both
request directions and release H3 state and queued Finished events. Priority
updates cannot recreate a canceled request before peer final size arrives.
Already shut or collected request streams can be cancelled again; unknown stream IDs,
control streams and unexpected transport errors are rejected. The provider
keeps QPACK dynamic-table and blocked-stream limits at zero.

Both build and test scripts stage the public Cargo archive, verify SHA-256
`61166d27591eb7cb1310eec2b8fc6ae0e0686e9e4ed742a3ffc6317171175e7d`,
and apply the explicit ordered patch list before compilation. Cargo's
same-graph `paths` override keeps the upstream version, dependency graph and lockfile unchanged. The
archive's license remains in the generated source and `quiche-COPYING`.

The 10,000-cancellation regression measures live Rust allocations released by
dropping the server's H3 object, independently of application byte counters.
This fixes canceled H3 request-state retention; total allocator/RSS limits
remain separate work. The same real-protocol fixture
checks body, partial-field and response deadlines. `pixi run -e tls-http3 quic-suite`
also runs four patched-quiche API tests for both reset entry points, pending
Finished events and canceled/future-stream priority updates.

The second patch backports merged upstream
[PR #2719](https://github.com/cloudflare/quiche/pull/2719), reviewed head
`df16f4538484420c174be7f64a286228938a688f`, merge commit
`c8da372daa06b7cb51aa23b1a55bfe395dcf3d46`. Only source paths are normalized
for staging. It compresses collected transport stream sequences into four
exact range sets, preserving type separation, implicit gaps, stream credit and
historical membership without eviction or a new connection lifetime limit.
The upstream implementation and regression tests are retained together.

Provider regressions separately drop the server transport after first dropping
its H3 engine. Both normal request/response completion and peer resets compare
10,000 versus 50,000 streams: the original transport retains another 442,368
Rust allocation bytes, while compressed ranges remain at 20,604 and 20,712
bytes respectively. These are server transport Rust allocation sizes at matched
protocol states, excluding native TLS allocations and total process RSS. The
suite also exercises exact membership, out-of-order gaps and stream-limit
rejection. Dependency updates must retain these contracts or use the released
upstream fix; quiche 0.30.0 already includes range compression.

The third patch retires locally drained transport streams when FIN or RESET
final size is already known at Read shutdown, or arrives later. Collection
follows connection-byte consumption and keeps an unfinished bidi send half
alive. Ordinary application FIN/reset delivery remains unchanged. H3 removes
only unknown uni parsing state after a successful Drain shutdown; control and
both QPACK critical streams retain their fatal close semantics.

Open upstream [PR #2054](https://github.com/cloudflare/quiche/pull/2054), head
`dc2c024fd69acca9f144e1ccc5b63a54ca023453`, covers terminal state already known
at Read shutdown. This local paired patch also covers later FIN/RESET and H3
state retirement; it is not an accepted upstream backport. Preserve all four
completion orders, exact consumed/final-size and same-type MAX_STREAMS credit,
pending opposite bidi direction, application delivery and critical streams
when rebasing it.

Before this patch, a valid control stream plus two unknown streams exhausted
the three-uni allowance: returned peer uni credit was zero for both FIN and
natural STOP_SENDING/RESET, while a GET remained usable. Measured H3 Rust
allocation sizes rose from 620 to 1,200 bytes at zero/two unknown streams;
the old retention was bounded by exhausted credit, not demonstrated unbounded
growth. The provider regressions now process 10,000 FIN and 10,000 non-FIN
unknown streams, verify returned peer credit after every cycle and a valid GET
after churn, and measure 620 bytes released by dropping the server H3 object.
These measurements exclude transport, native TLS and total process RSS.

Transport collection and H3 retirement must remain paired: enabling only the
transport repair restores credit but retained 2,404,680 H3 Rust allocation bytes
after 10,000 FIN unknown streams in the same fixture. That intermediate case
fails the allocation regression; it does not describe the old exhausted-credit
behavior.
