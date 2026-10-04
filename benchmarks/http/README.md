# HTTP benchmarks

Phase 0 pins the measurement setup. Numbers are recorded here from
Phase 3 onward; this document fixes the procedure so Mojo and Go runs
stay comparable.

## Baseline

- Go toolchain: `go1.26.4 darwin/arm64` (local). CI re-records its own
  `go version` output with each measurement.
- Go baseline: `benchmarks/http_go/main.go` (`go.mod` pins `go 1.26` and
  `golang.org/x/net` for HTTPS+HTTP/2).
- Current Mojo toolchain: `pixi.toml` requires `mojo >=1.1.0,<1.2`;
  `pixi.lock` resolves Mojo `1.1.0`. Record the actual `mojo --version`
  for each run; historical results retain their recorded toolchain.
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

## Process resource samples

Monitor the actual server and load-generator PIDs on Linux or macOS with
Python 3.9 or later. Linux requires kernel `pidfd_open` support:

```bash
python3 benchmarks/http/sample_resources.py --server-pid "$SERVER_PID" --loader-pid "$LOADER_PID" --interval 1 --samples 30 > resources.json
python3 -m unittest discover -s benchmarks/http -p test_sample_resources.py
```

Both processes must outlive the requested samples. Sampling starts immediately;
the last planned sample is at `(samples - 1) * interval`, followed by collection
time. The command emits JSON and exits nonzero if either original process exits,
is replaced, or cannot be inspected. Terminal observations omit CPU, RSS and FD
metrics rather than reporting zero. A kernel process watch and initial start
token preserve the original process identity.

Each observation records wall and monotonic timestamps, cumulative CPU seconds,
interval CPU percent, RSS bytes and numeric open FD count. CPU percent uses
actual CPU capture times; 100% means one CPU core, and the first observation has
no interval percent. Linux reads `/proc` directly, with CPU resolution of one
clock tick. macOS reads cumulative `ps` TIME (0.01-second resolution) and counts
numeric `lsof` FDs, excluding mappings such as `cwd` and `txt`.

Linux records each PID's current `fd_limit_soft` and `fd_limit_hard` from
`/proc/PID/limits` on every sample, with source `proc_limits`. Finite limits are
integers; an unlimited value is the string `unlimited`. This required metadata
failing to read or parse makes the observation an error. macOS reports null
limits with source `not_exposed`; join direct startup `getrlimit` metadata by
original PID separately. Process limits do not describe the system-wide FD pool.

Linux also reports CPU affinity and the strictest visible cgroup v2 ancestor
quota. `visible_limit` and `visible_unlimited` describe only that visible tree:
outer ancestor quotas can be hidden by a cgroup namespace. `unavailable` means
the relevant metadata could not be read. macOS reports affinity and quota as
null with quota state `not_exposed`. Host logical CPU count is metadata, not a
claim about the target's available CPU capacity.

The artifact records actual schedule lag, per-sample collection wall time, and
collector CPU time including its `ps`/`lsof` helpers. These costs quantify the
collector's work; they do not establish its effect on benchmark results.
Delayed samples retain their actual timestamps. Align samples with workload
windows before drawing conclusions; this command does not yet receive loader
window markers. Client start-lag diagnostics and resource samples still require
controlled comparison runs to establish client capacity or server efficiency.

## Saturated HTTP/1 load

The Mojo H1/H2/H3 entrypoints and Go baseline emit a startup JSON line with
`event: "fd_limits"`, `source: "getrlimit"`, their own PID, and exact current
soft/hard `RLIMIT_NOFILE` values. This records the actual process after runtime
initialization; Go can raise its soft limit, so a parent's inherited limit does
not describe the running server. The values are a startup snapshot of process
limits, including each OS's raw infinity sentinel, not a global FD availability
claim. Join the PID to the monitored original process and record successful
connection counts and buffer settings separately.

```bash
python3 benchmarks/http/check_fd_metadata.py --mojo-server /tmp/http1-server --go-server /tmp/http_go
```

This check changes FD limits only inside owned test children, validates exact
limits/field order and Go runtime adjustment, and checks the exact fixed body.
Linux PID limit snapshots during the workload remain separate from this startup
record; macOS resource samples do not expose another process's current FD limit.

The dedicated Mojo HTTP/1 benchmark records a one-hour idle deadline, a
10,000-connection limit and its configured buffer budget at startup. Match that
deadline with `http_go -idle-timeout 1h` for HTTP/1 comparisons, including the
many-idle and 30-minute soak scenarios. The Go flag defaults to 60 seconds for
existing HTTPS/HTTP2 runs; zero or negative values are rejected. Production
`ServerConfig.default()` still uses a 60-second idle deadline. Header, body and
write deadlines retain their existing 5/30/30-second settings on both sides.

