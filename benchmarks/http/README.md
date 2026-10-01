# HTTP benchmarks

Phase 0 pins the measurement setup. Numbers are recorded here from
Phase 3 onward; this document fixes the procedure so Mojo and Go runs
stay comparable.

## Baseline

- Go toolchain: `go1.26.4 darwin/arm64` (local). CI re-records its own
  `go version` output with each measurement.
- Go baseline: `benchmarks/http_go/main.go` (`go.mod` pins `go 1.26` and
  `golang.org/x/net` for HTTPS+HTTP/2).
- Mojo toolchain: `pixi.toml` pinned `mojo >=1.0.0,<2` (local `1.0.0`).
- Build: Go `go -C benchmarks/http_go build -o /tmp/http_go_baseline .` (run from the repository root; `benchmarks/http_go` is its own module);
  Mojo optimized executable (`mojo build`), compile and startup time
  excluded from the measurement window.

Verified Phase 0 (loopback, `GOMAXPROCS=1`):

- `GET /fixed` returns 64 B (`a` x 64) with `Content-Length: 64`.
- `GET /json` returns exactly 1024 B `application/json`.
- `POST /echo` returns the request body verbatim (tested with 64 B).

## Fixed conditions

- Same handler shapes and byte counts on both servers (see above).
- Same keep-alive setting, same payloads, same connection counts,
  same socket options, logging disabled on both sides.
- Server pinned to one core equivalent first (`GOMAXPROCS=1` for Go,
  equivalent CPU limit for Mojo). Load generator runs on separate CPUs
  or a separate host.
- Production measurements use optimized executables.

## Scenarios (from Issue #42)

| Scenario | Conditions |
| --- | --- |
| Small fixed response | GET 64 B body, connections 1 / 64 / 1024 |
| Small API response | 1 KiB JSON, same construction on both sides |
| Request body | POST 1 KiB / 64 KiB, Content-Length and chunked |
| Many idle connections | 10,000 keep-alive, 100 active |
| Connection churn | keep-alive disabled, sustained accept/close |
| Slow client | slow header, slow body, slow reader mixed with normal clients |

## Procedure

- Warmup 10 s, measure 30 s, repeat at least 5 times.
- Record req/s, bytes/s, p50 / p95 / p99, error rate, CPU, RSS, fd count.
- Record allocation and syscall counts as a separate measurement with
  the profiler name and its overhead noted.
- Separate saturated throughput from fixed-arrival-rate latency. For
  latency runs use a generator that avoids coordinated omission and
  confirm the client itself is not saturated.
- For the 10,000-connection run, record successful connection count
  alongside the OS fd limit and the configured buffer budget.
- Soak 30 min: no monotonic fd growth, RSS stable within the budget
  plus connection metadata.

## Targets (unverified, Phase 0)

- Small fixed response at 64 and 1024 connections: >= 90% of the Go
  baseline throughput.
- Same unsaturated load: p99 within 1.2x of Go.
- Missing the target keeps the feature set intact; the shortfall is
  recorded with a profile as follow-up work.

## Running the Go baseline

```bash
go -C benchmarks/http_go build -o /tmp/http_go_baseline .
GOMAXPROCS=1 /tmp/http_go_baseline -addr 127.0.0.1:18080 &
curl -D - http://127.0.0.1:18080/fixed -o /tmp/fixed.body
curl -D - http://127.0.0.1:18080/json -o /tmp/json.body
curl -X POST --data-binary @/tmp/fixed.body \
  http://127.0.0.1:18080/echo -o /tmp/echo.body
```

HTTPS + HTTP/2 (after `pixi run -e tls-http2 tls-build`):

```bash
go -C benchmarks/http_go build -o /tmp/http_go_h2 .
GOMAXPROCS=1 /tmp/http_go_h2 -tls -addr 127.0.0.1:18442 \
  -cert build/tls/test-cert.pem -key build/tls/test-key.pem &
curl -k --http2 https://127.0.0.1:18442/fixed -o /tmp/fixed.h2.body
```

## Mojo benchmarks

- `benchmarks/http_parse.mojo` (Phase 1): parser time by input size.
- `benchmarks/http_server.mojo` (Phase 4): `pixi run benchmark-http-server`.
  Sequential keep-alive round-trips plus nonblocking tick time with many
  idle connections (ready-batch-only proof).
- `benchmarks/http2_tls_server.mojo` + `benchmarks/http/run_http2_bench.sh`
  (PR 9): HTTPS+HTTP/2 `/fixed`/`/json`/`/echo` vs the Go `-tls` baseline
  using `h2load`.
