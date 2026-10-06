# Current matched H2 comparison — TCP keepalive OFF

The current numerical comparison and recorded source/tool/binary/native provenance are available in [H2_RESULTS.tables.json](H2_RESULTS.tables.json).

All 90 trials were valid: 60 ordinary, 10 netem and 20 slow/cancel. Each of the seven ordinary/netem comparisons has five alternating Go/Mojo pairs and passes the original throughput ratio ≥0.90 and p99 ratio ≤1.2 conditions. All 20 special wire scenarios passed with 160 timed siblings; their batch rate and p99 ratios are descriptive, without an added numerical gate.

## Source, policy and execution conditions

Go uses clean local benchmark policy 93 (`9ebb9ee120e979cd305ac9109ff276754ee593b7`), with accepted-socket TCP SO_KEEPALIVE OFF and TCP_NODELAY enabled. HTTP reuse, handler/framing/status/body checks and deadlines remain unchanged. Mojo uses the frozen runtime 87 H2 binary with the actual qualified TLS C91 library alias and unchanged HPACK library. The scenario client is the separately qualified revision 92 with TCP_NODELAY; its sibling timing derives from revision 88. The Go common-loader policy does not assert that all independent H2 client sockets have TCP keepalive disabled.

The environment is the owned Linux arm64 container, CPUs 0, 1, 2 and 2 GiB, with disconnected bridge and unchanged capabilities/constraints. Server CPU 0 is separate from loader/collector CPUs 1, 2; Go runs with `GOMAXPROCS=1`. Live soft/hard FD limits are 1,048,576. The Go baseline idle timeout is 3,600 s. Source, binaries, tools, native aliases, actual mappings, constraints and owned cleanup were qualified before/after by independent review; the original whole-platform evidence retains runtime 87 scope.

| Provenance | Recorded value |
| --- | --- |
| Mojo compiler | 1.1.0 (8189361e), original optimized runtime 87 H2 build |
| Go toolchain | 1.26.4, current benchmark policy 93 |
| Ordinary/netem loader | Pinned h2load 1.59, one worker, ALPN h2, TLS 1.3, TLS_AES_128_GCM_SHA256 |
| Observed resource-window span (UTC) | 2026-10-06T05:06:49.340062+00:00 to 2026-10-06T06:10:51.590189+00:00 |
| Mojo H2 binary SHA256 | `2b58745b0b8d38931899e29a2995b72191803540c5757235767f49130aada818` |
| Go baseline SHA256 | `b6ed0f7905d1c3e696e4e49f118c40ee4acdc03d480fe229eb881e4beeea67cb` |
| Actual TLS C91 library SHA256 | `99573298f0a98dd9ec2d7c26fcdc62e1b9dece2f5afbb8458bcc1f6a434cec0e` |
| HPACK library SHA256 | `a2f74fd6e6d4fa7c7878fa314caf91a66a8de055c6e2275f2daf90d1ca7a49a7` |
| Scenario 92 source SHA256 | `cd56b0cb134d35e3a1df5068902fff035149737114740efa9adc1dd818658967` |

Each ordinary/netem trial measures fixed 64 B responses with the original 10 s warmup and 30 s main duration. Concurrency is 1/16/64 connections ×1/10 concurrent streams; odd pairs run Go then Mojo, even pairs Mojo then Go. Independent setup clients validate actual 64 B content, status, h2 ALPN and TLS/cipher; h2load DATA counters alone do not establish per-response content. Independent qualification retains the original eight-request baseline smoke and both handler/source/body premises.

## Throughput and original numerical outcomes

Per-role rates are medians of five trial values. Paired ratios are medians of the five within-pair Mojo/Go ratios, not ratios of the displayed role medians. Every row has 5/5 valid pairs; rounded display values retain full precision in the machine table.

| Cell (connections×streams) | Go req/s | Mojo req/s | Paired throughput ratio | Paired p99 ratio | Original conditions |
| --- | ---: | ---: | ---: | ---: | --- |
| 1×1 | 18,010.97 | 20,397.97 | 1.1330 | 0.8476 | Both pass |
| 1×10 | 47,460.10 | 93,459.23 | 1.9672 | 0.3499 | Both pass |
| 16×1 | 56,565.60 | 92,287.57 | 1.6118 | 0.5241 | Both pass |
| 16×10 | 45,785.57 | 96,758.90 | 2.1861 | 0.3772 | Both pass |
| 64×1 | 52,091.47 | 95,488.47 | 1.8303 | 0.4954 | Both pass |
| 64×10 | 46,658.17 | 91,421.80 | 2.0081 | 0.2703 | Both pass |
| netem 16×10 | 3,825.47 | 5,831.87 | 1.4934 | 0.2591 | Both pass |

## Native reported latency and counter populations

