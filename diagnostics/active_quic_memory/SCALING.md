# Receive fragment scaling and conservation

Branch `test/issue42-quic-fragment-conservation` starts from
`18cf35a29c555c7bf6be74b9ef9aa1c14c95729e`, the receive-view compaction fix.
This unit changes diagnostics only. All four production source patches,
provider configuration, windows, quota policy, source checksum, lockfile and
license remain unchanged. The appended native helpers/tests are `cfg(test)`.

Reproduce from this worktree:

```sh
pixi run -e tls-http3 bash diagnostics/active_quic_memory/run.sh
pixi run -e tls-http3 cargo test --locked --release \
  --manifest-path build/quic/quiche-0.29.3/Cargo.toml \
  --target-dir build/quic/diagnostic-cargo stream::recv_buf::tests \
  -- --test-threads=1
```

The first command freshly stages the pinned source and four ordered patches.
The second runs the 38 existing buffer contracts on that same staged source.
The allocator attribution and authenticated-packet exclusions are described
in [README.md](README.md). In particular, the synthetic incoming frames have
no sender recovery records, so their ACKs are never fed back to that sender.
These tests do not prove loss recovery or independent control flow credit.

## Equal body occupancy at three sizes

Each POST has valid parsed headers and a DATA length of 4,096, 16,384 or
65,536 bytes. Each held state omits only the first body byte. All three
patterns have identical retained bytes and largest received offset for that
size. Subsequent read cases fill the gap, add FIN and verify every body byte
and H3 Finished. Reset cases process an authenticated RESET_STREAM and the
supported H3 cancellation. All cases enforce compact backing.

Darwin arm64, rustc/cargo 1.98.1, release tests, one test thread:

| Body bytes | Held pattern | Entries | Held view/backing bytes | Server transport Rust bytes released on drop |
| ---: | --- | ---: | ---: | ---: |
| 4,096 | Contiguous | 4 | 4,095 | 28,052 |
| 4,096 | Sparse | 4,095 | 4,095 | 620,988 |
| 4,096 | Overlap | 3,072 | 4,095 | 472,748 |
| 16,384 | Contiguous | 16 | 16,383 | 42,068 |
| 16,384 | Sparse | 16,383 | 16,383 | 2,417,772 |
| 16,384 | Overlap | 15,360 | 16,383 | 2,269,532 |
| 65,536 | Contiguous | 64 | 65,535 | 97,028 |
| 65,536 | Sparse | 65,535 | 65,535 | 9,609,612 |
| 65,536 | Overlap | 64,512 | 65,535 | 9,461,372 |

For all sizes/patterns, complete read leaves zero entries/view/backing bytes
and 23,892 server transport Rust bytes; reset leaves zero entries/view/backing
bytes and 23,280 Rust bytes. Those residuals are other connection state, not
held body backing.

The independent low-level RecvBuf measurements are:

| Body bytes | Contiguous Rust bytes | Sparse Rust bytes | Overlap Rust bytes |
| ---: | ---: | ---: | ---: |
| 4,096 | 4,880 | 597,816 | 449,576 |
| 16,384 | 18,896 | 2,394,600 | 2,246,360 |
| 65,536 | 73,856 | 9,586,440 | 9,438,200 |

These are requested Rust allocation layouts on this build, not portable
bytes per node. No multiplier is selected. Fragment count and backing bytes
need distinct limits; equal offset credit alone does not bound a useful small
allocation budget.

## Two held requests

One authenticated connection holds valid 16 KiB and 4 KiB sparse POST bodies.
The test asserts each request's offset, unread gap and retained tuple before
summing the two requests. It then reads the first exact body, resets the
second, and accepts Headers/Finished for a new valid GET on stream 8. That GET
uses a normal client flight delivered only to the receiver. It proves receiver
acceptance after cleanup, not a complete recovery or response roundtrip.

The three allocation observations use fresh equivalent connections so dropping
the transport can measure each state independently. The final state also
includes the newly accepted and canceled GET.

| State | Request entries/view/backing bytes | Server transport Rust bytes released on drop |
| --- | ---: | ---: |
| Both held | 20,478 | 3,018,708 |
| First read, second held | 4,095 | 624,828 |
| Both released, next GET accepted | 0 | 27,224 |

## Conservation transitions

Let F be positive entries, T empty terminal entries, V retained view bytes and
B distinct backing payload bytes. Each observed buffer enforces `F <= V`,
`T <= 1` and `V <= B`. These are object/payload relations, not an exact native
allocator accounting API.

| Transition | F | T | V | B |
| --- | ---: | ---: | ---: | ---: |
| Three two-byte islands | 3 | 0 | 6 | 6 |
| Incoming 14-byte range around all islands | 7 | 0 | 14 | 14 |
| Duplicate same range | 7 | 0 | 14 | 14 |
| Read three bytes | 6 | 0 | 11 | 12 |
| Duplicate consumed prefix | 6 | 0 | 11 | 12 |
| Shutdown, then late final data | 0 | 0 | 0 | 0 |
| Empty FIN at a held gap | 0 | 1 | 0 | 0 |
| Duplicate same FIN | 0 | 1 | 0 | 0 |
| RESET replaces positive range | 0 | 1 | 0 | 0 |
| Application receives reset error | 0 | 0 | 0 | 0 |

One incoming frame around three islands adds four novel fragments. A quota
must admit all four before retention. Duplicate/consumed-prefix frames add
none. Shutdown retains no later body backing while final-size accounting
continues. Empty FIN and reset markers cost metadata despite zero body bytes;
the observed empty FIN releases 736 Rust bytes on buffer drop.

A separate partial-read test consumes 1,023 bytes from an ordinary 1,024-byte
frame. The final one-byte view still owns all 1,024 backing bytes and releases
1,760 Rust bytes on drop. Reading that byte removes the entry/backing but an
empty map root still releases 720 bytes. Reset after that partial read clears
the map and releases zero bytes. Therefore partial reads must not refund
backing early, and empty buffers cannot be treated as zero allocation.

## Validation and limits

All five diagnostics and all 38 existing RecvBuf tests pass. Logs:
`/private/tmp/net-mojo-quic-fragment-final.out` and
`/private/tmp/net-mojo-quic-fragment-recv-contracts.out`.
The 1 MiB normal sender/ACK echo and unchanged 257-cancel/eight-sibling/reuse
checks belong to base 18cf35a and are documented in README.md; this test-only
unit does not repeat or replace them.

This proof does not enforce a fragment limit, shared server budget or allocator
cap. It excludes native TLS heap, RSS, allocator-retained pages, retransmission
and send buffers, transient input/copy allocations, and broader engine state.
CRYPTO receive buffering is separate from STREAM/MAX_DATA. A production ledger
must account for it separately and preserve control-stream resources.