Build the independent Go standard-library loader with Go 1.26.4:

```bash
go -C benchmarks/http_go build -o /tmp/http-load ./cmd/http-load
/tmp/http-load -url http://127.0.0.1:18081/fixed -connections 64 -warmup 10s -duration 30s
/tmp/http-load -url http://127.0.0.1:18080/json -connections 64 -warmup 10s -duration 30s
/tmp/http-load -url http://127.0.0.1:18081/echo -body-size 65536 -chunked -connections 64
/tmp/http-load -url http://127.0.0.1:18081/fixed -keepalive=false -connections 64
```

Use identical arguments for the Go and Mojo endpoints and repeat each run at
least five times. The loader accepts plain HTTP URLs for `/fixed`, `/json` and
`/echo`; `-method` defaults to GET or POST for echo. Each worker has one active
request. `-timeout` bounds each request (default 5s). Warmup stops starting work
at its deadline and finishes outstanding requests before measurement, retaining
keep-alive connections. All drained warmup responses are validated, including
those completed after its deadline. Set `-warmup 0` only when warmup is
intentionally omitted.

One JSON record reports configuration, warmup counts, measured `started`,
`success`, `errors`, `cutoff`, `samples`, payload byte counts, requests/s,
response payload bytes/s, and nearest-rank p50/p95/p99 latency in milliseconds.
Only measured requests started and completed inside the fixed window count
toward success/errors and latency. Requests crossing its deadline are canceled
and reported as `cutoff`; `started = success + errors + cutoff` and
`samples = success`. Rates always use the configured measurement duration.
Warmup, worker startup and final cancellation time are excluded.

`measurement_window` records `start_unix_ns`, `end_unix_ns` and `elapsed_ns`
from the actual shared start/deadline after workers are ready, in both saturated
and fixed-arrival modes. The Unix nanosecond epoch boundaries describe the
scheduled half-open interval `[start, end)`; `end` is the exclusive cutoff, not
the time the phase returns after cancellation/drain. `elapsed_ns` uses Go's
same-process monotonic time subtraction and supplies `elapsed_seconds` and the
rate denominator. Align external resource samples using their wall-clock epoch,
not an assumed shared monotonic clock. Preserve integer nanosecond precision
when reading JSON.

A distinct `warmup_window` is emitted only when warmup runs. It describes its
scheduled interval; outstanding warmup responses may finish later, before the
measuring interval begins. Invalid measured trials still emit their actual
`measurement_window`. If configuration is rejected or warmup aborts before
measurement, that window is omitted; a failed warmup retains its own window.
Neither worker startup nor warmup/final drain is added to the measuring window.

Every success requires HTTP/1.1 status 200, explicit matching Content-Length and
the exact benchmark body; compression and redirects are disabled. Invalid
configuration, warmup failure, measured errors or zero successful measured
requests produce a nonzero exit status and `valid: false`. Cutoff is reported
separately. These runs measure saturated closed-loop throughput and its latency;
fixed-arrival latency uses the mode below. Resource sampling, idle and slow-client
runs remain separate scenarios.

## Fixed-arrival HTTP/1 latency

Use `-rate` to schedule a fixed integer number of requests per second:

```bash
/tmp/http-load -url http://127.0.0.1:18081/fixed -rate 1000 -connections 64 -warmup 10s -duration 30s
/tmp/http-load -url http://127.0.0.1:18080/fixed -rate 1000 -connections 64 -warmup 10s -duration 30s
```

`-rate 0` keeps saturated closed-loop behavior. A positive rate places arrivals
at absolute offsets `k / rate` from each window's start, without waiting for
previous responses. Workers and queue capacity each equal `-connections`.
Only those workers issue requests; a full queue records a dropped arrival and
the original schedule continues. Queue memory is bounded by the worker count.

`arrivals.scheduled` counts every planned arrival inside the measurement window.
`dropped` counts full-queue admissions; `unstarted` includes arrivals the scheduler
missed and queued requests that could not start before the deadline. The
invariants are `scheduled = started + dropped + unstarted` and
`started = success + errors + cutoff`. Any dropped/unstarted work, response error
or zero latency samples makes the result invalid and the command exit nonzero.
Warmup uses the same schedule, accounts for dropped/unstarted arrivals, and
validates all admitted work through its bounded drain before measurement.

Successful `latency_ms` samples run from planned arrival to completed validation,
including scheduler lag and queue waiting. `arrivals.service_latency_ms` measures
actual request start to completion for the same successful responses.
`start_lag_p99_ms`, `start_lag_max_ms` and `start_lag_samples` describe planned-to-
actual-start delay for all started requests, including errors and cutoff.
Invalid runs contain partial diagnostic latency samples and cannot establish a
latency comparison. These fields expose client lag; independent client resource
checks are still required to establish that the generator is not saturated.