- `benchmarks/http3_server.mojo` + `benchmarks/http3_aioquic_baseline.py` +
  `benchmarks/http/run_http3_bench.sh` (PR 10): QUIC ALPN `h3` `/fixed`/
  `/json`/`/echo` vs a pinned aioquic 1.3.0 server using
  `benchmarks/http3_load.py` (aioquic client; Homebrew `h2load` lacks
  ngtcp2/nghttp3).

## Phase 3 poll baseline (preliminary, same host)

Not the formal procedure above (loader shared the server host, no CPU
pinning on the Mojo side, single 10 s run each). Recorded to anchor the
poll implementation before Phase 4 optimizes it.

- Machine: Apple M2 Pro, darwin/arm64, `mojo 1.0.0`, `go1.26.4`.
- Mojo server: blocking `serve` loop with the hello handler
  (`GET /hello` -> 17 B `text/plain`), `mojo build` binary, RSS
  ~12.8 MB with 50 keep-alive connections.
- Loader: 50 concurrent keep-alive clients, 10 s window, same host.
- Interop verified first: curl (200 + 404 + keep-alive reuse) and an
  independent Go `net/http` client (200/404/200 with exact bodies).

| Server | Throughput |
| --- | --- |
| Mojo poll server (`/hello`, 17 B) | ~28,000 rps, 0 failures |
| Go baseline (`/fixed`, 64 B, all cores) | ~80,000 rps, 0 failures |
| Go baseline (`/fixed`, 64 B, `GOMAXPROCS=1`) | ~56,000 rps, 0 failures |

Mojo sits near 50% of the pinned Go figure here, under the 90%
development target. Known unoptimized spots carried into Phase 4:
per-tick full-table scans (poll set build, deadline checks, interest
sync), a `time()` syscall per tick for `Date`, string copies on the
request path, and `List` prefix drains. No feature is cut to chase the
number; the gap is profiled and closed in Phase 4.

## Phase 4 kqueue baseline (preliminary, same host)

Same caveats as Phase 3 (loader shared the server host, single runs, no
CPU pinning on the Mojo side). Production `serve`-loop numbers with a
separate loader, `GOMAXPROCS=1` pinning, and the 30 s x 5 procedure above
are re-recorded as follow-up work; the harness below is checked in so the
comparison is reproducible (`pixi run benchmark-http-server`).

- Machine: Apple M2 Pro, darwin/arm64, `mojo 1.0.0`.
- Backend: kqueue (level-triggered) via `net/_sys/readiness.mojo`; the
  poll set-build is gone from the production path.
- Tick loop: no per-tick full-table scans. Ready events drive only touched
  connections (slot map + token generation check); capped pipelines
  re-drive via an explicit urgent list; fairness counters reset lazily per
  tick id; deadlines expire via an indexed min-heap and the wait timeout
  peeks the heap minimum.
- Harness (`benchmarks/http_server.mojo`, tick-driven, in-process):
  500 sequential keep-alive `GET /fixed` (64 B) round-trips, then 1000 idle
  keep-alive connections with nonblocking ticks.

| Measurement | Value |
| --- | --- |
| Sequential round-trips/s (tick harness, 64 B) | ~230/s |
| Avg nonblocking tick with 1000 idle conns | ~14 us |
| Idle connections accepted / active after close | 1000 / 0 |
| `test-http-server` (27 tests) | pass |
| `test-reactor` (11 tests, incl. EOF+unread) | pass |
| `test-sys` (18 tests, incl. ABI + queue fd leak) | pass |

The ~14 us idle tick (vs a poll build+scan proportional to the
registration count on every tick) is the Phase 4 delta: active-event
processing no longer walks the full connection table. Remaining profiled
costs carried forward (unchanged from Phase 3): one `Date` syscall per
tick, string copies on the request path, `List` prefix drains. No
bottleneck optimization beyond the readiness + scan removal was added, per
the Phase 4 rule (optimizations only with before/after measurements).

## HTTP/2 TLS (PR 9, measured)

HTTPS + ALPN `h2` comparison for the shared `/fixed` / `/json` / `/echo`
handlers. Numbers below are from a full Phase 0 procedure on one host
(warmup 10 s, measure 30 s, 5 runs). Raw h2load logs and mid-run
`ps`/`lsof` samples live under `build/bench/http2/` when the harness is
re-run locally (that directory is gitignored).

### Host and toolchain

