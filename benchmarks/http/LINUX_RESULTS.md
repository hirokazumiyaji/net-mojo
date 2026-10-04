# Linux packet-loss validation (2026-10-04)

These single-run measurements validate real kernel delay/loss and successful
request completion. They do not complete the five-repeat performance matrix,
fixed-arrival latency, resource profiling or 30-minute soak requirements.
Follow [LINUX_NETWORK.md](LINUX_NETWORK.md) to reproduce the isolated setup.

## Sources and environment

- HTTP/2 server: repository `43938a8` (Mojo and Go).
- HTTP/3 server: `349a1f6`, which closes the transport send half on reset.
  Later cancellation-memory, pacing and queue changes are not measured here.
- Harness: `2f7d647`; optimized binaries, logging redirected outside loaders.
- Local Docker Linux VM: `7.0.14-linuxkit`, aarch64, on Apple M2 Pro.
  Container limited to CPU IDs 0–2 and 2 GiB; server pinned to CPU 0 and
  loader to CPUs 1–2. Go uses `GOMAXPROCS=1`.
- Mojo 1.1.0; Go 1.26.4 linux/arm64; h2load nghttp2 1.59.0;
  aioquic 1.3.0; OpenSSL 3.6.4 for the Mojo TLS shim. Frozen Pixi
  environments; system GCC 13.3 for linking.
- HTTP/2: negotiated ALPN `h2`, TLS 1.3, forced
  `TLS_AES_128_GCM_SHA256` on both servers.
- HTTP/3: both servers negotiate ALPN `h3`, QUIC v1 and
  `AES_256_GCM_SHA384` with the same aioquic client defaults. Cipher metadata
  was checked in a separate handshake after the load runs.
- The container's bridge network was disconnected before the trials. The
  wrapper checked that only loopback was active; host networking was unchanged.

All duration runs use `GET /fixed` (64 B), 16 connections × 10 streams,
10 seconds warmup and 30 seconds measurement. The qdisc adds 10 ms delay and
1% random loss **in each direction**, giving nominal 20 ms RTT; this is not
a statement that the effective round-trip loss rate is 1%.

## Completed requests and latency

| Server | Successful | Failed / errors / timeouts | req/s | p50 µs | p95 µs | p99 µs |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Mojo HTTP/2 | 166,091 | 0 / 0 / 0 | 5,536.37 | 23,019 | 52,867 | 68,161 |
| Go HTTP/2 | 110,349 | 0 / 0 / 0 | 3,678.30 | 43,092 | 56,546 | 266,295 |
| Mojo HTTP/3 | 205,954 | 0 failed | 6,865.133 | 21,586 | 28,834 | 47,261 |
| aioquic HTTP/3 | 188,416 | 0 failed | 6,280.533 | 24,312 | 29,756 | 52,395 |

HTTP/2 percentiles are sorted h2load request-log durations, using index
`floor((n-1)*q)`. All Mojo HTTP/2 log rows have status 200. The Go duration
run has 110,303 status-200 rows and 46 status-0 rows while h2load's summary
counts every request as successful. In nghttp2 1.59.0, headers received during
warmup set the success flag without storing the log status; requests finishing
after the warmup boundary can therefore log 0. See the upstream
[header handling](https://github.com/nghttp2/nghttp2/blob/v1.59.0/src/h2load.cc#L919-L932).
The percentiles above include those successful boundary requests.

A separate Go HTTP/2 trial used 100,000 requests without a warmup boundary:
all 100,000 log rows have status 200, with zero failures/errors/timeouts,
3,399.39 req/s over 29.42 seconds and p50/p95/p99 of
43,418/55,982/269,510 µs. This cross-check is not substituted for the duration
procedure. The HTTP/3 loader validates status and exact response body on every
successful request; successful counts equal latency-sample counts.

## Kernel evidence and cleanup

| Trial | qdisc packets | qdisc drops | qdisc after cleanup |
| --- | ---: | ---: | --- |
| Mojo HTTP/2 | 310,621 | 3,147 | noqueue |
| Go HTTP/2 duration | 258,518 | 2,596 | noqueue |
| Go HTTP/2 100,000 requests | 170,252 | 1,756 | noqueue |
| Mojo HTTP/3 | 1,043,214 | 10,532 | noqueue |
| aioquic HTTP/3 | 1,091,316 | 10,918 | noqueue |

Every trial recorded its configured netem qdisc, packet/drop counters and
cleanup state. The Mojo HTTP/2 trial increased the namespace's
`TcpRetransSegs` from 0 to 2,675, independently confirming TCP retransmission.
Six Linux harness integration tests also passed: measured UDP delay, real
loss, failed-command cleanup, existing-qdisc preservation, refusal of an
active external interface, and child-process/qdisc cleanup on SIGTERM.

Raw outputs and request logs were retained locally under
`workspace/issue42-verification/`, with qdisc JSON under
`linux-netem/netem/`. Reproduction writes fresh artifacts under
`build/bench/netem/`; these generated files are not committed.

These observations establish packet recovery for the tested workload. They
do not establish the Issue's relative-performance targets: each cell has one
run, CPU/RSS/fd sampling was absent, and the final combined implementation
still needs independent connection/stream sweeps and profiling.
