# Active QUIC receive allocation diagnostic

This is an observational diagnostic, not a production patch or memory quota.
It reproduces active retained-state amplification with unchanged receive
windows and admission policy. All additions to staged quiche source are
`cfg(test)`; the existing three production patches are unchanged.

## Current reproducer and historical baseline

Current focused branch: `test/issue42-active-quic-memory`, based on
`a54ff807bce29c0c4ec0a6501816ef5ae7291dbc` (unknown-stream retirement).
It contains only these five diagnostic files; the staged integration snapshot
is not part of this branch or commit.

The rerun on this base produced exactly the historical measurements below.
A byte-for-byte comparison verified all three existing patches, the staging
script, upstream Cargo.lock/Cargo.toml/COPYING, and native lib/frame/range_buf/
flowcontrol/stream/recv_buf/H3 source (including identical test appendices).
All 14 comparisons passed. Source hashes are recorded in
`/private/tmp/net-mojo-active-quic-memory-source-comparison.json`.

Historical baseline experiment:

- Repository baseline: `43938a8d5f536e09f3d252cc04622223d949ffc8`.
- Applied saved integration snapshot:
  `/private/tmp/net-mojo-issue42-integration-source.patch`, SHA256
  `9d32d225cacee205dfdf8a2ebe8b565ee792c59f89b85fcaefb2d6a7559733fa`.
- Checksum-verified upstream quiche 0.29.3 plus the existing cancellation,
  collected-range and unknown-stream-retirement patches. The archive checksum,
  license and locked dependency graph are retained by the existing staging
  script. Later response-ready queue changes are outside this fixed snapshot.
- Darwin arm64, rustc 1.98.1 `(48a229cea 2026-09-01)`, cargo 1.98.1
  `(797e8a9bc 2026-08-05)`, release tests, one test thread.

From this worktree:

```sh
pixi run -e tls-http3 bash diagnostics/active_quic_memory/run.sh
pixi run -e tls-http3 cargo test --locked --release \
  --manifest-path build/quic/quiche-0.29.3/Cargo.toml \
  --target-dir build/quic/diagnostic-cargo stream::recv_buf::tests \
  -- --test-threads=1
```

The diagnostic script stages fresh pinned source before every run and appends
test-only helpers. It verifies that the production configuration still matches
the explicit fixture values. It uses an independent cargo target directory and
does not build or modify the parent integration worktree. Re-staging through a
different build entrypoint removes these test additions; rerun this script.

## Equal occupancy, different retained state

Every case holds exactly 16,383 bytes of the same 16,384-byte POST body, with
the first body byte missing and the same largest received offset. FIN is sent
only after filling the gap in the read case. The POST headers and DATA length
are valid and already parsed before the held state.

- Contiguous: 1024-byte adjacent fragments, with one shorter last fragment.
- Sparse: one-byte adjacent fragments behind the same gap.
- Overlap: consistent 1024-byte frames starting one byte later each time.
  Each frame repeats existing `b` bytes and contributes one new byte after the
  first frame. No contradictory overlapping data is sent.

Each authenticated case performs a genuine TLS handshake and SETTINGS/static
QPACK POST exchange. The pinned packet helper then encrypts actual STREAM or
RESET_STREAM frames, and the receiver processes those packets normally.
Adversarial frames use synthetic sender packet construction without recovery
records. Receiver ACKs are deliberately not returned to that synthetic sender.
This proves authenticated receive allocation and cleanup, not loss recovery,
sender congestion control, retransmission or control-credit independence.

The test-only buffer helpers count map entries, non-overlapping retained body
bytes, and distinct underlying Arc payloads, deduplicating shared backing
pointers. A thread-local System allocator wrapper records requested Rust
allocation layouts. It measures allocations released by dropping only the
server transport after dropping its H3 engine. Client transport, client H3,
packet buffers and fixture state remain alive outside that drop interval.

## Baseline measurements

The historical runs and the focused-branch rerun produced identical values:

| Held pattern | Map entries | Unique body bytes | Distinct Arc payload bytes | Server transport Rust bytes released on drop |
| --- | ---: | ---: | ---: | ---: |
| Contiguous | 16 | 16,383 | 16,383 | 42,068 |
| Sparse | 16,383 | 16,383 | 16,383 | 2,417,772 |
| Overlap | 15,360 | 16,383 | 15,728,640 | 17,874,276 |

After filling the gap, H3 reads the exact 16,384 `b` bytes and reports Finished.
All patterns then have zero entries/body/backing bytes and release 23,892 Rust
transport bytes on drop. After authenticated RESET_STREAM followed by the
supported H3 request cancellation, all patterns have zero entries/body/backing
bytes and release 23,280 Rust transport bytes on drop.

