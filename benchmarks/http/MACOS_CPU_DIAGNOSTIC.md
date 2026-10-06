# macOS HTTP/1 stack diagnostic — 2026-10-04

This diagnostic brackets one sampled run with two unsampled controls for each
server. It identifies observed stacks and sampling perturbation; it is not the
five-trial Linux comparison, an unsaturated latency target check, or allocation
profiling. The six trials are independent and their latencies are not pooled.

## Source and conditions

- macOS 27.0.1 (26A434), arm64; native macOS scheduling, without Linux CPU affinity.
- Mojo 1.1.0 (8189361e), optimized `mojo build -O3 --Werror`; Go 1.26.4 arm64.
- Runtime snapshot87: SHA256
  `deb7661f366cddf7b3e62757835f77885e65bd04c8da1509ccebc9f8c7f71c17`.
  Its 306 regular files, 11 links, native source and prior binaries matched
  before and after execution. Later benchmark88 changes do not alter this runtime.
- Plain HTTP/1.1 loopback, `GET /fixed`, exact 64-byte response, keep-alive,
  64 active connections, closed loop (`-rate 0`), 5-second request timeout.
  TLS, cipher suites and handshakes are absent from this workload.
- Each trial has 10 seconds of warmup and a 30-second measurement window.
  Go server uses `GOMAXPROCS=1`; the Go loader uses `GOMAXPROCS=2` for both servers.
  The Mojo server has one networking event loop; its runtime worker threads
  remain visible to the sampler. This does not establish identical CPU restrictions.
- Every trial uses the same resource collector, with one-second intervals and
  30 observations. All 30 observations fall inside that trial's actual loader
  measurement window. Only the middle trial additionally runs `/usr/bin/sample`
  for a requested 30 seconds at 10-millisecond intervals.

The loader validates exact protocol, status, body and framing. Warmup and measured
errors are zero in all six trials. Each has 64 explicitly reported deadline
cutoffs; only successful completions inside the measurement window contribute to
latencies and throughput. The fixed 30-second window supplies the rate denominator.

## Results

| Server | Trial | Successful samples | Requests/s | p50 ms | p95 ms | p99 ms |
|---|---|---:|---:|---:|---:|---:|
| Go | Control before | 2,130,349 | 71,011.633 | 0.890417 | 1.348833 | 1.622583 |
| Go | Sampled | 1,992,684 | 66,422.800 | 0.914000 | 1.741667 | 2.220875 |
| Go | Control after | 2,059,656 | 68,655.200 | 0.915500 | 1.395125 | 1.787833 |
| Mojo | Control before | 1,892,239 | 63,074.633 | 1.010084 | 1.220584 | 1.758666 |
| Mojo | Sampled | 1,827,087 | 60,902.900 | 1.013916 | 1.674458 | 2.010500 |
| Mojo | Control after | 1,920,412 | 64,013.733 | 1.009834 | 1.120209 | 1.575583 |

The change is `(sampled / control - 1) × 100` for each adjacent control:

| Server | Relative to | Requests/s change | p50 change | p95 change | p99 change |
|---|---|---:|---:|---:|---:|
| Go | Before | -6.462% | +2.649% | +29.124% | +36.873% |
| Go | After | -3.252% | -0.164% | +24.839% | +24.222% |
| Mojo | Before | -3.443% | +0.379% | +37.185% | +14.320% |
| Mojo | After | -4.860% | +0.404% | +49.477% | +27.604% |

This single bracket includes normal scheduling drift as well as any sampling
perturbation. It does not isolate a causal profiler overhead percentage or
establish a repeatable Go/Mojo throughput ratio.

## Stack observations and limits

The completed Go report contains 2,717 snapshots for each of three threads; the
Mojo report contains 2,768 for each of nine threads. Multiplying counts by the
requested interval does not recover elapsed duration. Each report has one
millisecond-resolution Date/Time near tool launch, without exact first/last
snapshot timestamps or an explicit end timestamp. Launch-based nominal overlap
with the loader window is 29.998487 seconds for Go and 29.996431 seconds for Mojo;
using the report timestamp instead gives nominal overlaps of 29.939475 and
29.936625 seconds. These are timing estimates, not exact snapshot coverage.

Named collapsed top-of-stack observations include:

| Server | Frame | Observations |
|---|---|---:|
| Go | `write` | 783 |
| Go | `read` | 730 |
| Go | `kevent` | 115 |
| Mojo | `__sendto` | 759 |
| Mojo | `__recvfrom` | 598 |
| Mojo | `kevent` | 286 |

These are sampled stack occupancy, including syscall residency and waiting;
they are neither syscall counts nor on-CPU percentages. Eight parked Mojo
workers each have 2,768 semaphore-wait observations. Go also has runtime/parked
waits. Recursive call-graph totals overlap, and collapsed entries below five
observations are omitted. Four Go and 199 Mojo unknown call-graph records remain
unassigned; these are tree records, not disjoint sample counts. Optimized generic,
inlined or missing symbols are not attributed to invented functions. Allocation
profiling is unavailable; a stack mentioning allocation does not count allocations.