## Scenarios (from Issue #42)

For the many-idle scenario, hold 9,900 idle sockets alongside 100 active
original connections, for exactly 10,000 total:

```bash
/tmp/http-load -url http://127.0.0.1:18081/fixed -idle-connections 9900 -connections 100 -warmup 10s -duration 30s
/tmp/http-load -url http://127.0.0.1:18080/fixed -idle-connections 9900 -connections 100 -warmup 10s -duration 30m
```

Use matching one-hour server idle deadlines as described above. The second
command illustrates the separate 30-minute soak; repeat the 30-second scenario
at least five times against each server. This mode requires `/fixed` and
keepalive. Each idle socket completes a strict initial fixed-response handshake,
receives no workload traffic through warmup/measurement, and completes the same
strict handshake on its original socket afterward. No reconnect can replace a
lost idle socket. Only initial/final confirmed counts are reported; final
confirmation detects EOF, reset or invalid replies and is required for validity.

Each active worker owns a client pinned to one preflight-confirmed original
socket. Reconnection attempts, `Connection: close`, local closure before the
measurement deadline or a worker unused during measurement invalidate the row.
Deadline cancellation remains explicit cutoff. Ordinary mode keeps the shared
client behavior. Setup/postflight each have a separate two-minute deadline
(`-connection-check-timeout`), with the existing `-timeout` bounding individual
operations. Their elapsed times are recorded outside the workload window.

The `idle_connections` result object records requested total, confirmed idle
initial/final and active initial counts, measured active use, forbidden
replacement attempts, early active closures, setup/postflight times and the
loader's effective soft/hard FD limits, read inside the running Go process.
Go can raise its own soft limit at startup, so an inherited launcher value is
insufficient. Requests exceeding that loader limit fail before
dialing; other setup failures retain partial confirmed counts and fail the row.
Sockets close on every exit path. The loader's limit does not describe the
server's limit: record the actual server FD limit and configured buffer budget
separately, together with timestamped server/client CPU, RSS and FD samples.
Short functional probes do not satisfy the exact 10,000-connection or 30-minute
soak evidence requirements.

For a mixed slow-header/slow-body probe, add explicit cohorts to ordinary
`/fixed` clients. Both counts default to zero; this mode requires keepalive and
cannot combine with the idle mode:

```bash
/tmp/http-load -url http://127.0.0.1:18081/fixed -connections 64 -slow-headers 8 -slow-bodies 8 -warmup 10s -duration 30s
/tmp/http-load -url http://127.0.0.1:18080/fixed -connections 64 -slow-headers 8 -slow-bodies 8 -rate 1000 -warmup 10s -duration 30s
```

Use identical flags for both servers and the matched server deadlines above.
`-slow-interval` defaults to 250ms: headers remain incomplete through eight
one-byte ticks, then validate the exact 64-byte reply; bodies require a strict
HTTP/1.1 `100 Continue`, send 65536 bytes at 1024 bytes per tick, then validate
that exact echo. Nominal request phases are 2s and 16s; configurations reaching
the existing 5s header or 30s body deadline fail. Tick lag is recorded;
I/O deadline and response errors invalidate the row. Server deadlines remain
unchanged.

Every cohort slot owns one socket, strictly probes `/fixed` before the workload,
reuses it for all cycles, and probes it again afterward. No connection is
replaced. At workload end, workers finish the finite current request promptly,
validate its response and the original socket, then close and join. Individual
I/O uses `-timeout`, and original-socket probes also use the separate
`-connection-check-timeout`; cleanup remains bounded on error paths.

`slow_clients.headers` and `.bodies` each record requested and confirmed
initial/final counts, closed owned sockets and slots with measured
incomplete-phase drip traffic. The object also records profile constants,
loader FD limits and setup/postflight time. Per-kind `warmup` and `measurement` entries
use exactly the ordinary half-open phase windows. `incomplete_ns` is summed
connection time, so it can exceed one window when multiple sockets overlap.
`request_bytes_written` counts accepted client writes completed inside the
window; `drip_bytes_written` counts only the scheduled one-byte/1024-byte
ticks, excluding prefixes and final completion. `validated_cycles` and
`validated_response_payload_bytes` count complete strict response validations
inside it. Total profile bytes/cycles retain events
outside the windows. These are client I/O/validation timestamps, not peer ACK or
packet timings. Postflight cannot inflate ordinary success, throughput or
latency. Every configured slot must have measured incomplete overlap and actual
drip writes, and complete a validated cycle plus postflight to make the row valid.