Independent low-level RecvBuf results:

| Held pattern | Rust allocation bytes released by RecvBuf drop |
| --- | ---: |
| Contiguous | 18,896 |
| Sparse | 2,394,600 |
| Overlap | 17,851,104 |

After a complete read, an empty RecvBuf still releases 720 bytes when dropped;
its BTreeMap retains an empty root allocation. After reset/error delivery it
releases zero. Thus zero entry count is not an exact allocator-byte counter.

Validation: both diagnostics pass, including exact offsets, exact body bytes,
node/backing counts, read/Finished and RESET cleanup. The existing RecvBuf
contract suite passes all 38 tests on the same staged source. Logs:

- `/private/tmp/net-mojo-active-quic-memory-final.out`
- `/private/tmp/net-mojo-active-quic-memory-recv-contracts.out`
- `/private/tmp/net-mojo-active-quic-memory-unit.out`
- `/private/tmp/net-mojo-active-quic-memory-unit-recv-contracts.out`

Initial compile/fixture corrections are not allocation baseline RED evidence:
the private RecvBuf type needed a test-only re-export; H3 needed to consume the
DATA prefix before the missing-body assertion; the held-state fixture does not
send FIN before RESET. No production behavior was changed to accommodate them.

## Findings and smallest follow-up API proposal

The sparse case proves a fragment/container cost independent of body length.
The overlap case additionally proves retained backing amplification:
`RangeBuf::split_off` clones its Arc, so trimming a 1024-byte received frame to
one novel byte retains that frame's full allocation. Both costs are active
state, not historical canceled-stream retention; normal read/reset releases
them. Both exceed the current soft 256 KiB per-connection admission estimate
with only one request and 16 KiB of body offset credit.

The first focused production unit proposed after this diagnostic is receive
backing compaction only: compact a trimmed range before RecvBuf insertion,
retain offsets/FIN exactly, and leave windows, admission and quota APIs alone.
Sparse-fragment cost remains visible and is not solved by that unit.

A later independent accounting API proposal, also requiring design review:

1. Add connection-level reassembly counters and two explicit limits:
   retained backing-payload charge and retained fragment slots. Provide a
   public `Connection::receive_reassembly_stats()` returning backing charge and
   fragment slots, plus `Connection::set_receive_reassembly_limits(bytes,
   slots)` so the provider can allocate its remaining budget per receive call.
   Keep this distinct from an allocator/RSS byte API.
2. Charge full backing length, not RangeBuf view length. Shared backing may be
   charged once per retained range as a conservative upper bound; avoiding a
   growing pointer-identity map keeps the accounting simple. Enforce limits
   before committing retained entries. Check overwrite, overlap splitting,
   partial reads, reset, shutdown, stream collection and CRYPTO ownership.
3. Compact a trimmed incoming receive range into backing for its retained
   bytes before insertion. This removes the demonstrated amplification while
   preserving the normal untrimmed receive path. It does not eliminate sparse
   fragment costs; those still require the independent slot limit.
4. Define quota exhaustion as an explicit connection resource error. QUIC
   credit already advertised cannot be revoked, so silently discarding excess
   data or waiting forever is not an acceptable budget policy. The native error
   and provider close mapping require review before implementation.
5. Let the provider allocate remaining server-wide reassembly budget to the
   connection before receive processing and reconcile actual counter changes
   afterward. Charge transient input separately: frame parsing currently
   allocates backing before RecvBuf retention checks. An input datagram is
   bounded by protocol limits but still needs stated peak headroom.

No limit value, slot-to-byte multiplier, admission change or error mapping is
selected here. A calibrated multiplier cannot be described as exact BTreeMap
allocator layout. A strictly bounded fragment count plus bounded backing bytes
can bound this object's population; full native byte accounting needs additional
container/base/send/crypto counters. The 720-byte empty-map observation must not
be lost when active entry counters reach zero.

The next unit needs meaningful RED/GREEN assertions for retained backing and
quota exhaustion, all existing RecvBuf overlap/read/reset tests, unchanged
>=1 MiB bodies, and the 257-cancel/eight-sibling/reuse proof. No production code
should be written until the counter, quota and close contract is reviewed.

## Limits of this evidence

The Rust drop probe excludes native BoringSSL allocations, allocator-retained
pages, RSS and process-wide memory. It does not measure response/retransmission
buffers, all cryptographic state or peak allocations during packet processing.
The packet fixture does not establish control/QPACK progress under request flow
saturation. Those are separate outstanding requirements; this result does not
claim a hard engine or process memory bound.
