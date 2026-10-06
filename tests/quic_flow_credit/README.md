# Critical-stream connection credit regression

Run from the repository root:

```sh
pixi run -e tls-http3 bash scripts/test_quic_flow_credit.sh
```

The regular `quic-rust-test` task also runs this fixture. The runner stages the
checksum-verified pinned archive and all six ordered patches, then appends only
`cfg(test)` fixtures. It embeds the exact provider constants and transport/default
receive-limit functions and prints their SHA256 plus the whole provider source
hash. An independent cargo target avoids replacing provider build artifacts.
Re-staging through another entrypoint removes the appendices.

The actual-default server uses finite shared request/control/crypto pools and
100 bidi/three uni streams, initial 1,000,000-byte stream credit and the fixed
16 MiB maximum. Eleven valid 1 MiB POSTs have HEADERS parsed while their positive
partial DATA remains unread. Rotating bounded writes stops when connection or
request-stream credit runs out. The former 10,000,000 connection credit makes
the real 9-byte PRIORITY_UPDATE return `StreamBlocked`, despite control-stream
and congestion allowance. With the connection envelope it reaches the parser
before any request body read. All eleven requests then complete exact 1 MiB
echoes; a further request proves reuse, and transport drops refund every pool.
The client retains the historical 10M/24 MiB connection receive settings; this
fixture changes only server settings. Both peers exchange genuine TLS/QUIC
packets, ACKs and timers and honor `SendInfo.at`; no packet gaps are manufactured
for the held-body case. Its zero-loss counters are assertions, not a benchmark.

The lazy-QPACK variant starts a legal zero-table/zero-blocked peer with its
control stream only. A separate GET receives an unfinished response, consumes
its prefix and actually abandons it; the original STOP_SENDING packet is
observed from a decrypted copy and then delivered unmodified. This request is
removed and refunded before the eleven held bodies begin. Afterwards the
existing upstream methods open encoder and decoder streams. The decoder emits
one correctly encoded StreamCancellation for abandoned stream0 (`0x40`). The
server consumes exactly one encoder type byte and two decoder bytes (type plus
one instruction), without held-body reads. A 28-line helper is appended inside
H3 only under `cfg(test)`; no release API is added. Quiche discards zero-table
QPACK instruction bytes, so this proves stream/parser byte progress rather
than general dynamic-QPACK conformance.

Pure algebra tests use the actual embedded provider settings. They cover all
advertised stream windows, prior committed consumption, the strictly-less-than
half update threshold and the fixed connection autotuning clamp. Genuine QUIC
component tests use an explicitly reduced profile: two bidi/one uni stream,
4096-byte initial/maximum stream windows, C=24576. They first retire a complete
stream, then hold two replacement requests unread. Consumption reaches exact
half, then crosses it by one control byte. An actual 39-byte MAX_DATA packet is
withheld; a later independently emitted MAX_STREAM_DATA packet is delivered.
The peer has zero connection allowance and positive uni allowance. Reordering
the original packet restores progress. In the loss case that packet is dropped;
real PING packets, real ACKs and ordinary timers cause loss detection and an
updated MAX_DATA retransmission. RESET retirement and a further replacement
preserve the two-window held exposure and continued control progress. Ciphertext
copies identify frames; original emitted packets and recovery records are never
rewritten. This reduced fixture proves counter and recovery semantics, rather
than default HTTP/3 throughput, permanent-loss progress or an allocator bound.

C=3,456,106,496 is advertised offset credit, not 3.21875 GiB of allocated memory.
The finite backing pools total 84 MiB and have independent entry quotas; Arc/node
costs, native TLS, send/retransmission state and other engine allocations remain
outside that number. Existing allocation diagnostics preserve their expressly
historical 10M profile and source provenance. Performance measurements must
record the new flow settings and source revision separately from earlier rows.