| Item | Value |
| --- | --- |
| Host | Mac mini (Mac14,12), Apple M2 Pro, 32 GB |
| OS | macOS 27.0.1 (Darwin 27.0.0), `arm64` |
| Go | `go1.26.4 darwin/arm64` (`GOMAXPROCS=1`) |
| Mojo | `1.0.0` (`pixi.toml` pin `>=1.0.0,<2`) |
| OpenSSL (TLS shim / pixi `tls-http2`) | `3.6.4` via `pkg-config` |
| Load tool | `h2load` from Homebrew `nghttp2` 1.70.0 (`--alpn-list=h2`) |
| Certs | `build/tls/test-cert.pem` / `test-key.pem` from `pixi run -e tls-http2 tls-build` |

### Harness

- Go: `benchmarks/http_go/main.go` with `-tls` (stdlib + `golang.org/x/net/http2`, NextProtos `h2,http/1.1`). Default listen for this run: `127.0.0.1:18442`.
- Mojo: optimized `mojo build` of `benchmarks/http2_tls_server.mojo` (ALPN `h2` only) on `127.0.0.1:18443`. Requires `tls-build` + `hpack-test`.
- Driver: `benchmarks/http/run_http2_bench.sh` (documents `WARMUP_S` / `MEASURE_S` / `RUNS` / `CLIENTS` / `STREAMS`).
- Scenario measured here: `GET /fixed` (64 B), `clients=64`, max concurrent streams `1` and `10`, h2load `-t 1`. Loader and server share the host (same caveat as earlier Phase 3/4 notes); Go pinned with `GOMAXPROCS=1`, Mojo unpinned.

### Reproduce

```bash
pixi run -e tls-http2 tls-build
pixi run -e tls-http2 hpack-test
# Full Phase 0 (as recorded below):
WARMUP_S=10 MEASURE_S=30 RUNS=5 CLIENTS=64 STREAMS="1 10" \
  bash benchmarks/http/run_http2_bench.sh
```

### Results (mean of 5 runs; req/s from h2load; latency = h2load request median/p95/p99)

| Server | Conns | Streams | req/s (mean) | p50 (µs) | p95 (µs) | p99 (µs) | CPU % | RSS (MB) | fd* |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Go HTTPS+H2 | 64 | 1 | 42,551 | 1,300 | 2,368 | 2,882 | ~99 | ~20 | 75* |
| Mojo HTTPS+H2 | 64 | 1 | 32,504 | 1,966 | 2,070 | 2,180 | ~99 | ~38 | 85* |
| Go HTTPS+H2 | 64 | 10 | 52,101 | 11,554 | 21,252 | 25,592 | ~99 | ~32 | 75* |
| Mojo HTTPS+H2 | 64 | 10 | 51,223 | 11,964 | 15,662 | 17,802 | ~99 | ~39 | 85* |

\* `fd` was counted with the old `lsof -p | wc -l` sampler (includes header,
`cwd`/`txt`/mapped libraries). The harness now counts numeric FDs only;
these published values are inflated and will be recomputed on the next full
run.

Per-run req/s ranges: Go m=1 42,164–43,082; Mojo m=1 32,485–32,531; Go m=10 51,928–52,205; Mojo m=10 50,551–51,526. All runs: 0 failed / 0 errored.

### Target check

Development target for small fixed responses is ≥90% of the Go baseline
throughput (same unsaturated latency budget where applicable).

| Scenario | Mojo / Go req/s | Verdict |
| --- | ---: | --- |
| 64 conns × 1 stream | 76.4% | Miss — shortfall recorded; no features cut |
| 64 conns × 10 streams | 98.3% | Meet |

At single-stream concurrency Mojo trails Go on median latency (~1.5×) while
p95/p99 stay comparable or slightly better. Multiplexed streams close the
throughput gap. Follow-up profiling (not in this PR): TLS/HPACK path cost
and per-request handler overhead under low stream concurrency.

## HTTP/3 QUIC (PR 10, measured)

QUIC ALPN `h3` comparison for the shared `/fixed` / `/json` / `/echo`
handlers on loopback (RTT ≈ 0, induced loss 0%). Numbers below are from a
full Phase 0 procedure on one host (warmup 10 s, measure 30 s, 5 runs).
Raw load logs and mid-run `ps`/`lsof` samples live under
`build/bench/http3/` when the harness is re-run locally (that directory is
gitignored).

### Host and toolchain