## Reproduce the diagnostic

Use the pinned toolchains, an owned output directory and isolated execution time.
From the repository root, build the existing programs:

```bash
export PROFILE_DIR="$(mktemp -d)"
GOTOOLCHAIN=local go -C benchmarks/http_go build -p 2 -o "$PROFILE_DIR/http_go" .
GOTOOLCHAIN=local GOMAXPROCS=2 go -C benchmarks/http_go build -p 2 -o "$PROFILE_DIR/http-load" ./cmd/http-load
pixi run --as-is -e tls-http3 mojo build -O3 --Werror -I . benchmarks/http1_server.mojo -o "$PROFILE_DIR/http1_server"
```

For each server, restart an owned process for control-before, sampled and
control-after. Choose one server command:

```bash
GOMAXPROCS=1 "$PROFILE_DIR/http_go" -addr 127.0.0.1:18580 -idle-timeout 3600s
"$PROFILE_DIR/http1_server"
```

Keep `PROFILE_DIR` for the binaries. Create a distinct `TRIAL_DIR` for each
server/trial, and use the same values in the separate terminals. Use port18580
for Go or port18081 for Mojo:

```bash
export TRIAL_DIR="$PROFILE_DIR/go-control-before"
mkdir "$TRIAL_DIR"
GOMAXPROCS=2 "$PROFILE_DIR/http-load" -url http://127.0.0.1:18580/fixed -connections 64 -warmup 10s -duration 30s -keepalive=true -timeout 5s -rate 0 > "$TRIAL_DIR/loader.json"
```

Record the actual newly owned server and loader PIDs as `SERVER_PID` and
`LOADER_PID`. Near the nominal warmup end, run the resource command for every
trial, and the stack sampler only for the sampled trial, in separate terminals:

```bash
python3 benchmarks/http/sample_resources.py --server-pid "$SERVER_PID" --loader-pid "$LOADER_PID" --interval 1 --samples 30 > "$TRIAL_DIR/resources.json"
/usr/bin/sample "$SERVER_PID" 30 10 -file "$TRIAL_DIR/stacks.txt"
```

Use a distinct directory per trial. Record actual launches/completions and retain
loader `measurement_window`, cutoffs and resource timestamps; clip resources to
that window rather than assuming startup alignment. Confirm sampler completion
and the report Process/Parent PIDs against the original live process identity.
Stop and reap only the owned server after each finite workload and verify socket
release before proceeding. The recorded run used 100-second per-trial supervision
and terminated/reaped all six servers, fourteen tool children and its runner.

## Provenance and first-attempt history

Selected source SHA256 values identify the actual inputs:

| Public source | SHA256 |
|---|---|
| [Mojo H1 server](../http1_server.mojo) | `83dade9462f1a711d4a878ebff2ecec2eda625a531be04e89425a379ea8dc673` |
| [Shared benchmark handler](../http_handler.mojo) | `c41103205ecb79b2c587d53c862c1bae1891cbe0d995c7aa1e87e6fc84c77b14` |
| [Go baseline](../http_go/main.go) | `d4179afef90a9cc73498e9a3fe82cf9d98ad8282186b1d318fd83e421ebd6961` |
| [Go loader](../http_go/cmd/http-load/main.go) | `454f03c13d99416b6803ab808930ae5f33e2caf17482ad1a70e1cd2124651724` |
| [Resource collector](sample_resources.py) | `3b4d4ca13d60b08fc499c82cf60fa4b763a6454347d85aa336eb83be4b795313` |

The actual executable digests are Go server
`d9e817232f0fc2aa5d70ad4e26e97fdb84203a9468e121b720dc88def467c8bf`,
Go loader `eb2875f594d4a4d963fefb4431276d8a561e08542eff56edf7fbad49b425804e`,
and Mojo server `7334882c139704afbd5356405ca4c59638f29274bac50ec3b52f35626f6187fb`.
The retained raw stack reports have SHA256
`b4f801b03625b7841de3d7f9dd34bdb5a7e251e5ed3675847822a1c02d82d8dd`
(Go) and `eae35529ed518c4582ddc6f4815da3f1b9362f846290bff302e9ada411503901`
(Mojo). Raw stacks are not imported into this documentation change.

The first procedure attempt stopped after two valid Go workloads because its
identity checker expected an unredacted report Path. Those records remain
historical and are excluded from the six fresh trials above. The retry accepted
the tool's redacted Path while checking exact report PID/parent PID and stable
live process start/executable identity. Runtime, source, toolchain, timeouts and
workload verdicts were unchanged. This diagnostic adds no acceptance threshold
and cannot substitute for the formal protocol comparison or FD/RSS soaks.