Each latency entry below is the median of the five reported trial percentiles, in milliseconds. No percentile samples are pooled. The reviewed terminal checker reconstructed all 70 ordinary/netem native CSV populations and ranks; this derivative reads its saved JSON rather than rerunning that scan. These native completion-duration percentiles are not H1 fixed-arrival planned-start latency.

| Cell | Go p50 ms | Go p95 ms | Go p99 ms | Mojo p50 ms | Mojo p95 ms | Mojo p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1×1 | 0.053 | 0.063 | 0.078 | 0.046 | 0.054 | 0.068 |
| 1×10 | 0.201 | 0.247 | 0.403 | 0.101 | 0.122 | 0.141 |
| 16×1 | 0.257 | 0.344 | 0.640 | 0.154 | 0.306 | 0.336 |
| 16×10 | 3.492 | 5.080 | 6.069 | 1.621 | 1.867 | 2.459 |
| 64×1 | 1.076 | 2.183 | 2.748 | 0.623 | 0.907 | 1.343 |
| 64×10 | 12.964 | 26.194 | 34.106 | 6.928 | 8.179 | 9.671 |
| netem 16×10 | 41.687 | 53.016 | 264.409 | 21.600 | 50.461 | 64.380 |

The following counts sum the five trials for each role. Native succeeded/log-close, HTTP 2xx and MAIN DATA bytes have distinct boundary membership. The log is emitted for stream closes in `MAIN_DURATION`; headers received during warmup can produce status 0 in that log. Status 0 is retained in the qualified native percentile population: it is neither a generic HTTP error nor independent proof of HTTP 200 for each boundary row. No DATA=64×log-close conservation or per-row body assertion is inferred.

| Cell | Role | Native succeeded/log members | Log status 0 | Native 2xx | MAIN DATA bytes | Failed / errored / timeout |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 1×1 | Go | 2,683,425 | 0 | 2,683,425 | 229,728,384 | 0 / 0 / 0 |
| 1×1 | Mojo | 3,038,079 | 0 | 3,038,079 | 261,411,712 | 0 / 0 / 0 |
| 1×10 | Go | 7,166,917 | 8 | 7,166,914 | 612,500,672 | 0 / 0 / 0 |
| 1×10 | Mojo | 14,104,683 | 0 | 14,104,683 | 1,185,546,496 | 0 / 0 / 0 |
| 16×1 | Go | 8,586,318 | 26 | 8,586,308 | 731,210,048 | 0 / 0 / 0 |
| 16×1 | Mojo | 13,793,452 | 0 | 13,793,452 | 1,166,009,984 | 0 / 0 / 0 |
| 16×10 | Go | 6,747,779 | 478 | 6,747,670 | 575,185,920 | 0 / 0 / 0 |
| 16×10 | Mojo | 14,406,761 | 0 | 14,406,761 | 1,216,771,648 | 0 / 0 / 0 |
| 64×1 | Go | 7,821,153 | 30 | 7,821,155 | 665,492,480 | 0 / 0 / 0 |
| 64×1 | Mojo | 14,273,164 | 0 | 14,273,164 | 1,199,155,328 | 0 / 0 / 0 |
| 64×10 | Go | 6,966,919 | 276 | 6,966,866 | 595,774,656 | 0 / 0 / 0 |
| 64×10 | Mojo | 13,870,571 | 0 | 13,870,571 | 1,165,726,912 | 0 / 0 / 0 |
| netem 16×10 | Go | 578,475 | 307 | 578,394 | 49,725,760 | 0 / 0 / 0 |
| netem 16×10 | Mojo | 871,639 | 0 | 871,639 | 74,345,536 | 0 / 0 / 0 |

The ordinary phase records 113,459,221 native successes and 818 status-0 log rows; netem records 1,450,114 and 307, respectively. All failed/errored/timeout counters are zero. The machine table also retains started/done, complete status histograms and header/total/DATA summaries without treating their different populations as interchangeable.

## Clipped ordinary/netem resources

CPU entries are median (minimum–maximum) percentages across five trials. 100% is one logical CPU. RSS/FD ranges are sampled minima/maxima across those five windows, not lifetime peaks, allocator caps or 30-minute stability. The collector records only running PID/start-token-matched processes; boundaries are excluded without prorating.

The native MAIN markers are flushed stdout observations. Resource clipping uses their observed interior and retains an unmeasured start-activation gap; it is not an exact timer epoch or guaranteed full 30 s coverage. Positive monotonic CPU intervals provide 28.997536888–29.002335430 s of coverage across the 140 ordinary/netem actor windows. Warmup, drain and post-exit values do not substitute for missing window samples.

