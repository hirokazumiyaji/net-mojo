# Issue #42 unit 111 — shortened Linux re-measurement and allocation counts

This unit records a shortened Linux re-measurement of HTTP/1 F64, F1024 and
LATENCY (fixed-arrival p99), one matched HTTP/2 cell (h2load, c=64 m=10)
and the first per-request allocation / syscall counts for the Mojo H1 server
and Go H1 baseline on this host. The shortened schedule is **not** a
replacement for the published full procedure
(`benchmarks/http/README.md`, 10 s warmup / 30 s measure / 5 pairs).

## Shortened procedure caveat

Three alternating Go/Mojo pairs, warmup 5 s and measure 15 s per role. The
procedure is enough to spot gross regressions at the current main SHA; it
does not re-establish the published 120-trial H1 or 90-trial H2 verdicts
and is not pooled with them. Thresholds are unchanged.

## Host and toolchain

| Item | Value |
| --- | --- |
| Host | Apple M2 Pro, Docker Desktop Linux VM, aarch64 |
| Container | `net-mojo-http-netem:issue42` (image sha256 `bd84096f4b17`); CPUs 0–5, 4 GiB, `--cap-drop ALL --security-opt no-new-privileges` |
| Kernel | `7.0.14-linuxkit` aarch64 (Ubuntu 24.04.4 LTS userspace) |
| Mojo | `1.1.0 (8189361e)` (same compiler as the published H1/H2 series) |
| Go | `go1.26.4 linux/arm64` (`GOTOOLCHAIN=go1.26.4`) |
| h2load | `nghttp2/1.59.0` |
| Repo SHA at measurement | `7f80f55e4f70f7468bd0a077d29b057bfd77d65e` (`origin/main`) |
| Mojo H1 binary SHA256 | `acf44ed8cf44ee8297436a8f14e32872d8ee0493ba510ab03159afafabd086cb` |
| Mojo H2 binary SHA256 | `ac8c3595f0b193eb023580807cafbce75e0486e2281181706dedc0ef0a4cb36a` |
| Go H1/H2 binary SHA256 | `0dcb3d7ab2d82f24c6b14dcc3364f75cdaf4a2baad2ec9e26cb36f767cc5e3b6` |
| http-load SHA256 | `d2b690eaed82a71c4448872538d8fbe1d0ccd2f2e5d6ec928b0a821ae572b89a` |
| Go memstats server SHA256 | `274da2cb8de52f57e340fb28e58d14ca76d85f0c71115a6c99de1dab5d83149a` |
| malloc_count shim SHA256 | `168b78827b65df94c1ae35a67f50c74d1f7383c3b33f58d702b11cd30f72aec7` |

Server pinned to CPU 0 (`GOMAXPROCS=1` for Go, `taskset -c 0` for Mojo);
loader on CPUs 1–5. Both servers use `-idle-timeout 1h` where applicable.
No netem shaping, no bridge disconnection (loopback only).

## H1 shortened cells

Full-precision results in [`LINUX_REMEASURE_RESULTS.tables.json`](LINUX_REMEASURE_RESULTS.tables.json);
raw per-run TSV in `workspace/u111/h1_summary.tsv`.

### Throughput (median across 3 pairs; paired ratio median across pairs)

| Cell | Workload | Go req/s | Mojo req/s | Paired Mojo/Go ratio | Threshold (unchanged) |
| --- | --- | ---: | ---: | ---: | --- |
| F64 | GET /fixed, 64 connections | 110,197.0 | 149,508.3 | 1.3567 | ≥0.90: pass |
| F1024 | GET /fixed, 1,024 connections | 94,540.6 | 145,714.0 | 1.5457 | ≥0.90: pass |
| LATENCY | GET /fixed, 64 workers, 250 arrivals/s | 250.0 | 250.0 | — | fixed arrival; no throughput target |

### Reported p99 latency (median of 3 pairs; paired ratio median)

| Cell | Go p99 ms | Mojo p99 ms | Paired p99 ratio | Threshold (unchanged) |
| --- | ---: | ---: | ---: | --- |
| F64 | 1.472 | 1.302 | 0.8792 | descriptive |
| F1024 | 15.787 | 11.723 | 0.7433 | descriptive |
| LATENCY | 5.237 | 5.532 | 1.1285 | ≤1.2: pass |

All 18 H1 trials emitted `valid: true` with zero errors; closed-loop
cutoffs equal the active connection count (64 or 1,024) and are the
usual in-flight requests at the measurement deadline. LATENCY recorded
3,750 scheduled arrivals per role (250 arrivals/s × 15 s), zero dropped
or unstarted.

### Delta vs published numbers (`H1_RESULTS.md`, 120-trial series)

Published (Linux arm64 container, 10 s / 30 s / 5 pairs, policy 93):

