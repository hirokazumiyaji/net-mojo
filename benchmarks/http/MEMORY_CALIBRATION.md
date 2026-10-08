# QUIC per-connection memory calibration

Issue #42 Phase 10 gap: replace the documented 256 KiB per-connection soft
estimate with a measured number.

## Methodology

`benchmarks/http/quic_memory_calibration.py` opens N QUIC+H3 connections via
aioquic (`==1.3.0`) against a running Mojo H3 server
(`benchmarks/http3_server.mojo` built release), measures the server RSS at
four points, then closes the connections. The script samples RSS via
`ps -o rss=`. Each run starts a freshly launched server so the baseline is
clean. The server listens on UDP `127.0.0.1:18453` with the default
`ServerConfig.default()` (`max_connections=10,000`,
`quic_max_transport_memory_bytes=2,621,440,000`).

Each sample:

- `before`: idle server before client dial.
- `after_handshake`: after N connections completed `wait_connected()`.
- `after_idle_hold`: 3 s later, with no application traffic.
- `after_one_request`: after one `GET /fixed` on each connection.
- `after_close`: after client teardown and a 0.5 s settle.

Per-connection delta uses `after_* − before` divided by N.

## Host and toolchain

| Item | Value |
| --- | --- |
| Host | Apple M2 Pro, macOS 27.0.1 (Darwin 27.0.0), arm64 |
| Mojo | `1.1.0 (8189361e)` |
| QUIC provider | quiche `=0.29.3` (`net/quic/provider/Cargo.toml`, BoringSSL) |
| H3 baseline | aioquic `1.3.0` as client |
| Repo SHA | `7f80f55e4f70f7468bd0a077d29b057bfd77d65e` (origin/main at measurement time) |
| H3 server binary SHA256 | `8858bc4a15e193b5853c9c5c2ce0f1f6728c0b2be57ea461018092ba0d34a824` |
| quiche provider SHA256 | `da9022facc3b265a9d557de935d0eae1f09bd317d3d7c70c53d855415cabe331` |
| TLS shim SHA256 | `32580bd75ca01e569f935f39d5d9c0bed8d110456445dba91344314c2de6aed7` |

## Results

Each row is one calibration run with a fresh server. `handshake` is
`(after_handshake − before) / N`; `post_one_request` includes one
GET `/fixed` per connection.

| N | RSS before (B) | RSS after handshake (B) | RSS after one GET (B) | per-conn handshake (B) | per-conn post-GET (B) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1    | 17,186,816 | 18,563,072 | 18,563,072 | 1,376,256 | 1,376,256 |
| 100  | 17,170,432 | 25,100,288 | 25,542,656 | 79,299     | 83,722    |
| 500  | 17,137,664 | 58,867,712 | 60,669,952 | 83,460     | 87,065    |
| 800  | 17,252,352 | 69,877,760 | 72,712,192 | 65,782     | 69,325    |
| 1000 | — | — | — | — | — (client timeout, see below) |

Raw JSON for each run is retained under `workspace/unit109/mem_n*.json`;
committed per-run summaries ship in `benchmarks/http/MEMORY_CALIBRATION.tables.json`.

### N=1000 attempt

Two separate N=1000 attempts failed in the aioquic client with
`asyncio.TimeoutError` while opening connections (server was alive, no
server-side close observed). Server RSS at the time of the failed attempt
rose to roughly 44 MiB with ~1,000 UDP sockets briefly held, consistent with
the handshake dominating client-side scheduling at that scale. The N=800
run demonstrates admission continues to work; the N=1000 result is deferred.

## Comparison with the documented soft estimate

`ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION` in
`net/quic/provider/src/lib.rs` is `256 * 1024 = 262,144 B`. The measured
per-connection RSS delta for N=100, 500 and 800 is in the range
~66 KiB to ~87 KiB after handshake, and ~69 KiB to ~87 KiB after one GET.
Treating the three multi-connection points as the measured population,
observed per-connection RSS is on the order of 65–90 KiB — about one third
of the 256 KiB soft estimate.

### Decision on the constant

The 256 KiB constant is retained as the soft admission estimate. The
measurement here captures idle quiche heap plus one small request; it does
not capture retransmission queues, large in-flight sends, dynamic QPACK
tables under load, or peak-handshake-concurrency bursts, all of which the
soft estimate is intended to accommodate. The design document (see
`docs/design/quic-transport.md`, "connection credit" section) also makes
clear that the admission charge is an operator-tunable safety margin
rather than a tight RSS cap. Shrinking it to the measured idle floor
would reduce headroom without a complementary peak measurement.

The measurement remains recorded for future tuning: a tighter default
(e.g. 128 KiB) would still cover the observed idle+GET footprint by ~1.5×
and double the admissible connection count under the current default
`quic_max_transport_memory_bytes` of 2,621,440,000. That change is left
for a dedicated calibration pass that also measures under in-flight load.

## Caveats

- Measurement is on macOS; `ps rss` reports resident set size including
  shared pages, so values are an upper bound of exclusive quiche heap.
- The baseline (idle server before any client) includes Mojo runtime,
  TLS shim and quiche library pages that are amortized across N. The
  per-connection figure therefore drops as N grows, consistent with the
  observed 79 → 83 → 66 KiB sequence at N=100/500/800.
- All runs are on a single host (loopback). This does not probe behaviour
  under packet loss or over a real NIC.
- N=1000 could not be opened via aioquic in a single serial loop within
  the configured timeouts; a batched or multi-process client is required
  for that scale.