| Cell | Go server CPU % | Go loader CPU % | Mojo server CPU % | Mojo loader CPU % |
| --- | ---: | ---: | ---: | ---: |
| 1×1 | 62.52 (60.59–63.31) | 38.41 (38.31–39.69) | 43.38 (41.07–44.17) | 38.90 (38.62–39.07) |
| 1×10 | 99.10 (98.24–99.96) | 51.14 (49.93–51.76) | 99.13 (98.62–99.97) | 72.38 (71.86–72.87) |
| 16×1 | 99.35 (99.21–99.73) | 77.80 (76.41–78.32) | 99.24 (98.97–99.59) | 86.45 (84.83–88.21) |
| 16×10 | 99.90 (99.90–99.97) | 48.83 (47.97–52.07) | 99.87 (99.79–99.93) | 85.58 (84.76–86.93) |
| 64×1 | 99.79 (99.69–99.80) | 68.41 (67.83–69.41) | 99.83 (99.80–99.85) | 85.24 (84.51–86.38) |
| 64×10 | 99.96 (99.93–100.00) | 48.21 (47.79–49.97) | 99.97 (99.96–100.00) | 87.89 (85.79–87.93) |
| netem 16×10 | 23.52 (21.65–24.17) | 11.62 (11.41–12.41) | 20.93 (17.07–21.34) | 14.97 (12.24–16.07) |

| Cell | Role | Server sampled RSS MiB | Server sampled FD | Loader sampled RSS MiB | Loader sampled FD |
| --- | --- | ---: | ---: | ---: | ---: |
| 1×1 | Go | 14.52–14.60 | 8 | 24.70–46.66 | 6 |
| 1×1 | Mojo | 22.93–24.73 | 10 | 24.69–48.67 | 6 |
| 1×10 | Go | 14.55–16.64 | 8 | 24.48–64.66 | 6 |
| 1×10 | Mojo | 22.91–24.80 | 10 | 24.48–64.28 | 6 |
| 16×1 | Go | 14.22–16.73 | 23 | 24.26–62.32 | 21 |
| 16×1 | Mojo | 24.05–25.55 | 25 | 24.28–62.36 | 21 |
| 16×10 | Go | 15.51–18.50 | 23 | 24.30–64.70 | 21 |
| 16×10 | Mojo | 24.22–25.35 | 25 | 24.25–64.70 | 21 |
| 64×1 | Go | 16.18–18.81 | 71 | 27.13–65.38 | 69 |
| 64×1 | Mojo | 28.79–30.25 | 73 | 27.04–68.73 | 69 |
| 64×10 | Go | 21.01–26.61 | 71 | 27.20–68.71 | 69 |
| 64×10 | Mojo | 28.99–30.03 | 73 | 27.04–68.55 | 69 |
| netem 16×10 | Go | 14.05–16.78 | 23 | 11.93–30.74 | 21 |
| netem 16×10 | Mojo | 20.67–25.54 | 25 | 10.13–30.50 | 21 |

## Actual owned netem scope

All ten netem trials used the original 16×10 cell with configured 10 ms delay and 1% random loss on loopback traffic in each direction, a nominal 20 ms RTT condition. Owned handle 42 was actually configured and removed/restored to noqueue after each workload. Packet/drop counters below are actual qdisc observations, not a claim that realized RTT or random drop proportion exactly matched the configured values. Host networking/settings were unchanged.

| Trial | Recorded qdisc packets | Recorded qdisc drops | Owned handle removed |
| --- | ---: | ---: | --- |
| h2-16x10-1-baseline | 260,822 | 2,594 | Yes |
| h2-16x10-1-mojo | 329,146 | 3,317 | Yes |
| h2-16x10-2-mojo | 334,744 | 3,374 | Yes |
| h2-16x10-2-baseline | 278,863 | 2,710 | Yes |
| h2-16x10-3-baseline | 280,940 | 2,763 | Yes |
| h2-16x10-3-mojo | 319,022 | 3,264 | Yes |
| h2-16x10-4-mojo | 319,212 | 3,209 | Yes |
| h2-16x10-4-baseline | 268,203 | 2,753 | Yes |
| h2-16x10-5-baseline | 260,582 | 2,736 | Yes |
| h2-16x10-5-mojo | 337,409 | 3,408 | Yes |

## Slow/cancel wire outcomes and batch-only numbers

Both special cells retain five alternating pairs and eight siblings per trial, with the original per-scenario deadlines: 30 s for slow and 300 s for cancel. The launcher deadlines remain unchanged. Slow keeps the target response unfinished during sibling execution, validates all sibling payloads, then validates the eventual target body. Cancel preserves the original flow-block/reset checks, full sibling bodies, post-reset request and full 1 MiB echo reuse. All 20 scenarios passed, with 160 completed timed siblings and no missing/failed sibling. The cumulative reservation-burn estimate exceeds the original 256 MiB budget; it is a functional cleanup/reuse oracle, not a measured leak quantum or process-memory cap.