| Cell | Published Go req/s | Published Mojo req/s | Published ratio |
| --- | ---: | ---: | ---: |
| F64 | 127,003.5 | 129,180.3 | 1.0203 |
| F1024 | 117,514.0 | 127,006.6 | 1.0869 |
| LATENCY (paired p99 ratio) | — | — | 0.9074 |

Shortened delta:

- F64: Go `−13%` req/s, Mojo `+16%` req/s, ratio moves `1.02 → 1.36`. Still passes the ≥0.90 target.
- F1024: Go `−20%` req/s, Mojo `+15%` req/s, ratio moves `1.09 → 1.55`. Still passes the ≥0.90 target.
- LATENCY: paired p99 ratio moves `0.91 → 1.13`. Still passes the ≤1.2 target.

The absolute throughput shift (both roles) is consistent with a different
host class: the published series used three container CPUs on an owned
rig, this unit uses the Docker Desktop Linux VM on an Apple M2 Pro with
six CPUs available. The direction of the Mojo/Go ratio is the signal
preserved by the shortened procedure, and the ≥0.90 / ≤1.2 targets at
F64, F1024 and LATENCY all still hold at this SHA.

## H2 shortened cell

The published H2 series uses h2load with per-request log sampling
(`--log-file`) and a single worker. The shortened cell mirrors that cell
type: `c=64 m=10` over `GET /fixed`, h2load `--alpn-list=h2 -t 1 -c 64
-m 10 --warm-up-time=5s -D 15s --log-file=…`, three alternating Go/Mojo
pairs. Negotiated ALPN `h2` and `TLS_AES_128_GCM_SHA256` on both servers.

Raw per-run TSV in `workspace/u111/h2_summary.tsv`.

| Role | req/s (median of 3) | p50 µs | p95 µs | p99 µs | succeeded (total) | failed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Go H2 (`GOMAXPROCS=1`) | 59,546 | 10,382 | 20,501 | 26,998 | 2,664,157 | 0 |
| Mojo H2 | 138,427 | 4,572 | 4,876 | 5,547 | 6,230,857 | 0 |

Paired ratios (median across 3 pairs): throughput Mojo/Go 2.327 ×,
p99 Mojo/Go 0.209 ×. Both the ≥0.90 throughput and ≤1.2 p99 targets
pass at this cell on this host at this SHA.

### Delta vs published H2 numbers (`H2_RESULTS.md`, 64×10 cell)

Published (Linux arm64 container, 10 s / 30 s / 5 pairs, policy 93):
Go 46,658 req/s, Mojo 91,422 req/s, paired throughput ratio 2.0081,
paired p99 ratio 0.2703. Shortened delta: both roles higher in absolute
req/s (consistent with the different host class), Mojo advantage larger
(ratio 2.00 → 2.33). The published verdict (both targets pass) still holds.

## Allocation and syscall counts per request

The H1 section of `H1_RESULTS.md` records "Allocation instrumentation
remains unavailable" at the strace reproduction block. This unit records
one set of allocation and syscall counts per request for the Mojo H1
server and a parallel Go H1 baseline on this host.

### Method and overhead

- **Mojo libc malloc shim**: `benchmarks/http/alloc_count/malloc_count.c`
  (`LD_PRELOAD`) counts `malloc`, `calloc`, `realloc`, `aligned_alloc`,
  `posix_memalign`, `memalign` call counts, their requested-byte sums
  and `free` call count. It bootstraps a 64 KiB arena so `dlsym(RTLD_NEXT, ...)`
  can resolve the real allocators before any instrumented allocation
  returns, and dumps a JSON summary at `atexit`. Overhead against the
  Mojo H1 server under saturated F64 load (`warmup 3 s / measure 10 s`,
  `c=64`): `150,266` req/s unshimmed vs `150,573` req/s shimmed
  (−0.20 %, within run-to-run noise). The shim measures libc-level
  allocations only; Mojo's internal arena/free-list allocators may
  satisfy allocations without reaching libc malloc, so the Mojo counts
  are a lower bound on total allocation work per request.
- **Go runtime MemStats**: `benchmarks/http_go/cmd/go-memstats-server`
  serves the same 64-byte `/fixed` payload plus `GET /_memstats`
  returning `runtime.MemStats.{Mallocs,Frees,TotalAlloc,HeapAlloc,
  HeapObjects,NumGC}` as JSON. The driver reads the endpoint before and
  after the measurement window; the delta covers the full in-process
  allocation path (not only libc malloc). Go allocations do not go
  through libc malloc, so an `LD_PRELOAD` shim would miss them.
- **strace -f -c**: for both servers, over the full owned child
  lifetime of a 10,000-request burst (`-rate 1000 -duration 10s`
  `-connections 32`, same shape as the allocation run). The totals
  include startup, warmup, measurement, drain and shutdown, matching
  the published H1 syscall methodology.

Measurement conditions for the allocation and syscall counts:

- 10,000 `GET /fixed` requests at 1,000 req/s (`-rate 1000 -duration 10s`).
- `-warmup 0` for the counting run; a separate 3 s warmup run runs
  immediately before to populate connection pools and arenas.
- 32 keep-alive connections.
- Driver `taskset -c 1,2`; server `taskset -c 0`.

### Allocation counts

Full report in `workspace/u111/alloc_report.json`.

| Server | Count scope | Allocations per request | Bytes per request |
| --- | --- | ---: | ---: |
| Mojo H1 | libc malloc family (`malloc`+`calloc`+`realloc`+`aligned_alloc`+`posix_memalign`+`memalign`) | 0.012 | 41.4 |
| Go H1 | `runtime.MemStats.Mallocs` delta | 21.05 | 2,261.5 |

Mojo totals over the 9,999 successful requests: 114 malloc, 3 calloc,
0 realloc, 1 aligned_alloc, 2 posix_memalign, 0 memalign; 98 free.
Mojo's near-zero libc allocation rate under this workload is consistent
with the server using an internal arena/free-list for per-request state
and keep-alive connections, so the libc counters capture process-wide
startup allocations rather than per-request work. Go's `Mallocs` delta
(210,549 new objects, 192,776 freed, 22,615,472 bytes of `TotalAlloc`
growth) counts every runtime allocation and includes
HTTP/net/http/http.ResponseWriter bookkeeping.

These numbers are not an apples-to-apples comparison of allocator work:
libc malloc counts (Mojo) and Go runtime object counts (Go) are different
instruments. They are reported together as a lower-bound baseline for
each server; a Mojo-side arena/allocation profiler would be needed to
report Mojo's internal allocation work.

### Syscall counts

Raw `strace -f -c` tables in `workspace/u111/syscalls_mojo.txt` and
`workspace/u111/syscalls_go.txt`.

| Server | Total syscalls | Errors returned | Syscalls per request |
| --- | ---: | ---: | ---: |
| Mojo H1 | 400,020 | 47 | 40.01 |
| Go H1 | 388,717 | 113,379 | 38.87 |

Key per-syscall counts (Mojo / Go): sendto 129,091 / —, recvfrom
129,142 / —, epoll_ctl 129,196 / 80, epoll_pwait 12,176 / 19,915;
Go reads 227,292 (113,304 EAGAIN errors) and writes 113,949. Error
returns are not HTTP response-error counts; most of Go's errors are
EAGAIN on edge-triggered epoll reads.

strace overhead is not instrumented here. The published H1 series
notes the strace -f -c diagnostic covers whole owned child lifetime
including startup/warmup/drain and that summed syscall time is not
on-CPU time or per-request cost. The same caveats apply to these
numbers.

## Reproduce

Build artifacts and shim inside the container (see `LINUX_NETWORK.md`
for container creation):

```bash
cd /work
pixi install --frozen -e tls-http2
GOTOOLCHAIN=go1.26.4 go -C benchmarks/http_go build -o build/bench/u111/http_go .
GOTOOLCHAIN=go1.26.4 go -C benchmarks/http_go build -o build/bench/u111/http-load ./cmd/http-load
GOTOOLCHAIN=go1.26.4 go -C benchmarks/http_go build -o build/bench/u111/go_memstats_server ./cmd/go-memstats-server
pixi run mojo build --Werror -I . benchmarks/http1_server.mojo -o build/bench/u111/http1_server
pixi run -e tls-http2 tls-build
pixi run -e tls-http2 hpack-test
pixi run -e tls-http2 bash -c "PATH=/usr/bin:/bin:\$PATH mojo build --Werror -Xlinker -ldl \
    -I . benchmarks/http2_tls_server.mojo -o build/bench/u111/http2_server"
cc -O2 -fPIC -shared -o build/bench/u111/alloc/libmalloc_count.so \
    benchmarks/http/alloc_count/malloc_count.c -ldl
```

Then run the measurement scripts (shortened; see the top of this file):

- `benchmarks/http/alloc_count/run_alloc_count.sh` — 10,000-request
  Mojo+Go allocation counts (writes `alloc_report.json`).
- Shortened H1 and H2 scenario drivers live in this unit's workspace;
  the published full procedure remains the authoritative driver.

## Limitations

- Not the published 10 s/30 s/5-pair procedure or the 120-trial / 90-trial
  qualifications.
- Loopback only inside the Docker Linux VM; no netem shaping, no 30-minute
  soak, no `maintained_cohort`.
- Mojo and Go allocation counts measure different allocator layers (see
  Method). Numbers are reported side by side, not as a strict ratio.
- strace overhead is not measured; the shim overhead is reported above
  as the only profiler whose overhead this unit instruments.
- No resource (CPU/RSS/FD) sampler window is attached to these runs;
  the published series' separate `sample_resources.py` remains the way
  to collect those.