Ordinary cutoff, response checks and dropped/unstarted arrival gates apply
unchanged. Tick lag and arrival diagnostics expose scheduling pressure; record
actual loader/server CPU, RSS and FD evidence separately before claiming client
capacity. Reader behavior is described below; formal five-trial comparison results remain separate.

Add `-slow-readers 8` to the same mixed `/fixed` keepalive commands to include
slow readers (default zero). Each reader owns one original socket, requests a
65536-byte receive buffer and records its actual raw `SO_RCVBUF` plus original
local/remote addresses. Set/query failures invalidate setup; the reported raw
value can differ across operating systems.

A finite reader batch sends eight pipelined 1 MiB `/echo` bodies and validates
eight exact HTTP/1.1 200 replies in order. The first byte of response i must be
`b+i`, with the remaining bytes all `b`; one shared immutable payload supplies
the uploads. The writer proceeds concurrently with 65536-byte paced reads,
using one validation buffer per reader. At the 250 ms default, each response
has sixteen read quanta (4 s nominal) and a full batch takes 32 s. Uploads do
not wait for previous replies; accepted uploads can themselves block.

Reader directional I/O uses a fresh 30 s budget clamped to an absolute finite
batch cap from `-connection-check-timeout` (2 min default), recorded separately
from ordinary `-timeout`. This cap starts at each batch admission. A caller's
shorter cap can invalidate the batch. Pacing waits also stop at the finite cap,
and an expired batch is rejected before reading buffered body bytes. Nominal
response pacing reaching 30 s is
rejected. Server 5/30/30 s deadlines and ordinary requests remain unchanged;
a single aggregate 30 s cap would incorrectly reject the default 32 s batch.
At workload end, stop starting batches and pacing, finish the finite concurrent
uploads/reads, confirm the original socket, close and join. Errors close that
owned socket before joining its blocked writer.

`slow_clients.readers` has the same per-kind connection gates. `reader_sockets`
records actual socket buffer values and tuples; reader profile constants and
I/O/batch budgets are explicit. Reader windows record returned payload bytes,
actual scheduled `paced_response_bytes_read` and `paced_read_quanta`, tick lag,
validated responses/payloads and batches. `incomplete_ns` for readers measures
known unread response time after strict headers until body consumption, clipped
to the identical ordinary windows. Header prefetch, upload writes and sleep
duration cannot qualify a reader as measured; actual paced reads and known
unread overlap plus all eight strict replies/postflight are required. Totals
retain events outside the workload windows. No profile work inflates ordinary
success, throughput or latency, and ordinary overload remains invalid.

`reader_server_send_pressure` reports `unverified`: client unread state or
slower reads do not establish that a server application send blocked. The real
TCP test fixture proves a large server Write remains pending with an owned
small send buffer while ordinary siblings progress, then completes after read
credit is released. This fixture does not change benchmark socket settings.
Unchanged actual Go/Mojo server pressure requires separate independent evidence.
Do not treat a sleeping socket, a blocked client upload or functional reader
validation as that proof. Formal five-trial comparisons and capacity evidence
remain separate from short functional checks and instrumented pressure trials.

| Scenario | Conditions |
| --- | --- |
| Small fixed response | GET 64 B body, connections 1 / 64 / 1024 |
| Small API response | 1 KiB JSON, same construction on both sides |
| Request body | POST 1 KiB / 64 KiB, Content-Length and chunked |
| Many idle connections | 10,000 keep-alive, 100 active |
| Connection churn | keep-alive disabled, sustained accept/close |
| Slow client | slow header, slow body, slow reader mixed with normal clients |

## Procedure

For real TCP/UDP RTT and loss without changing host networking, use the
[isolated Linux procedure](LINUX_NETWORK.md).
The [2026-10-04 Linux results](LINUX_RESULTS.md) record real RTT/loss
validation and distinguish it from the remaining performance procedure.

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

- `benchmarks/http1_server.mojo`: optimized HTTP/1.1 `serve`-loop endpoint on
  `127.0.0.1:18081`, using the same fixed/JSON/echo handlers as H2/H3 and Go.
  Build with `pixi run mojo build --Werror -I . benchmarks/http1_server.mojo
  -o /tmp/http1_server`. Verify exact responses and keep-alive with
  `python3 tests/test_http1_benchmark.py --server /tmp/http1_server
  --go-baseline /tmp/http_go_baseline` from the repository root.

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

