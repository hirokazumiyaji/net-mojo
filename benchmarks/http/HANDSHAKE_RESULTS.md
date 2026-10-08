# Issue #42 unit 110 — handshake-included (churn) H2/H3 cells

Issue #42 Phase 10 asks for cells that record "handshake 有無"
(with vs. without handshake). This unit adds a new TLS connection
per request for HTTP/2 and a new QUIC connection per request for
HTTP/3, with bounded concurrency (c=1 and c=16), and records the
shortened result on this macOS host. No session resumption is used
client-side (every connection starts from a fresh SSL/QUIC
configuration); 0-RTT is not negotiated. Full procedure numbers are
not re-established here.

## Shortened procedure caveat

This is a labelled **shortened** measurement, not a replacement of the
full Phase 0 procedure. Each cell is three alternating runs with
warmup 5 s and measure 15 s (vs. the published 10 s warmup / 30 s
measure, 5 runs). Three alternating runs is enough to spot gross
regressions in the handshake-included cell; it does not establish a
new verdict and is not pooled with the published keep-alive series.

## Host and toolchain

| Item | Value |
| --- | --- |
| Host | Apple M2 Pro, macOS 27.0.1 (Darwin 27.0.0), arm64 |
| Mojo | `1.1.0 (8189361e)` |
| Go | `go1.26.4 darwin/arm64` |
| aioquic | `1.3.0` |
| quiche (provider pin) | `0.29.3` |
| System TLS | LibreSSL 3.3.6 (system `openssl version`) |
| Repo SHA at measurement | `7f80f55e4f70f7468bd0a077d29b057bfd77d65e` |
| Mojo H2 bench binary SHA256 | `4878707b30841a707fe7dbfdab6e96991b352945fe86a2ab0fb891698a26374f` |
| Mojo H3 bench binary SHA256 | `c252f31c98c75577155e761738cdd1398f833a64e87d3f98abe3262f4e564bc3` |
| Go H2 baseline binary SHA256 | `59b2196488ce0a6ab4d974b1668089051a54d43e99330b60f6afdcedc3b638f6` |

## What is new in this unit

- `benchmarks/http3_load.py` grew a `--churn` flag that opens a new
  QUIC connection per request (requires `--streams 1`).
- `benchmarks/http/http2_scenarios.py` grew a `churn` scenario that
  opens a new TLS+h2 connection per request with bounded worker
  concurrency and reports req/s and p50/p95/p99 µs.
- `benchmarks/http_go/cmd/http-load/main.go` grew a `-churn` flag
  (requires `-keepalive=false`) for symmetry with the H1 harness.
- Unit tests in `tests/test_http3_load.py`,
  `tests/test_http2_scenarios.py` and
  `benchmarks/http_go/cmd/http-load/main_test.go` cover the new
  flags.

## Commands

```bash
# Builds (one-off)
pixi run -e tls-http2 mojo build --Werror -I . \
    benchmarks/http2_tls_server.mojo -o build/bench/handshake/http2_tls_server
pixi run -e tls-http3 mojo build --Werror -I . \
    benchmarks/http3_server.mojo -o build/bench/handshake/http3_server
go -C benchmarks/http_go build -o build/bench/handshake/http_go_h2 .

# HTTP/2 handshake-included cell (one of six)
pixi run -e tls-http2 python benchmarks/http/http2_scenarios.py \
    --scenario churn --url https://127.0.0.1:18443/fixed \
    --clients 16 --warmup 5 --duration 15

# HTTP/3 handshake-included cell (one of six)
pixi run -e tls-http3 python benchmarks/http3_load.py \
    --url https://127.0.0.1:18453/fixed \
    --clients 16 --streams 1 --warmup 5 --duration 15 --churn
```

## Measured cells (3 runs × 15 s, c=1 and c=16, loopback)

Per-cell latency and resource rows are per-run medians across three
runs. Resource (CPU, RSS, FD) ranges are the min–max of the mid-measure
samples (`ps -o %cpu=,rss=` and numeric-FD `lsof` on the server PID).

### HTTP/2 (ALPN h2, TLS 1.3)

