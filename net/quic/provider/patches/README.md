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
Patch application uses the HTTP/3 feature's existing Git dependency, without
requiring a separate `patch` executable. Git repository discovery stops at the
fresh staging directory so an enclosing checkout cannot filter staged paths.

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

The fourth patch compacts a received RangeBuf view immediately before RecvBuf
insertion when its Arc backing is larger than the retained bytes. It preserves
bytes, current offset, final offset and FIN. Ordinary receive buffers retain
their backing; generic send buffers and partial application reads are unchanged.

The authenticated diagnostic in `diagnostics/active_quic_memory` holds the
same 16,383-byte body and missing first byte under contiguous, one-byte and
consistent overlapping frames. Overlap backing falls from 15,728,640 to 16,383
bytes; server transport Rust allocations released after H3 drop fall from
17,874,276 to 2,269,532 bytes. Node counts and read/reset cleanup are unchanged.
All 38 existing RecvBuf contracts and eight new view/overlap/FIN contracts run
in `quic-suite`. The real client also verifies a full 1 MiB echo and reuse.

This fixes retained backing amplification, not a memory quota. Sparse fragment
nodes, Arc headers, empty-map capacity, partly read backing, transient input/copy
allocations, retransmission and native TLS/RSS costs remain separate work.

The fifth patch adds an opt-in native `ReceiveBudget` shared by clones installed
with `Config::set_receive_budget()`. Its immutable capacities separately limit
bidirectional receive data, all unidirectional receive data, and CRYPTO data.
The existing provider still uses the actual unlimited default budget. Selecting
finite server policy and exposing provider settings remain separate work.

Each live receive object reserves two metadata/terminal tokens. Each positive
fragment additionally reserves one token and its full retained backing length.
Partly consumed backing remains charged until that fragment is removed.
Reset, Read shutdown and CRYPTO clear refund retained fragments; metadata stays
charged until the receive object is dropped. CRYPTO clear preserves the object
and its original shared budget across packet epochs.

An allocation-free overlap planner reserves all novel fragments in an incoming
frame before map, FIN, stream length or connection received-byte mutation.
Already covered bytes need no new reservation and remain acceptable at full
quota. New compacted views are charged using their actual backing accessor.
Unaccepted admission cannot consume stream-open counts. RAII reservations and
owners refund failed construction and connection disposal.

Exhausted STREAM resources return `ReceiveBufferExceeded` and close transport
with QUIC INTERNAL_ERROR (`0x1`); the C error value is `-24`. Exhausted CRYPTO
resources retain the existing CRYPTO_BUFFER_EXCEEDED (`0xd`) mapping. The native
C header records these error values; this unit adds no C settings interface.

`quic-suite` verifies atomic rejection, empty FIN/marker replacement, consumed
input split around islands, partial and complete read/discard, reset, clear,
constructor rollback and arithmetic overflow. Authenticated packet tests use
two real connections sharing a finite budget, preserve receiver state on
rejection and check a real HTTP/3 priority update while request resources are
full. CRYPTO has its own finite pool. Synthetic packet injections deliberately
receive no ACK flight because their sender has no recovery records; these are
receive-state tests, not loss, recovery or full control-progress proofs.

Slots bound receive-object/fragment population without assuming portable
allocator bytes per node. Backing charges conservatively count each retained
view; map capacity, Arc/node overhead, transient input/copies, H3/application
state, send state, native TLS and RSS are outside the byte ledger. This native
opt-in facility does not establish a whole-engine or default server memory cap.