The H3 loader preserves its seven metric tokens and appends `warmup_successes`,
`late_responses`, `load_start_unix_s`, `measurement_start_unix_s`,
`measurement_end_unix_s`, `clock_anchor_span_s` and `rate_denominator_s`.
The endpoints describe its scheduled completion window, including both
boundaries. Quantiles contain successful responses completed in that window;
a request begun during warmup retains its full latency. `late_responses` counts
status200 completions after the deadline, before fixed-body validation. Failed
counts cover all phases and connection errors; these are not conserved request
counts. Existing exit gates and classification are unchanged.

A wall-clock reading bracketed by two `perf_counter` readings maps the schedule
through the bracket midpoint. Epoch fields have six decimal places; mapping
uncertainty includes half the reported bracket span, clock precision and
formatting. One anchor cannot detect later wall-clock steps or drift. For
same-host resource clipping, select sample timestamps within the mapped window;
interval CPU observations need both endpoints inside it. Handshakes use the
scheduled warmup, and final drain can finish later. These fields do not establish
client saturation, handshake timing or full-window resource evidence; historical
mid-run samples still use their original startup-relative delays.

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

## Multiplex matrix (PR 11, measured)

Connections × streams varied independently over `GET /fixed`, plus the
slow-stream, cancellation, and loss scenarios per protocol. Shortened
procedure (labeled as such; Phase 0 full-length numbers are the PR 9/10
sections above).

### Host and procedure

- macOS 27.0.1, Apple M3 Max, `h2load` nghttp2/1.70.0, aioquic 1.3.0,
  hyper-h2 4.4.1 (`h2==4.4.1`, pinned in the `http2` feature).
- `WARMUP_S=2 MEASURE_S=4 RUNS=2 CONNS="1 16" STREAMS="1 10"`, harness
  default SKIP flags otherwise; `SKIP_SPECIAL=1` for the matrix tables and
  a separate `RUNS=1 CONNS="1" STREAMS="1"` pass for the scenarios.

```bash
WARMUP_S=2 MEASURE_S=4 RUNS=2 CONNS="1 16" STREAMS="1 10" SKIP_SPECIAL=1 SKIP_H3=1 \
  bash benchmarks/http/run_multiplex_matrix.sh
WARMUP_S=2 MEASURE_S=4 RUNS=2 CONNS="1 16" STREAMS="1 10" SKIP_SPECIAL=1 SKIP_H2=1 \
  bash benchmarks/http/run_multiplex_matrix.sh
```

### HTTPS + HTTP/2 matrix (mean of 2 runs; req/s and latency from h2load)

| Server | Conns | Streams | req/s (mean) | p50 (µs) | p95 (µs) | p99 (µs) | CPU % | RSS (MB) | fd |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Go HTTPS+H2 | 1 | 1 | 19,715 | 46 | 60 | 86 | ~92 | ~17 | 6 |
| Mojo HTTPS+H2 | 1 | 1 | 17,652 | 53 | 64 | 85 | ~67 | ~19 | 8 |
| Go HTTPS+H2 | 1 | 10 | 43,582 | 221 | 266 | 418 | ~99 | ~18 | 6 |
| Mojo HTTPS+H2 | 1 | 10 | 43,975 | 220 | 242 | 276 | ~99 | ~19 | 8 |
| Go HTTPS+H2 | 16 | 1 | 47,161 | 312 | 526 | 822 | ~99 | ~18 | 21 |
| Mojo HTTPS+H2 | 16 | 1 | 32,645 | 482 | 526 | 591 | ~99 | ~23 | 23 |
| Go HTTPS+H2 | 16 | 10 | 44,907 | 3,545 | 5,245 | 6,220 | ~99 | ~19 | 21 |
| Mojo HTTPS+H2 | 16 | 10 | 46,679 | 3,420 | 4,000 | 5,280 | ~99 | ~23 | 23 |

Per-run req/s ranges: Go c1m1 19,616–19,815; Mojo c1m1 17,630–17,674;
Go c1m10 42,685–44,479; Mojo c1m10 43,972–43,978; Go c16m1 46,895–47,426;
Mojo c16m1 32,618–32,671; Go c16m10 44,768–45,046; Mojo c16m10
46,009–47,350. All runs: 0 failed, rc=0.

### HTTP/3 matrix (mean of 2 runs; req/s and latency from the aioquic client)