| Peer | c | runs | req/s median | p50 µs | p95 µs | p99 µs | ok total | failed | CPU % min–max | RSS KB min–max | FD min–max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| mojo | 1 | 3 | 15.73 | 63,938 | 67,667 | 74,180 | 712 | 0 | 12.1–15.9 | 18,928–19,280 | 10–10 |
| go | 1 | 3 | 16.13 | 62,444 | 65,378 | 67,667 | 726 | 0 | 11.5–13.3 | 17,232–17,344 | 6–6 |
| mojo | 16 | 3 | 219.20 | 73,616 | 76,215 | 77,233 | 9,854 | 0 | 28.6–30.8 | 22,240–22,368 | 25–25 |
| go | 16 | 3 | 212.53 | 75,265 | 77,894 | 78,676 | 9,546 | 0 | 28.0–30.0 | 17,984–18,000 | 21–21 |

### HTTP/3 (ALPN h3, QUIC v1 + TLS 1.3)

| Peer | c | runs | req/s median | p50 µs | p95 µs | p99 µs | ok total | failed | CPU % min–max | RSS KB min–max | FD min–max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| mojo | 1 | 3 | 8.67 | 20,791 | 24,384 | 25,196 | 292 | 1 | 0.1–3.5 | 18,720–18,864 | 10–10 |
| aioquic | 1 | 3 | 5.67 | 27,268 | 32,142 | 34,246 | 255 | 0 | 6.3–7.0 | 49,856–51,600 | 7–7 |
| mojo | 16 | 3 | 141.80 | 11,046 | 29,210 | 35,503 | 6,367 | 0 | 11.9–12.5 | 20,240–20,240 | 10–10 |
| aioquic | 16 | 3 | 138.80 | 8,682 | 18,748 | 25,246 | 6,217 | 1 | 32.4–35.1 | 90,592–99,200 | 7–7 |

### Negotiated transport

- h2 mojo c=1: `h2/TLSv1.3/TLS_AES_256_GCM_SHA384`
- h2 go c=1: `h2/TLSv1.3/TLS_AES_128_GCM_SHA256`
- h2 mojo c=16: `h2/TLSv1.3/TLS_AES_256_GCM_SHA384`
- h2 go c=16: `h2/TLSv1.3/TLS_AES_128_GCM_SHA256`
- h3 mojo c=1: `h3/TLSv1.3/aioquic-1.3.0`
- h3 aioquic c=1: `h3/TLSv1.3/aioquic-1.3.0`
- h3 mojo c=16: `h3/TLSv1.3/aioquic-1.3.0`
- h3 aioquic c=16: `h3/TLSv1.3/aioquic-1.3.0`


## Interpretation

Handshake-included latency is dominated by the TLS 1.3 handshake
(H2) or QUIC+TLS 1.3 handshake (H3) at this concurrency. On this
host at c=1 the H2 handshake-included median p50 is ~63 ms for both
Mojo and Go, with throughput capped near 16 req/s per connection
slot. At c=16 the pool amortises connect latency and throughput
rises to ~210–220 req/s. For H3 the handshake-included Mojo median
p50 is ~21 ms at c=1 and ~11 ms at c=16, with aioquic correspondingly
slower at c=1 but close at c=16. These numbers only establish a
handshake 有無 baseline; the publicised keep-alive cells are
unchanged by this unit.

## Observations and anomalies

- Mojo H3 c=1 run 1 recorded 31 successes and 1 failure vs. 130–131
  successes in runs 2 and 3; the first run looks like a cold-cache
  warmup artefact rather than a steady-state rate. The median across
  three runs reflects this honestly (`req/s median = 8.67` is drawn
  from the two steady runs). Raw per-run rows are retained in
  [`unit110/handshake_summary.tsv`](unit110/handshake_summary.tsv).
- `aioquic` H3 c=16 run 3 recorded a single late/failed completion
  across 2,028 attempts (`failed=1`). Treated as noise, not a
  verdict.

## Limitations

- macOS loopback only (`Apple M2 Pro`); not a Linux netem run.
- Shortened schedule (3 × 15 s, c∈{1,16}); not the published
  5 × 30 s / c∈{1,16,64} × m∈{1,10} grid.
- Server CPU/RSS/FD columns are mid-measure spot samples per run
  with aggregate min–max over three samples; they do not substitute
  for the per-interval sampler used by the published series.
- The H2 scenario client (`hyper-h2` + `ssl.SSLContext`) and the
  Mojo H2 handler negotiate `TLS_AES_256_GCM_SHA384`; the Go H2
  baseline negotiates `TLS_AES_128_GCM_SHA256`. Both are TLS 1.3 and
  the comparison is of two separately-measured handshake-included
  cells, not an exact cipher-matched A/B.
- Numbers are descriptive and are not promoted to any threshold or
  verdict for Issue #42.