| Item | Value |
| --- | --- |
| Host | Mac mini (Mac14,12), Apple M2 Pro, 32 GB |
| OS | macOS 27.0.1 (Darwin 27.0.0), `arm64` |
| Mojo | `1.0.0` (`pixi.toml` pin `>=1.0.0,<2`) |
| QUIC provider | quiche `0.29.3` (`net/quic/provider/Cargo.toml`, BoringSSL via quiche) |
| H3 baseline | aioquic `==1.3.0` (`pixi` feature `http3` / `tls-http3`) |
| Load tool | `benchmarks/http3_load.py` (aioquic 1.3.0 client). Homebrew `h2load` 1.70.0 advertises `--h3` but is not linked against ngtcp2/nghttp3, so it cannot drive H3 here. |
| Certs | `build/tls/test-cert.pem` / `test-key.pem` from `pixi run -e tls-http3 tls-build` |
| Loss | `0%` loopback (harness `LOSS_PCT` is a label only; no netem/pf injection in this recording) |

### Harness

- Baseline: `benchmarks/http3_aioquic_baseline.py` on UDP `127.0.0.1:18452`.
- Mojo: optimized `mojo build` of `benchmarks/http3_server.mojo` (quiche
  provider + UDP-only tick loop) on `127.0.0.1:18453`. Requires
  `tls-build` + `quic-build`.
- Driver: `benchmarks/http/run_http3_bench.sh` (documents `WARMUP_S` /
  `MEASURE_S` / `RUNS` / `CLIENTS` / `STREAMS` / `LOSS_PCT`).
- Scenario measured here: `GET /fixed` (64 B), `clients=64`, max concurrent
  streams `1` and `10`. Loader and server share the host (same caveat as
  PR 9). Mojo unpinned; aioquic is a single asyncio process.

### Reproduce

```bash
pixi run -e tls-http3 tls-build
pixi run -e tls-http3 quic-build
# Full Phase 0 (as recorded below):
WARMUP_S=10 MEASURE_S=30 RUNS=5 CLIENTS=64 STREAMS="1 10" \
  bash benchmarks/http/run_http3_bench.sh
```

### Results (mean of 5 runs; req/s and latency from aioquic load client; CPU/RSS/fd mid-measure)

| Server | Conns | Streams | Loss % | req/s (mean) | p50 (µs) | p95 (µs) | p99 (µs) | CPU % | RSS (MB) | fd* |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| aioquic H3 | 64 | 1 | 0 | 4,984 | 12,575 | 13,838 | 14,763 | ~100 | ~106 | 47* |
| Mojo H3 | 64 | 1 | 0 | 8,426 | 5,875 | 6,817 | 7,329 | ~50 | ~32 | 18* |
| aioquic H3 | 64 | 10 | 0 | 4,465 | 136,645 | 186,740 | 221,746 | ~98 | ~153 | 47* |
| Mojo H3 | 64 | 10 | 0 | 7,237 | 86,051 | 91,238 | 102,805 | ~43 | ~38 | 18* |

\* `fd` was counted with the old `lsof -p | wc -l` sampler (includes the
header plus `cwd`/`txt`/mapped files). The harness now counts numeric
descriptors only; these published values are inflated and will be recomputed
on the next full run.

Per-run req/s ranges: aioquic m=1 4,904–5,045; Mojo m=1 8,315–8,567;
aioquic m=10 4,183–4,744; Mojo m=10 7,208–7,262. All runs: 0 failed.

Notes on sources within this recording:

- Mojo rows: single Phase 0 session (`build/bench/http3/`).
- aioquic throughput/latency/CPU/RSS: Phase 0 re-run after the harness was
  fixed to sample the real Python PID (not the `pixi run` wrapper). Same
  host, procedure, and load shape as the Mojo session.

### Target check

There is no Go H3 peer in this PR; the pinned independent baseline is
aioquic 1.3.0. Relative to that baseline:

| Scenario | Mojo / aioquic req/s | Verdict |
| --- | ---: | --- |
| 64 conns × 1 stream | 169% | Exceed baseline |
| 64 conns × 10 streams | 162% | Exceed baseline |

Mojo’s quiche-backed path outperforms the Python aioquic server on
loopback for this small-response workload, with lower median latency and
RSS. Multiplexing (m=10) raises per-request latency on both sides as
expected when 640 in-flight streams share the client and server. Follow-up
(not in this PR): induced-loss runs (`LOSS_PCT` with an out-of-band
netem/pf path) and a non-Python H3 baseline if a stronger peer is needed.