| Server | Conns | Streams | req/s (mean) | p50 (µs) | p95 (µs) | p99 (µs) | CPU % | RSS (MB) | fd |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| aioquic H3 | 1 | 1 | 3,376 | 216 | 264 | 322 | ~66 | ~53 | 7 |
| Mojo H3 | 1 | 1 | 4,620 | 167 | 206 | 259 | ~28 | ~20 | 8 |
| aioquic H3 | 1 | 10 | 6,043 | 1,572 | 1,788 | 1,961 | ~100 | ~62 | 7 |
| Mojo H3 | 1 | 10 | 6,154 | 1,568 | 1,792 | 2,023 | ~36 | ~20 | 8 |
| aioquic H3 | 16 | 1 | 4,280 | 3,603 | 4,056 | 4,282 | ~99 | ~68 | 7 |
| Mojo H3 | 16 | 1 | 6,112 | 1,920 | 2,444 | 2,771 | ~48 | ~22 | 8 |
| aioquic H3 | 16 | 10 | 4,052 | 39,230 | 40,850 | 43,246 | ~99 | ~73 | 7 |
| Mojo H3 | 16 | 10 | 5,605 | 27,574 | 30,336 | 31,424 | ~46 | ~22 | 8 |

All runs: 0 failed, rc=0.

### Special scenarios

The slow/cancel drivers also report timing for the existing sibling batch.
`sibling_samples` counts only exact successful bodies/statuses with actual
dispatch and completion timestamps; `sibling_completed` and
`sibling_missing_timing` disclose usable and missing/out-of-window timings.
`sibling_req_s` divides successes by the interval beginning just before phase
dispatch and ending at the last actual sibling completion, excluding idle polls,
target drain, deliberate sleep and reuse. Latencies include upload and withheld
credit waits. `sibling_p50_us`, `sibling_p95_us` and `sibling_p99_us` use sorted
index `floor(fraction * (samples - 1))`; empty quantiles are `None`.
Failures preserve the existing verdict and use the actual observation endpoint
with `sibling_window_scope=failed_phase_observation`. Window epochs use one
bracketed wall-clock anchor; its span and half-span uncertainty are reported.
These small batches are not 30-second saturated throughput or population tail
estimates. Keep each trial separate and retain full-fixture `elapsed_ms`.

Both HTTP/2 special scenarios run over a **single** HTTP/2 connection
(`benchmarks/http/http2_scenarios.py`, hyper-h2): the target stream and its
siblings share one connection, so a server with per-connection
head-of-line blocking or broken `RST_STREAM` handling cannot pass. The
earlier `curl --limit-rate` + `h2load` version could not show this, because
those are separate processes and therefore always separate connections;
`h2load` still drives the throughput matrix above.

| Proto | Server | Scenario | Verdict | Detail |
| --- | --- | --- | --- | --- |
| h2 | Go | slow | pass | 1 conn: 8/8 siblings exact 64 B while the upload stream was still open; echo completed after release |
| h2 | Mojo | slow | not run | see note below |
| h2 | Go | cancel | pass | 1 conn: 274 cancel cycles (unsent residual > 256 MiB budget); target+8 siblings FC-blocked across RST (65535 B at reset); siblings completed after release; post-reset full echo + GET /fixed OK |
| h2 | Mojo | cancel | not run | see note below |
| h2 | Go | loss | skip | pf/dummynet needs root; no-loss reference 49,882 req/s |
| h2 | Mojo | loss | skip | pf/dummynet needs root; no-loss reference 35,860 req/s |
| h3 | aioquic | slow | pass | 1 conn incomplete upload: 8/8 siblings exact 64 B while POST /echo was still open; echo completed after finish (`method=incomplete_upload`) |
| h3 | Mojo | slow | pass † | held 262,144 B while 8/8 siblings completed |
| h3 | aioquic | cancel | pass | 257 incomplete-reset cycles with peer-ACK'd 256 KiB each (> 64 MiB request-body budget); reset target in-flight; 8/8 siblings outstanding across the reset and completed; post-reset GET /fixed on the same connection OK |
| h3 | Mojo | cancel | pass † | reset target in-flight; 8/8 siblings completed |
| h3 | aioquic | loss | pass | 5% client datagram drop, req/s 5,460, 0 failed |
| h3 | Mojo | loss | pass † | 5% client datagram drop, req/s 6,134, 0 failed |

† Historical results recorded by an earlier revision of the scenario drivers, before the
incomplete-upload H3 slow criterion, post-reset connection probe, sibling
body validation and the partial-run rejection were added, and not
re-measured at that time: the Mojo servers could not be built on that host (the Mojo
build in the `tls-http2` and `tls-http3` environments fails to parse
`net/http/_encoder.mojo` on `InlineArray`, which is unrelated to this harness
and reproduces on an unmodified checkout). These rows therefore show the Mojo
servers were not broken at that revision; they are not evidence under the
current criteria.

### Current HTTP/3 cancellation validation (2026-10-04)

The current driver exposed a transport-credit leak: resetting 100 incomplete
uploads exhausted the peer's initial bidirectional stream allowance. The
provider now closes its send direction on a received reset. This returns stream
credit even for requests that never produced a response.

