# Issue #42 unit 109 — shortened re-measurement and gap notes

Issue #42 Phase 8/10 audit asked for:

1. Shortened re-measurement of H1/H2/H3 at the current main SHA.
2. Handshake-included TLS/QUIC churn cells.
3. QUIC per-connection memory calibration.
4. Allocation / syscall counts per request.
5. Recomputed macOS fd columns (new numeric sampler).

This unit delivers the QUIC per-connection memory calibration end-to-end
(`MEMORY_CALIBRATION.md` / `.tables.json`) and a shortened H3 cell at the
current main SHA, which doubles as the first recomputed macOS fd column.
The remaining gaps are documented below with the specific reasons they
are deferred.

## Shortened H3 cell (gap #1 and gap #5)

### Shortened procedure caveat

This is a labelled **shortened** measurement, not a replacement of the
full Phase 0 procedure. Pairs are three alternating runs with warmup 5 s
and measure 15 s (vs the published 10 s warmup / 30 s measure, 5 runs).
It is intended as a lightweight check at the current main SHA; the full
procedure remains authoritative. Results use the standard
`benchmarks/http/run_http3_bench.sh` driver with
`WARMUP_S=5 MEASURE_S=15 RUNS=3 CLIENTS=64 STREAMS="1"`.

### Host and toolchain

| Item | Value |
| --- | --- |
| Host | Apple M2 Pro, macOS 27.0.1 (Darwin 27.0.0), arm64 |
| Mojo | `1.1.0 (8189361e)` (same compiler as published H1 series) |
| QUIC provider | quiche `0.29.3`, BoringSSL (via quiche) |
| H3 baseline | aioquic `1.3.0` |
| Repo SHA at measurement | `7f80f55e4f70f7468bd0a077d29b057bfd77d65e` |
| Mojo H3 server SHA256 | `8858bc4a15e193b5853c9c5c2ce0f1f6728c0b2be57ea461018092ba0d34a824` |
| quiche provider SHA256 | `da9022facc3b265a9d557de935d0eae1f09bd317d3d7c70c53d855415cabe331` |
| TLS shim SHA256 | `32580bd75ca01e569f935f39d5d9c0bed8d110456445dba91344314c2de6aed7` |

### Results (3 runs × 15 s, c=64, m=1, loss=0 loopback)

Raw rows live in `workspace/unit109/h3_bench/summary.tsv`. Mid-measure
server CPU, RSS and (numeric) FD count come from the harness's
`sample_server` helper, which uses the new numeric FD counter (not the
old `lsof | wc -l` tally).

| Server | run | req/s | p50 µs | p95 µs | p99 µs | server CPU % | server RSS KB | server FDs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| aioquic | 1 | 5,106.93 | 12,395 | 13,063 | 13,454 | 98.5 | 60,816 | 7 |
| aioquic | 2 | 5,120.33 | 12,365 | 12,992 | 13,302 | 98.5 | 80,704 | 7 |
| aioquic | 3 | 5,125.40 | 12,364 | 13,014 | 13,388 | 99.4 | 100,400 | 7 |
| Mojo    | 1 | 9,360.33 |  4,627 |  6,273 |  6,569 | 38.8 | 24,512 | 10 |
| Mojo    | 2 | 9,435.73 |  4,863 |  6,100 |  6,526 | 39.9 | 25,024 | 10 |
| Mojo    | 3 | 9,217.53 |  4,689 |  6,303 |  6,706 | 39.6 | 25,152 | 10 |

Means (3 runs): aioquic 5,117.56 req/s, p50 12,374 µs; Mojo 9,337.87 req/s,
p50 4,726 µs. All six runs report `failed=0`. Mojo / aioquic req/s
ratio = 1.825 (shortened; descriptive, no acceptance gate at this cell).

### Delta vs published numbers (`benchmarks/http/README.md`, PR 10)

Published c=64 m=1 cell (full procedure, same host class, Mojo 1.0 series):

