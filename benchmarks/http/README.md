# HTTP benchmarks

Phase 0 pins the measurement setup. Numbers are recorded here from
Phase 3 onward; this document fixes the procedure so Mojo and Go runs
stay comparable.

## Baseline

- Go toolchain: `go1.26.4 darwin/arm64` (local). CI re-records its own
  `go version` output with each measurement.
- Go baseline: `benchmarks/http_go/main.go` (`go.mod` pins `go 1.24`).
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

## Mojo benchmarks (landing later)

- `benchmarks/http_parse.mojo` (Phase 1): parser time by input size.
- `benchmarks/http_server.mojo` (Phase 3+): poll vs epoll/kqueue delta,
  Go comparison, CPU profile, memory measurement.

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