Recorded on macOS arm64 with Mojo 1.1.0 (8189361e), quiche 0.29.3 and
aioquic 1.3.0, using main `43938a8` plus this PR's reset-credit fix. The optimized
Mojo benchmark binary loads the rebuilt provider; no CPU pinning or separate
load-generator host was used. These are single-run correctness checks, not the
formal performance comparison or a total-engine-memory stability claim.

```bash
pixi run -e tls-http3 quic-build
pixi run -e tls-http3 mojo build --Werror -I . \
  benchmarks/http3_server.mojo -o /tmp/http3_server
/tmp/http3_server &
server_pid=$!
for scenario in slow cancel loss; do
  pixi run -e tls-http3 python benchmarks/http/http3_scenarios.py \
    --url https://127.0.0.1:18453/fixed --scenario "$scenario" \
    --siblings 8 --duration 30
done
kill "$server_pid"
```

| Scenario | Current result |
| --- | --- |
| Slow | Pass: incomplete upload stayed open while 8/8 siblings completed with validated bodies; final echo validated, elapsed 393 ms |
| Cancel | Pass: 257 ACK-confirmed partial-upload resets (67,371,008 B, beyond the 64 MiB application request budget); 8/8 sibling bodies and post-reset request passed, elapsed 3,154 ms |
| Loss | Pass: 5% seeded client UDP drop, 30 s, 4 connections × 4 streams; 224,422 successful requests, zero failures, 14,856/300,597 sent datagrams dropped; 7,481 req/s, p50 1,981 µs, p99 4,143 µs |

The provider also has an in-memory regression that cancels 105 requests against
the 100-stream allowance, verifies pending request-byte release and completes a
subsequent request. The older dagger-marked H3 rows above remain historical;
the current checks supply the missing current-criteria H3 evidence. H2
packet-loss measurements, full-duration comparisons and engine memory
measurements remain separate work.

The two `h2 | Mojo` rows in the earlier table are *not run* rather than carried over: the previous
`pass` entries came from the `curl` + `h2load` version, which cannot exercise
these properties at all, so re-recording them was not possible even before the
build problem. Mojo 1.1 now builds both servers. Those rows remain historical;
the current H2 rerun below and H3 rerun above supply the current correctness
evidence without replacing the earlier throughput measurements.

### Current HTTP/2 slow/cancel validation (2026-10-04)

The cancellation driver's upload loop left DATA queued while waiting for credit,
then continued polling until the peer went idle even after enough credit
arrived. With Mojo's smaller receive windows, those repeated idle waits could
exhaust the scenario's 300-second budget. Driver `c538fb5` flushes queued DATA
before waiting and resumes upload as soon as the next frame fits. Ordinary
response draining, deadlines and all correctness assertions are unchanged;
this result required no HTTP/2 server change.

Both server sources are main `43938a8d5f536e09f3d252cc04622223d949ffc8`;
the scenario driver is `c538fb56ad69a9417bbbf9b0ff92519ebe8ffd18`.
Recorded on Apple M2 Pro (12 CPUs, 32 GiB), macOS 27.0.1 / Darwin 27.0.0
arm64, with Mojo 1.1.0 (8189361e), Go 1.26.4, OpenSSL 3.6.4 and hyper-h2
4.4.1. The optimized Mojo executable used the existing TLS/HPACK artifacts
and generated test certificate; Go used its default `GOMAXPROCS`. Servers
and client shared the host, with no CPU pinning or induced network loss.

| Server | Scenario | Current result |
| --- | --- | --- |
| Mojo | Slow | Pass: 8/8 exact sibling bodies while the target upload remained unfinished; final target echo and body validated, elapsed 138 ms |
| Go | Slow | Pass: the same assertions, elapsed 115 ms |
| Mojo | Cancel | Pass: 274 cycles, 65,535 target response bytes at reset; target flow-blocked at reset and siblings flow-blocked before and after reset; 8/8 sibling bodies, full echo reuse and subsequent GET validated, elapsed 17,234 ms |
| Go | Cancel | Pass: the same assertions and counts, elapsed 15,245 ms |

The cancellation proof's estimated unreleased response remainder is
269,353,234 B, exceeding the configured 268,435,456 B response budget.
Each scenario uses one connection. These are single-run protocol correctness
checks; elapsed time is diagnostic wall time, not a request latency or
throughput comparison. They do not establish fixed-arrival latency, allocation
or syscall cost, nonzero RTT/loss behavior, or 30-minute RSS/fd stability.
The full production performance matrix remains incomplete.

Reproduce with the toolchain versions above, from a checkout of the server
revision with the fixed driver available in Git:

