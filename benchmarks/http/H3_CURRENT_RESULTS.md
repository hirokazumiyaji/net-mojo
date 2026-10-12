# Current HTTP/3 multiplexing results

Measured 2026-10-12 from repository source `5f4427989f1fa0e525cdb79407f3bec5c0be9051` on the LinuxKit aarch64 Docker VM. The Mojo server binary SHA256 is `a8b8ce1026dddf3a9c2bc04b24aaf43eb473faecc2181953d1e1c0f24032f325`; the runtime was Mojo 1.1.0, Python 3.12.3 and aioquic 1.3.0. The current multiplex harness was run from the working tree (SHA256 `a6c8bd439527f811e6c56855192b8c0c4fe37cd5a00bfacccf09b9dd09c27246`).

Both endpoints served `GET /fixed` with the same 64-byte body. An aioquic 1.3.0 HTTP/3 server is the independent baseline. The client negotiated HTTP/3 directly; TLS/QUIC setup was outside the measured request window. Each cell used 10 s warmup, 30 s measurement, five runs, and alternating baseline/Mojo order. Server processes were pinned to CPU 0 and the client to CPUs 1–2 in a three-CPU, 2 GiB container. Both servers remained resident on CPU 0 during the matrix. Results are loopback measurements, not bare-metal or production-network predictions.

The table reports the median of each role's five per-run values. Ratio columns are ratios of those displayed medians; latency is the median of per-run p99 values. Each run returned exit code 0 with zero failed requests. Exact per-run values are in [the raw table](H3_CURRENT_RESULTS.tables.tsv).

| Connections × streams | aioquic req/s | Mojo req/s | Throughput ratio | aioquic p99 (µs) | Mojo p99 (µs) | p99 ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 × 1 | 4,290.3 | 5,982.4 | 1.394 | 309 | 234 | 0.757 |
| 1 × 10 | 8,406.5 | 8,282.3 | 0.985 | 1,466 | 1,649 | 1.125 |
| 16 × 1 | 5,904.2 | 7,848.9 | 1.329 | 3,435 | 2,188 | 0.637 |
| 16 × 10 | 6,781.6 | 7,022.7 | 1.036 | 73,772 | 25,640 | 0.348 |
| 64 × 1 | 6,239.1 | 9,886.7 | 1.585 | 20,465 | 6,363 | 0.311 |
| 64 × 10 | 5,984.4 | 8,718.8 | 1.457 | 340,172 | 87,604 | 0.258 |

Using the project's 0.90 throughput and 1.2 p99 ratios as descriptive reference guardrails, all six HTTP/3 cells are within both. The 1 × 10 cell is the narrowest throughput result: Mojo measured 98.5% of aioquic throughput and 1.125× its p99. These HTTP/1-origin guardrails were not a separately pre-registered HTTP/3 target; the table is a reproducible comparative result, not a claim that HTTP/3 has its own declared acceptance threshold.

## Slow stream, cancel and client-side loss

Five repetitions per implementation passed each scenario. Slow upload kept the target request in progress while all eight sibling requests completed and validated their bodies. Cancel reset an in-flight request while eight siblings were outstanding; every sibling and the post-reset request passed. The 30 s loss workload discarded outbound client QUIC datagrams at a configured 5% rate and reported zero failed requests. This client-side impairment is distinct from the kernel packet loss run below. The exact output records, including all scenario counters and exit codes, are in [the special-scenario log](H3_CURRENT_SPECIAL.log).

The harness also attempted its sudo-based kernel loss case, which reported `skip: sudo -n unavailable` in this container. Kernel loss and RTT were instead measured using the repository's isolated Linux netem wrapper.

## RTT and kernel packet loss

The full 16 × 10 cell was repeated five times per implementation under 10 ms delay and 1% random loss in each direction (nominal 20 ms RTT). Mojo measured 7,581.5 req/s and 43,595 µs p99; aioquic measured 6,914.5 req/s and 47,477 µs p99. All ten runs passed with zero request failures. The throughput and p99 ratios were 1.096 and 0.918. Per-run data is in [the netem table](H3_CURRENT_NETEM.tables.tsv); qdisc configuration and counters are in [the netem evidence](H3_CURRENT_NETEM.json).

The wrapper observed 113,367 qdisc drops among 11,227,351 packets over the whole workload; this aggregate includes setup and teardown traffic and does not estimate the workload's realized loss rate. It recorded `noqueue` before setup and after cleanup, with no other active network interface in the container.

## Resource samples and limits

The harness recorded one process snapshot per run around the middle of the measurement window. RSS and open FD values are snapshots, not peaks. Its CPU percentage is the process-lifetime average reported by `ps`, not an interval utilization measurement; it is not used to claim CPU efficiency. The container is a Linux VM, the two servers shared CPU 0, and the loopback delay/loss profile does not model a particular external network. These conditions can affect measured throughput and latency, so the results describe this setup and should not be generalized to other hosts or networks. Request success and failure counters are the load generator's observed outcomes for these runs.

The 5% client-datagram-drop, slow, and cancel scenarios passed five out of five for both implementations. The netem matrix passed five out of five pairs. No H3-specific acceptance threshold had been recorded before this measurement; the comparative data and its guardrail interpretation are now recorded here. Before any future H3 optimization benchmark, record an H3-specific target before collecting results.