Only actual sibling dispatch-to-completion batches form the rate/latency population. Handshake, reservation burn, target drain and reuse outside the batch are excluded from its denominator. The eight individual durations are not exported, so these reported batch percentiles/anchors are checked but their ranks are not independently reconstructed. There is no added throughput, p99 or batch-duration gate.

| Scenario | Go batch req/s | Mojo batch req/s | Paired rate ratio | Paired p99 ratio | Wire scope |
| --- | ---: | ---: | ---: | ---: | --- |
| slow | 7,335.53 | 5,821.89 | 0.8223 | 1.2635 | 10/10 trials pass; numerical values descriptive |
| cancel | 43.55 | 23.54 | 0.5324 | 2.0724 | 10/10 trials pass; numerical values descriptive |

| Scenario | Go p50 ms | Go p95 ms | Go p99 ms | Mojo p50 ms | Mojo p95 ms | Mojo p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| slow | 0.816666 | 0.855875 | 0.855875 | 1.038042 | 1.063791 | 1.063791 |
| cancel | 105.497375 | 117.606792 | 117.606792 | 171.188083 | 235.743500 | 235.743500 |

The batch windows span 0.000897709–0.393446792 s. With the original 1 s sampler, all 40 server/loader CPU intervals are unavailable. Only the three cancel trials below contain one RSS/FD sample per actor (six samples total); all other special RSS/FD windows are unavailable. A single sample is not a peak, range over a batch or CPU estimate. Resource availability does not change the independent original wire verdict.

| Cancel trial with one sample/actor | Server RSS MiB | Server FD | Loader RSS MiB | Loader FD |
| --- | ---: | ---: | ---: | ---: |
| h2-cancel-1-mojo | 34.160 | 10 | 50.992 | 4 |
| h2-cancel-3-mojo | 28.820 | 10 | 50.371 | 4 |
| h2-cancel-4-baseline | 24.453 | 8 | 47.309 | 4 |

## Qualification and retained history

Independent review qualified all three terminal packets, including native CSV/counts, recorded identities, actual native maps, source/tool/binary constraints, resources and owned cleanup. Artifact counts are 941 ordinary, 309 netem and 340 special; these are separate phase packets, not a deduplicated global count. All phase host steps and owned groups were terminal/absent.

The v1 offline checker’s whole launch/ready identity comparison failed on the pre-taskset versus ready affinity snapshot; v2’s review map schema was blocked statically. Both records remain preserved. The corrected v3 checker retains exact stable identities, strict ready/resource affinities and the original parser/criteria, and all three phases were subsequently qualified offline. Neither checker correction changed or repeated a timing trial.

All earlier asymmetric-policy H2 results, invalid attempts, earlier cancel-only series and historical source/tool epochs remain unchanged and separate. No rows are spliced into this current 90-trial series. Original H3 results are retained in their existing scope; no H3 replay, cross-epoch p99 transfer, optimization gain, exact kernel cause, soak result, whole-RSS bound or Issue/publication completion claim follows from this document.

## Public tables and reproduction references

The full-precision current numeric derivative is [H2_RESULTS.tables.json](H2_RESULTS.tables.json), SHA256 `163d29f7ea4ac7926dbc9d5127e6b6a5538c9493e1a7f038f8d5ad476ac2c778`. Its combined independent qualification is identified by SHA256 `ff17ecc4a41c13ddcfd63eea7997ca085cc820a36f5581b206c1d729a5ae02f9` and binds the three per-phase summary/checker hashes retained in the public table. Source, binary, native and tool hashes remain recorded with explicit labels; raw execution/ownership/native CSV packets remain retained separately. Provenance hashes identify those records without including them or claiming independent raw reconstruction by this public projection.

For reproduction, use the recorded source/tool versions and the [HTTP procedure](README.md), [isolated delay/loss procedure](LINUX_NETWORK.md), [resource sampler](sample_resources.py), [H2 server](../http2_tls_server.mojo), [Go baseline](../http_go), [H2 benchmark entrypoint](run_http2_bench.sh), [H2 scenario client](http2_scenarios.py) and [sibling timing helper](sibling_metrics.py). Preserve one ordinary h2load worker, 10 s warmup, 30 s main duration, five alternating pairs, fixed 64 B bodies and the seven declared cells; preserve the original slow/cancel wire oracles and distinct per-scenario deadlines. Existing shell entrypoints are not the unpublished qualification supervisor and their shortened/default schedules or sampling cannot substitute for these recorded conditions. Current H2 and historical H3 scopes remain distinct in [MULTIPLEX_RESULTS.md](MULTIPLEX_RESULTS.md).