```bash
pixi run -e tls-http2 tls-build
pixi run -e tls-http2 hpack-test
pixi run -e tls-http2 mojo build --Werror -I . \
  benchmarks/http2_tls_server.mojo -o /tmp/http2_server
go -C benchmarks/http_go build -o /tmp/http_go_h2 .
git show c538fb56ad69a9417bbbf9b0ff92519ebe8ffd18:benchmarks/http/http2_scenarios.py \
  > /tmp/http2_scenarios.py
/tmp/http2_server &
mojo_pid=$!
/tmp/http_go_h2 -tls -addr 127.0.0.1:18442 \
  -cert build/tls/test-cert.pem -key build/tls/test-key.pem &
go_pid=$!
pixi run -e tls-http2 python - <<'PY'
import socket
import time
for port in (18443, 18442):
    deadline = time.monotonic() + 5
    while True:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)
PY
for port in 18443 18442; do
  for scenario in slow cancel; do
    pixi run -e tls-http2 python /tmp/http2_scenarios.py \
      --url "https://127.0.0.1:$port" --scenario "$scenario" --siblings 8
  done
done
kill "$mojo_pid" "$go_pid"
```

### Target check

Targets are >=90% of the Go baseline (H2) with p99 within 1.2x, and >=90% of
the aioquic baseline (H3).

| Scenario | Mojo / peer req/s | Verdict |
| --- | ---: | --- |
| h2 1 conn × 1 stream | 89.5% | Marginal miss (−0.5 pts), p99 85 µs vs 86 µs |
| h2 1 conn × 10 streams | 100.9% | Meet |
| h2 16 conns × 1 stream | 69.2% | Miss — recorded, no features cut |
| h2 16 conns × 10 streams | 103.9% | Meet |
| h3 1 conn × 1 stream | 136.8% | Exceed baseline |
| h3 1 conn × 10 streams | 101.8% | Meet |
| h3 16 conns × 1 stream | 142.8% | Exceed baseline |
| h3 16 conns × 10 streams | 138.3% | Exceed baseline |

Interpretation: multiplexed HTTP/2 (m=10) reaches or exceeds the Go baseline
at both connection counts, and in both m=10 cells Mojo's p50, p95, and p99
are at or below Go's. Latency is only claimed per percentile: the target
metric p99 is at or below Go in every cell (1×1 85 vs 86 µs, 1×10 276 vs
418 µs, 16×1 591 vs 822 µs, 16×10 5,280 vs 6,220 µs), while p50/p95 do
regress in the two single-stream cells (1×1 53/64 vs 46/60 µs; 16×1 482/526
vs 312/526 µs). Those two cells are also the throughput misses, so the p50/p95
gap tracks the single-stream shortfall rather than a tail-latency problem.
The 16×1 HTTP/2 shortfall (69%) is consistent with the PR 9 single-stream
result and is carried forward as profiling follow-up (TLS/HPACK path cost),
not a feature cut. HTTP/3 exceeds the Python baseline in every cell, with
lower median latency everywhere and lower p99 in every cell except
1 conn × 10 streams (2,023 µs vs 1,961 µs, still within 1.2x).

Slow-stream and cancellation pass for every server actually exercised with
the current harness — HTTPS+H2 against the Go baseline, HTTP/3 against
aioquic — meaning the server keeps serving siblings while another stream on
the *same* connection is still open (H2 and H3: an incomplete POST /echo
upload). The H2 driver also withholds the target's receive credit so it does
not depend on a rate limit or on wall-clock timing. The H3 slow driver cannot
withhold QUIC `MAX_STREAM_DATA` through aioquic (credit tracks the highest
received offset), so it matches H2 on the request side instead: siblings must
complete while the large upload is still unfinished, then the upload is
finished and the echo body is checked. Cancellation on both protocols also
requires a post-reset request on the same connection so a GOAWAY/draining
server that only finishes already-admitted siblings cannot pass.
That claim is scoped to the runs above. The current H2 and H3 validation
sections provide Mojo's slow/cancel correctness evidence; the earlier
`not run` and dagger-marked rows remain historical. The throughput matrix
is unchanged. Loss via pf/dummynet is skipped on this host (no passwordless
sudo). The current H3 validation at `349a1f6` records a 5% client-side
datagram-drop check for Mojo with zero failures; the dagger-marked loss rows
remain historical. This supplies correctness evidence under induced loss,
without a pinned throughput comparison. When dummynet is available the
harness reads `dnctl pipe list`
and configures the first unused id (H2 42–61, H3 62–81) rather than a fixed
one, because `dnctl pipe N config` targets an existing pipe instead of
allocating a private one; the chosen id is recorded in the scenario detail
and only that pipe is deleted afterwards, so a run never reconfigures or
removes shaping that already existed on the host.