- aioquic: 4,984 req/s, p50 12,575 µs, p95 13,838 µs, p99 14,763 µs,
  CPU ~100%, RSS ~106 MB, fd 47* (inflated — included `cwd`/`txt`/mapped).
- Mojo: 8,426 req/s, p50 5,875 µs, p95 6,817 µs, p99 7,329 µs,
  CPU ~50%, RSS ~32 MB, fd 18* (inflated).

Shortened re-measurement delta:

- aioquic: +~2.7% req/s, p50/p95/p99 ~1–8% lower, CPU unchanged, RSS lower.
- Mojo: +~11.5% req/s, p50 ~17% lower, p95/p99 ~8–11% lower, CPU and RSS
  lower.
- **Numeric FD column (new sampler)**: aioquic 7, Mojo 10 — compared to
  published inflated 47 / 18. The published `fd*` entries can now be
  replaced by these numeric values. A full re-run is still required
  before updating `README.md` tables themselves; this unit records the
  calibration and leaves the published table unchanged pending a full
  re-measurement series.

### Interpretation

The shortened run gives honest confirmation that the current main SHA
is at parity with (and modestly better than) the published PR 10
numbers for this one cell; it does not establish a new verdict. H2 and
H1 cells are not re-measured here (see gaps below).

## QUIC per-connection memory calibration (gap #3)

See `MEMORY_CALIBRATION.md` and `MEMORY_CALIBRATION.tables.json`.

- Measured idle per-connection RSS delta: ~66–87 KiB across N=100/500/800.
- Documented soft estimate: 256 KiB (`net/quic/provider/src/lib.rs`).
- Constant left unchanged pending a complementary peak-load calibration;
  rationale documented in `MEMORY_CALIBRATION.md`.
- Harness: `benchmarks/http/quic_memory_calibration.py` (newly added).

## Not done in this unit (gaps #1, #2, #4)

### H1 and H2 shortened re-measurement (gap #1 partial)

The published H1 results are a Linux ARM64 netem container run that
also requires an independent terminal qualifier for 120 trials and
precise CPU affinity (CPUs 0/1/2, GOMAXPROCS=1, 2 GiB cgroup). The
published H2 cell is a macOS loopback measurement that would be
in-scope on this host. Neither was done in this session: landing a
single-cell H2 re-run while the parent coordination session had an
active `pixi run -e tls-http2 http2-integration-test` process on the
same host would have risked port and CPU contention and polluted the
comparison. H1 Linux cells need the netem container which was not
spun up for this unit.

### Handshake-included TLS (H2) and QUIC (H3) churn cells (gap #2)

An H1 churn cell already exists in the published series (`CHURN` row,
one new TCP connection per request, 46,190 req/s Go vs 45,020 Mojo).
Equivalent H2 and H3 churn cells would require:

- Extending `benchmarks/http3_load.py` with a `--new-connection-per-request`
  (or `--requests-per-connection`) mode so the TLS 1.3 + QUIC handshake
  is included in every measurement.
- Mirroring the mode in `benchmarks/http/http2_scenarios.py`.
- Running Mojo vs Go-H2 (for H2) and Mojo vs aioquic (for H3) at
  a small batch size (e.g. 1 or 10 requests per connection).

Harness additions and matched runs were not completed in this unit.

### Allocation / syscall counts (gap #4)

Allocation counts were not produced. On this macOS host the standard
options are `malloc_history`, `MallocStackLogging`, `leaks --list`
and `xcrun xctrace` — none produce the plain per-request allocation
tally the H1 section requests, and all require either a controlled
driver loop or non-trivial Instruments template authoring. The Linux
`heaptrack` / `dhat` path requires the netem container to be rebuilt.
Neither path was attempted here. The published H1 table already
documents allocations as "unavailable"; this unit leaves that
unchanged rather than inferring a number from an unverified tool.

### N=1000 QUIC memory calibration

`quic_memory_calibration.py` opens connections in a serial loop. At
N=1000 aioquic timed out before all handshakes completed (server
remained alive). A batched or multi-process dialer is needed. Deferred.
