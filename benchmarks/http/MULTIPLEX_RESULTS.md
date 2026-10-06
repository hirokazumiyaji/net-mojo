# HTTP/2 and HTTP/3 Linux ARM64 results

The current matched-policy H2 series has 90 qualified trials: 60 ordinary,
10 delay/loss and 20 slow/cancel trials. All seven ordinary/delay-loss
comparisons meet the original throughput and H2 p99 conditions. All twenty
special wire scenarios pass; their numerical comparisons remain report only.

Original H3 evidence remains qualified in its original 90-trial epoch and is
reused without a rerun. The earlier 180-trial mixed H2/H3 series remains
178 VALID and two INVALID, with its separate ten-trial corrected H2 cancel
series retained. These epochs are not pooled, spliced or used to replace an
invalid original. This record does not establish soak completion, current x86
completion or completion of Issue 42.

## Current matched H2 — Go TCP keepalive OFF policy 93

The current baseline uses source 93 (`9ebb9ee120e979cd305ac9109ff276754ee593b7`):
accepted TCP SO_KEEPALIVE is OFF and TCP_NODELAY is enabled. HTTP connection
reuse remains enabled. Mojo uses the unchanged optimized runtime 87 H2 binary,
the actually mapped qualified C91 TLS library, unchanged HPACK and the qualified
scenario 92 client with TCP_NODELAY. This Go policy does not assert that every
independent H2 client socket has TCP keepalive disabled. Both peers retain the
original payloads, parsers, wire oracles, numerical targets and deadlines.

The owned Linux ARM64 container retained CPUs 0–2, 2 GiB, the disconnected bridge
and original capabilities. Server CPU 0 is separate from loader/collector CPUs
1–2, with `GOMAXPROCS=1` for Go and live FD limits 1,048,576. Ordinary/delay-loss
trials retain the 10 s warmup and 30 s main duration, fixed 64 B responses,
one h2load worker, TLS 1.3 and h2 ALPN. Each cell has five alternating pairs.

The full current [H2 results](H2_RESULTS.md) accompany this document, including
source/binary/native hashes, all latency/native-counter/resource tables,
actual netem packet/drop observations, wire details and qualification limits.
The exact saved [machine table](H2_RESULTS.tables.json) retains full precision; this
convergence uses those saved values without rescanning native CSV or making
new measurements.

### Seven original numerical comparisons

Each role rate is the median of five trial values. Each paired ratio is the
median of five within-pair Mojo/Go ratios, not the ratio of displayed role
medians. The original conditions are throughput ratio ≥0.90 and H2 p99 ratio
≤1.2. Native completion-duration percentiles remain distinct from H1 planned
arrival latency; percentiles are not pooled across trials.

| Connections × streams | Go req/s | Mojo req/s | Paired throughput ratio | Paired p99 ratio | Original conditions |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 × 1 | 18,010.97 | 20,397.97 | 1.1330 | 0.8476 | Both pass |
| 1 × 10 | 47,460.10 | 93,459.23 | 1.9672 | 0.3499 | Both pass |
| 16 × 1 | 56,565.60 | 92,287.57 | 1.6118 | 0.5241 | Both pass |
| 16 × 10 | 45,785.57 | 96,758.90 | 2.1861 | 0.3772 | Both pass |
| 64 × 1 | 52,091.47 | 95,488.47 | 1.8303 | 0.4954 | Both pass |
| 64 × 10 | 46,658.17 | 91,421.80 | 2.0081 | 0.2703 | Both pass |
| netem 16 × 10 | 3,825.47 | 5,831.87 | 1.4934 | 0.2591 | Both pass |

### Special wire scenarios and report-only comparisons

Both special cells retain five alternating pairs and eight timed siblings per
trial. Slow retains its 30 s per-scenario deadline; cancel retains its 300 s
per-scenario deadline. Launcher deadlines remain unchanged. Slow validates
the unfinished target, all sibling bodies and eventual target body. Cancel
retains the flow-block/reset, cumulative reservation burn, full sibling
bodies, post-reset request and full 1 MiB echo reuse oracles. All twenty
scenarios pass, with 160 completed timed siblings. The burn estimate is a
functional cleanup/reuse oracle, not a measured memory bound.

Only sibling dispatch-to-completion batches supply the numerical population;
handshake, burn, drain and reuse outside that batch are excluded. Individual
sibling durations are not exported, so the checked reported percentile
anchors do not provide an independently reconstructed rank population. These
comparisons add no numerical gate.

| Scenario | Go batch req/s | Mojo batch req/s | Paired rate ratio | Paired p99 ratio | Scope |
| --- | ---: | ---: | ---: | ---: | --- |
| slow | 7,335.53 | 5,821.89 | 0.8223 | 1.2635 | 10/10 wire trials pass; numbers report only |
| cancel | 43.55 | 23.54 | 0.5324 | 2.0724 | 10/10 wire trials pass; numbers report only |

### Counter, body, resource and delay/loss scope

The ordinary native population contains 113,459,221 successes and
818 status-0 log rows; delay/loss contains 1,450,114 and
307, respectively. All native failed/errored/timeout counters are zero.
Native stream-close/log members, HTTP 2xx counts and MAIN DATA bytes have
different boundary membership. Status 0 is retained in the qualified native
percentile population, without treating it as an HTTP error or proof of a
200 response. No DATA=64×log-close conservation or per-row body assertion is
inferred. Separate setup clients validate body content, status, ALPN and
cipher; aggregate DATA counters do not prove every response body.

All 140 ordinary/delay-loss actor windows have positive measured CPU intervals,
covering 28.997536888–29.002335430 s. Clipping uses the observed interior of native
MAIN stdout markers and retains an unmeasured activation gap. CPU is not
guaranteed full 30 s coverage; 100% is one logical CPU. Sampled RSS/FD ranges
are not continuous peaks, allocator caps or a soak bound. All forty special
CPU intervals are unavailable. Only three cancel trials have one RSS/FD
sample per actor, six samples total; those single observations are not CPU
estimates or lifetime peaks.

All ten delay/loss trials retain the original 16×10 cell with configured
10 ms delay and 1% random loss on loopback in each direction, a nominal 20 ms
RTT condition. Actual owned handle 42 packet/drop observations are in the
companion table; these whole-trial observations do not prove an exact
realized RTT/drop proportion or measurement-only packet count. Each owned
qdisc was removed/restored to noqueue, with host network settings unchanged.

### Current H2 qualification and epoch boundaries

Independent review qualified all three saved terminal packets: 941 ordinary, 309 delay/loss
and 340 special artifact hashes, with native populations/resources, actual
native maps, source/tools/binaries/constraints and owned cleanup checked.
These are separate phase packet counts, not a deduplicated global count.
All phase host steps were terminal and owned groups absent. The combined
independent H2 qualification SHA256
`ff17ecc4a41c13ddcfd63eea7997ca085cc820a36f5581b206c1d729a5ae02f9`
binds the three summary hashes recorded in [H2_RESULTS.tables.json](H2_RESULTS.tables.json). Earlier v1 offline identity-snapshot and v2 static schema
failures remain preserved; the v3 checker qualified the existing timing
trials without repeating or changing them.

Current H2 results do not yield a controlled optimization gain, exact kernel
cause, new H3 p99 verdict or H3 replay. Earlier H2 policy/source epochs and
their original invalid records remain separate below. Original H3 evidence
retains its original tools, policies, numerical scope and proof limitations;
the current H2 changes do not transfer qualification across protocols.

## Historical epochs and retained original H3 evidence

The following preserves the complete qualified historical v5 numerical text
and data, with heading depth changed for nesting and publication-reference
wording adjusted. The historical input SHA256 is
`8cca03b2d31033f8560b3d94d7c199946fa584f916de1b2f6ba48dbf707b2ab3`;
the public record includes its tables and limitations without exporting the
private historical snapshot/review packet.
Historical causal/provenance wording records the conclusions for those
epochs; it does not collapse them into the current matched H2 series.

### HTTP/2 and HTTP/3 Linux ARM64 results — draft

All 180 original trials across eighteen cells are retained: 178 VALID and
two INVALID. The ordinary matrix (120 trials) and real delay/loss phase
(20 trials) are fully qualified; their predeclared throughput targets and
H2 p99 targets were met. Of forty special trials, 38 passed and two Mojo
HTTP/2 cancel originals failed. Its three valid pairs do not qualify the
five-pair cell: H2 cancel cell medians are unavailable and its cause remains
unresolved. No trial was replaced, no failure was reclassified, and no
latency samples were pooled across trials or phases.

A separately corrected HTTP/2 cancel-only series now has ten qualified wire
trials across five alternating pairs. It uses the corrected shared client
TCP_NODELAY policy and independently validated Linux TLS SIGPIPE correction.
Its provenance postcheck failure and supplemental verification are disclosed
below. It does not replace, reclassify or supply missing medians for the
original H2 cancel cell, or rerun the ordinary/delay-loss/H3 matrix.

#### Original trial qualification by cell

| Phase | Cell | Original trials | VALID | INVALID | Complete valid pairs | Qualification / numeric scope |
| --- | --- | --- | --- | --- | --- | --- |
| ordinary | H2 1 × 1 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| ordinary | H2 1 × 10 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| ordinary | H2 16 × 1 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| ordinary | H2 16 × 10 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| ordinary | H2 64 × 1 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| ordinary | H2 64 × 10 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| ordinary | H3 1 × 1 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| ordinary | H3 1 × 10 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| ordinary | H3 16 × 1 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| ordinary | H3 16 × 10 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| ordinary | H3 64 × 1 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| ordinary | H3 64 × 10 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| delay/loss | H2 16 × 10 | 10 | 10 | 0 | 5 / 5 | rate + p99 met |
| delay/loss | H3 16 × 10 | 10 | 10 | 0 | 5 / 5 | rate met; p99 report only |
| special | H2-SLOW | 10 | 10 | 0 | 5 / 5 | batch metrics report only |
| special | H2-CANCEL | 10 | 8 | 2 | 3 / 5 | INCOMPLETE; cell medians unavailable |
| special | H3-SLOW | 10 | 10 | 0 | 5 / 5 | batch metrics report only |
| special | H3-CANCEL | 10 | 10 | 0 | 5 / 5 | batch metrics report only |

#### Sources and fixed conditions

Production runtime source corresponds to commit
`ef57bcdd17a9dc1df8194272c327ddccae86611e`. The separately recorded sibling
observability scripts correspond to
`64ed37228ef053a0816640b935e33b39039c4014`. The Go HTTP/2 baseline uses the
same handlers; the independent HTTP/3 baseline is aioquic 1.3.0. This source
attribution separates benchmark instrumentation from server changes.

| Condition | Recorded conditions and coverage |
| --- | --- |
| Machine | Linux aarch64 Docker VM on Apple M2 Pro; kernel `7.0.14-linuxkit` |
| Resources | 2 GiB; CPU IDs 0–2; server CPU 0, loaders/collector CPUs 1–2 |
| Go | 1.26.4 linux/arm64, `GOMAXPROCS=1` |
| Mojo | 1.1.0 (`8189361e`), AOT `--Werror -O3`; repository native shims |
| HTTP/2 client | h2load nghttp2 1.59.0, one worker; Python 3.14.7 / hyper-h2 4.4.1 for special scenarios |
| HTTP/3 client/baseline | Python 3.14.7 / aioquic 1.3.0 |
| Mojo TLS / QUIC | OpenSSL 3.6.4; pinned quiche 0.29.3 with repository patches |
| HTTP/2 crypto setup | Actual constrained h2load setup: TLS 1.3, ALPN `h2`, `TLS_AES_128_GCM_SHA256` on both servers |
| HTTP/3 crypto setup | Actual one-connection setup: QUIC v1, ALPN `h3`, `AES_256_GCM_SHA384`; pinned QUIC TLS uses TLS 1.3 |
| FD and buffer bounds | Actual live server/loader/collector soft and hard limits: 1,048,576; sampled counts below; unchanged server defaults |
| Ordinary workload | `GET /fixed`, exact 64 `a` bytes, keepalive; 10 s warmup and requested 30 s measurement |
| Repetition | Five pairs per cell, odd baseline-first/even Mojo-first; phases/trials sequential |

The setup suite verifies negotiated protocol/cipher and exact fixed body.
H2 h2load reports crypto for its first connection; it does not report every
connection's handshake duration. The separate default-cipher body probe is
functional evidence and does not replace the constrained AES128 load proof.
H3 setup records one handshake per peer, not every formal connection's
cipher/timing. Delayed H3 handshakes consume its scheduled warmup; no-sample
connections and failures must remain visible. Test certificates are generated
fixture material. These loopback ARM64 measurements do not claim x86_64
emulated performance or unrestricted hardware scaling.

Executable SHA256 inputs, verified before and after all three formal phases:

| Server | SHA256 |
| --- | --- |
| Go | `5a7c9db9a1df7e1da93db09664ea19a960c250a59750dbd8b99191220197ead7` |
| Mojo HTTP/2 | `2b58745b0b8d38931899e29a2995b72191803540c5757235767f49130aada818` |
| Mojo HTTP/3 | `c695af4712081e76b91092cadbb1cf981e87dd21d47fe2d859dfded5ae5c2e86` |

#### Connection/stream matrix

Connections and per-connection streams vary independently. Each row has
five complete baseline/Mojo pairs. Rates and absolute percentiles below are
separate-role medians of five trial values. Ratios are medians of five paired
Mojo/baseline ratios; they need not equal ratios of role medians. The H2
baseline is Go; the H3 baseline is aioquic.

| Cell (five pairs) | Baseline req/s | Mojo req/s | Paired rate ratio | Paired p99 ratio | Recorded targets |
| --- | --- | --- | --- | --- | --- |
| H2 1 × 1 | 17,299.53 | 19,503.70 | 1.1274 | 0.7590 | rate + p99 met |
| H2 1 × 10 | 50,262.57 | 97,212.93 | 1.9294 | 0.3968 | rate + p99 met |
| H2 16 × 1 | 66,064.83 | 105,525.80 | 1.5892 | 0.5132 | rate + p99 met |
| H2 16 × 10 | 49,655.47 | 106,102.43 | 2.1369 | 0.3252 | rate + p99 met |
| H2 64 × 1 | 60,414.53 | 104,435.97 | 1.7279 | 0.5523 | rate + p99 met |
| H2 64 × 10 | 58,638.40 | 106,799.50 | 1.8056 | 0.2641 | rate + p99 met |
| H3 1 × 1 | 4,654.77 | 6,235.03 | 1.3383 | 0.8008 | rate met; p99 report only |
| H3 1 × 10 | 8,916.23 | 8,561.43 | 0.9630 | 1.0397 | rate met; p99 report only |
| H3 16 × 1 | 6,445.23 | 8,456.33 | 1.3144 | 0.6121 | rate met; p99 report only |
| H3 16 × 10 | 8,102.03 | 7,957.07 | 0.9821 | 0.3381 | rate met; p99 report only |
| H3 64 × 1 | 6,262.10 | 10,032.17 | 1.6067 | 0.2963 | rate met; p99 report only |
| H3 64 × 10 | 6,034.43 | 8,671.30 | 1.4370 | 0.2632 | rate met; p99 report only |

Absolute latency and payload medians:

| Cell | Baseline p50 / p95 / p99 (µs) | Mojo p50 / p95 / p99 (µs) | Baseline / Mojo successful payload B/s |
| --- | --- | --- | --- |
| H2 1 × 1 | 56 / 65 / 84 | 47 / 54 / 63 | unavailable |
| H2 1 × 10 | 196 / 217 / 315 | 98 / 115 / 125 | unavailable |
| H2 16 × 1 | 228 / 290 / 574 | 138 / 272 / 292 | unavailable |
| H2 16 × 10 | 3,273 / 4,476 / 5,419 | 1,492 / 1,598 / 1,751 | unavailable |
| H2 64 × 1 | 985 / 1,880 / 2,146 | 594 / 655 / 1,186 | unavailable |
| H2 64 × 10 | 10,560 / 20,768 / 26,911 | 5,940 / 6,309 / 7,054 | unavailable |
| H3 1 × 1 | 158 / 196 / 236 | 136 / 159 / 190 | 297,905.07 / 399,042.13 |
| H3 1 × 10 | 1,073 / 1,160 / 1,338 | 1,143 / 1,195 / 1,398 | 570,638.93 / 547,931.73 |
| H3 16 × 1 | 2,414 / 2,634 / 2,957 | 1,385 / 1,703 / 1,805 | 412,494.93 / 541,205.33 |
| H3 16 × 10 | 13,761 / 45,039 / 64,450 | 19,377 / 20,789 / 21,812 | 518,530.13 / 509,252.27 |
| H3 64 × 1 | 9,555 / 10,779 / 20,456 | 4,636 / 5,746 / 6,096 | 400,774.40 / 642,058.67 |
| H3 64 × 10 | 78,539 / 233,086 / 335,766 | 71,336 / 77,419 / 88,377 | 386,203.73 / 554,963.20 |

Counts below are sums of the five retained trials per role, not a pooled
latency distribution. All loader exits were zero. H2's failed, errored and
timeout counters were each zero in all 60 trials: reported failure rate
`failed / (succeeded + failed)` was zero. H3's printed `failed` counter was
zero in all 60 trials. It covers request/body/status, connection and no-sample
failures; it is not a separately measured handshake count or request-start
denominator. No H2 cutoff count was emitted in these qualified records.

| Cell | Baseline / Mojo successes (= samples) | Baseline / Mojo failures | Baseline / Mojo status-0 rows (H2) or late responses (H3) |
| --- | --- | --- | --- |
| H2 1 × 1 | 2,596,291 / 2,919,883 | 0 / 0 | 0 / 0 |
| H2 1 × 10 | 7,558,620 / 14,575,565 | 0 / 0 | 9 / 0 |
| H2 16 × 1 | 9,905,224 / 15,727,553 | 0 / 0 | 11 / 0 |
| H2 16 × 10 | 7,454,003 / 15,921,912 | 0 / 0 | 209 / 0 |
| H2 64 × 1 | 9,084,728 / 15,432,841 | 0 / 0 | 144 / 0 |
| H2 64 × 10 | 8,822,624 / 16,014,772 | 0 / 0 | 368 / 0 |
| H3 1 × 1 | 698,229 / 934,864 | 0 / 0 | 4 / 4 |
| H3 1 × 10 | 1,326,027 / 1,284,524 | 0 / 0 | 48 / 49 |
| H3 16 × 1 | 967,543 / 1,270,984 | 0 / 0 | 79 / 73 |
| H3 16 × 10 | 1,215,383 / 1,193,170 | 0 / 0 | 790 / 773 |
| H3 64 × 1 | 939,970 / 1,505,351 | 0 / 0 | 318 / 205 |
| H3 64 × 10 | 907,276 / 1,300,169 | 0 / 0 | 3129 / 3096 |

H2 retained 741 status-0 log rows in 19 Go trials. The other retained rows
were status 200; Mojo's H2 status-0 count was zero. These 741 rows remain in
native main-phase completion counts and latency samples. Native headers can
arrive during warmup while stream-close logging belongs to the main phase;
the rows do not independently establish HTTP 200. Exact fixed-handler/body
setup and aggregate success counters were separately verified. H2 successful
payload-byte counts were not separately qualified, so that rate is unavailable:
neither multiplying all completions by 64 nor treating total traffic as payload
supplies a measured body counter.

H3 payload rates are labeled calculations from each exact-body success count
times 64 bytes divided by the recorded 30-s denominator, then median by role.
Late status-200 responses are retained separately and excluded from measured
successes/latencies; they are classified before the fixed-body check and are
not additional verified 64-byte successes. Warmup counts are also separate:

| H3 cell | Baseline / Mojo warmup successes (five-trial totals) |
| --- | --- |
| 1 × 1 | 233,052 / 311,351 |
| 1 × 10 | 434,204 / 428,953 |
| 16 × 1 | 322,166 / 419,212 |
| 16 × 10 | 411,053 / 402,451 |
| 64 × 1 | 310,463 / 498,857 |
| 64 × 10 | 306,156 / 438,005 |

Predeclared targets are HTTP/2 throughput ≥0.90 of Go and p99 ≤1.2 of Go;
HTTP/3 throughput ≥0.90 of aioquic. H3 p99 is reported without an additional
acceptance threshold. These are closed-loop multiplex comparisons, separate
from H1's fixed-arrival unsaturated p99 target. Target misses are recorded
with follow-up evidence; they do not authorize a threshold or feature change.

H2 request-log durations use sorted index `round(q*(n-1))`; all native ranks
were checked against retained request logs. H3 reports its original client
output using the same source convention, rounded to printed microseconds.
Its individual latency array was not exported, so its ranks cannot be
independently recomputed from these retained files. No trial percentiles are pooled. Preserve H2's raw status
histogram, including warmup-header/main-completion status-0 rows, and all
successful/failed/errored/timeout counters. Native main-phase log membership
is not an external request-start filter. Status 0 alone neither proves HTTP
200 nor is a blanket HTTP failure; its boundary population needs the fixed
handler/setup provenance and aggregate completion counts disclosed together.
Use actual data-byte counters where available; distinguish successful payload
from headers, framing and total network traffic. H3 exact-body successes can
support a labeled successful-payload calculation using the reported rate
denominator. No missing byte counter or latency sample is synthesized.

#### Resource windows and coverage

Per trial, retain server and loader CPU/RSS/FD separately, actual FD limits,
snapshot counts, coverage duration and raw window/anchor evidence. CPU is
one-core percent. Record RSS/FD ranges as sampled observations, not allocator
bounds or continuous peaks. CPU durations use collector monotonic clocks;
window selection uses recorded epoch mappings, with their uncertainty.

All 120 trials had 30 in-window snapshots for each server and loader. Their
usable CPU coverage ranged from 28.994684 to 29.004564 s for servers and
28.994660 to 29.004541 s for loaders; these collector-monotonic durations are
not an exact native phase duration. The tables show median trial CPU and the
minimum/maximum RSS and FD snapshots across the five trials of each role.
Resource samples are selected from each trial's own recorded window, not
from startup, warmup or post-measurement drain.

Server observations:

| Cell | Role | Median CPU % | Observed RSS range (MiB) | Observed FD range |
| --- | --- | --- | --- | --- |
| H2 1 × 1 | baseline | 62.34 | 14.55–16.60 | 8–8 |
| H2 1 × 1 | mojo | 43.31 | 23.16–24.78 | 10–10 |
| H2 1 × 10 | baseline | 99.83 | 14.32–16.64 | 8–8 |
| H2 1 × 10 | mojo | 99.90 | 23.17–24.52 | 10–10 |
| H2 16 × 1 | baseline | 99.93 | 14.30–16.73 | 23–23 |
| H2 16 × 1 | mojo | 99.93 | 24.71–25.70 | 25–25 |
| H2 16 × 10 | baseline | 99.97 | 15.75–18.46 | 23–23 |
| H2 16 × 10 | mojo | 99.97 | 24.16–25.35 | 25–25 |
| H2 64 × 1 | baseline | 99.97 | 16.22–18.40 | 71–71 |
| H2 64 × 1 | mojo | 99.97 | 28.70–30.38 | 73–73 |
| H2 64 × 10 | baseline | 99.96 | 21.00–27.09 | 71–71 |
| H2 64 × 10 | mojo | 99.97 | 29.15–30.53 | 73–73 |
| H3 1 × 1 | baseline | 64.79 | 50.43–60.62 | 7–7 |
| H3 1 × 1 | mojo | 21.34 | 20.06–21.34 | 10–10 |
| H3 1 × 10 | baseline | 99.90 | 53.77–73.85 | 7–7 |
| H3 1 × 10 | mojo | 24.14 | 20.02–21.30 | 10–10 |
| H3 16 × 1 | baseline | 99.86 | 53.04–65.97 | 7–7 |
| H3 16 × 1 | mojo | 30.79 | 21.20–22.59 | 10–10 |
| H3 16 × 10 | baseline | 99.93 | 60.07–93.55 | 7–7 |
| H3 16 × 10 | mojo | 29.89 | 21.49–22.51 | 10–10 |
| H3 64 × 1 | baseline | 99.95 | 59.11–71.21 | 7–7 |
| H3 64 × 1 | mojo | 27.31 | 22.95–24.74 | 10–10 |
| H3 64 × 10 | baseline | 99.96 | 60.45–72.44 | 7–7 |
| H3 64 × 10 | mojo | 24.48 | 24.46–25.37 | 10–10 |

Loader observations:

| Cell | Role | Median CPU % | Observed RSS range (MiB) | Observed FD range |
| --- | --- | --- | --- | --- |
| H2 1 × 1 | baseline | 37.79 | 24.70–44.67 | 6–6 |
| H2 1 × 1 | mojo | 38.14 | 24.69–46.67 | 6–6 |
| H2 1 × 10 | baseline | 51.97 | 24.48–64.66 | 6–6 |
| H2 1 × 10 | mojo | 73.24 | 24.47–64.16 | 6–6 |
| H2 16 × 1 | baseline | 77.27 | 24.28–62.32 | 21–21 |
| H2 16 × 1 | mojo | 82.04 | 24.27–62.32 | 21–21 |
| H2 16 × 10 | baseline | 50.34 | 24.30–62.36 | 21–21 |
| H2 16 × 10 | mojo | 82.48 | 24.31–62.36 | 21–21 |
| H2 64 × 1 | baseline | 70.04 | 27.20–65.40 | 69–69 |
| H2 64 × 1 | mojo | 84.04 | 27.05–65.28 | 69–69 |
| H2 64 × 10 | baseline | 49.62 | 27.20–65.58 | 69–69 |
| H2 64 × 10 | mojo | 85.34 | 27.04–65.25 | 69–69 |
| H3 1 × 1 | baseline | 65.93 | 52.61–67.87 | 7–7 |
| H3 1 × 1 | mojo | 82.59 | 53.22–71.97 | 7–7 |
| H3 1 × 10 | baseline | 98.07 | 56.19–87.93 | 7–7 |
| H3 1 × 10 | mojo | 100.00 | 56.21–86.80 | 7–7 |
| H3 16 × 1 | baseline | 96.86 | 55.46–76.04 | 22–22 |
| H3 16 × 1 | mojo | 100.00 | 62.57–103.27 | 22–22 |
| H3 16 × 10 | baseline | 99.96 | 64.84–107.52 | 22–22 |
| H3 16 × 10 | mojo | 100.00 | 64.88–106.53 | 22–22 |
| H3 64 × 1 | baseline | 99.18 | 62.00–82.50 | 70–70 |
| H3 64 × 1 | mojo | 100.00 | 68.02–113.92 | 70–70 |
| H3 64 × 10 | baseline | 100.00 | 69.32–89.37 | 70–70 |
| H3 64 × 10 | mojo | 100.00 | 75.89–119.82 | 70–70 |

All live process limits were independently recorded from `/proc/PID/limits`.
Server startup JSON also reported limits in 90 trials; the Python aioquic
baseline did not emit that event in its 30 trials. Absence of that startup
event is not an absent live limit observation. Both Mojo entrypoints used
unchanged defaults: 10,000 connections and 256 MiB shared application-buffer
budget. H3 additionally retained independent receive request/control/CRYPTO
byte caps of 64/4/16 MiB with 65,536/131,072/131,072 slots, and send caps of
128/8/64 MiB with 524,288 slots each. These logical ownership/admission caps
and the soft transport estimate are not RSS guarantees or measurements of
all TLS/QUIC allocations.

H2 resource captures are clipped to the observed interior between flushed
h2load main-start/main-end stdout markers. Each marker has last-empty-pipe
and received-line brackets. Main-start precedes the native phase/timer
activation, leaving an unknown activation gap. The observed marker span is
not an exact native 30-s window; do not invent start = end − 30 s.
H3 uses recorded epoch endpoints inset on each side by the observed clock
anchor span plus 1 µs printed-endpoint precision. Its requested schedule is
10 s warmup followed by 30 s measurement, anchored before connections are
created. Handshakes therefore consume warmup, rather than extending it;
the rate denominator stays 30 s. Warmup, late completions and drain are separate. Boundary-spanning CPU deltas
are excluded, not prorated. Tiny sibling windows can contain no usable CPU
interval: label CPU unavailable, not zero, and retain full-fixture trajectory
as a separate scope. Collector/profiler overhead is reported separately.

#### Real delay/loss

All 20 original delay/loss trials were retained and qualified: five complete
baseline/Mojo pairs for each protocol at 16 connections × 10 streams.
Both protocols met their predeclared rate target; H2 also met its p99 target.
The table uses separate-role medians and median paired ratios, as in the
ordinary matrix; neither per-trial latency samples nor phase results are pooled.

| Cell (five pairs) | Baseline req/s | Mojo req/s | Paired rate ratio | Paired p99 ratio | Recorded targets |
| --- | --- | --- | --- | --- | --- |
| H2 16 × 10 | 3,771.73 | 5,749.93 | 1.5120 | 0.2501 | rate + p99 met |
| H3 16 × 10 | 6,929.10 | 7,557.23 | 1.0913 | 0.9211 | rate met; p99 report only |

| Cell | Baseline p50 / p95 / p99 (µs) | Mojo p50 / p95 / p99 (µs) | Baseline / Mojo successful payload B/s |
| --- | --- | --- | --- |
| H2 16 × 10 | 42,049 / 54,322 / 266,395 | 21,916 / 50,954 / 66,169 | unavailable |
| H3 16 × 10 | 22,445 / 24,463 / 47,406 | 20,481 / 21,173 / 43,712 | 443,462.40 / 483,662.93 |

| Cell | Baseline / Mojo successes (= samples) | Baseline / Mojo failures | Baseline / Mojo status-0 rows (H2) or late responses (H3) |
| --- | --- | --- | --- |
| H2 16 × 10 | 568,713 / 862,215 | 0 / 0 | 282 / 0 |
| H3 16 × 10 | 1,040,109 / 1,133,511 | 0 / 0 | 798 / 795 |

All 20 loader and namespace-wrapper exits were zero. H2 failed, errored and
timeout counts were zero in every trial; the reported failure rate was zero.
The five Go H2 trials retained 282 status-0 rows (34, 41, 67, 79, 61); Mojo
retained none. These native main-phase completion/log rows stay in the
counts and percentiles and do not independently prove HTTP 200. The same
setup/body provenance and H2 payload-unavailable limitation above apply.
H3 printed failure counts were zero in every trial. Its late responses stay
outside measured success/latency counts and do not imply exact-body validation.
Five-trial H3 warmup-success totals were 361,779 / 376,121
(baseline / Mojo). H3 p99 is reported client output; no individual latency
array was exported for independent rank recomputation.

Each server and loader had 30 selected in-window snapshots per trial.
Collector-monotonic CPU coverage ranged from 28.997130–29.002667 s
for servers and 28.997384–29.002631 s for loaders. H2's selected
window still has an unknown native phase-activation gap. The reported
resource medians and snapshot ranges have the same scope and limitations
as the ordinary observations, including actual FD limits and server budgets.

| Cell | Role | Process | Median CPU % | Observed RSS range (MiB) | Observed FD range |
| --- | --- | --- | --- | --- | --- |
| H2 16 × 10 | baseline | server | 20.14 | 13.93–16.74 | 23–23 |
| H2 16 × 10 | baseline | loader | 8.83 | 10.06–28.30 | 21–21 |
| H2 16 × 10 | mojo | server | 17.48 | 22.06–25.50 | 25–25 |
| H2 16 × 10 | mojo | loader | 11.52 | 13.61–23.96 | 21–21 |
| H3 16 × 10 | baseline | server | 99.89 | 54.68–66.96 | 7–7 |
| H3 16 × 10 | baseline | loader | 93.55 | 59.28–79.25 | 22–22 |
| H3 16 × 10 | mojo | server | 23.14 | 22.02–23.14 | 10–10 |
| H3 16 × 10 | mojo | loader | 98.69 | 64.22–80.19 | 22–22 |

Netem applied 10 ms delay and 1% random loss in each loopback direction:
nominal 20 ms RTT, not a 1% effective round-trip loss claim. Every trial's
recorded qdisc was netem with these settings and had nonzero packet drops.
All twenty trials restored the owned container namespace's initial noqueue qdisc
after the workload; host qdiscs were not modified.

| Cell | Role | Whole-trial packets (five-trial total) | Whole-trial drops (five-trial total) |
| --- | --- | --- | --- |
| H2 16 × 10 | baseline | 1,321,702 | 13,366 |
| H2 16 × 10 | mojo | 1,646,294 | 16,490 |
| H3 16 × 10 | baseline | 5,777,375 | 58,223 |
| H3 16 × 10 | mojo | 5,448,736 | 55,599 |

These configured-to-after-workload qdisc deltas cover the whole trial,
including setup, warmup and drain; they are not measurement-only packet or
drop counters. Actual TCP retransmission deltas are unavailable in these
retained records, and the H3 loader emits no QUIC retransmission counter.
Packet drops alone do not prove ACK/loss recovery. Independent terminal
review qualified all 20 trials, verified the 326 retained artifact
hashes, and confirmed all 82 recorded owned PIDs and 81 process groups absent.
No delay/loss trial was replaced and no host networking change is needed to
interpret these retained observations.

#### Slow-stream and cancellation batches

All forty original trials are retained: 38 VALID/pass and two INVALID,
both Mojo HTTP/2 cancel originals. H2 slow, H3 slow and H3 cancel each have
five complete valid pairs. H2 cancel has three of five; its cell-level
role medians and paired medians are unavailable. The two missing pairs are
not replaced or omitted from qualification. Passing eight siblings in
completed trials does not turn the incomplete H2 cancel cell into a pass.

| Scenario (five original pairs) | Valid pairs | Baseline sibling req/s | Mojo sibling req/s | Paired batch-rate ratio | Paired batch-p99 ratio | Scope |
| --- | --- | --- | --- | --- | --- | --- |
| H2-SLOW | 5 / 5 | 189.0873 | 188.8478 | 0.9805 | 1.0163 | report only; no numeric target |
| H2-CANCEL | 3 / 5 | unavailable | unavailable | unavailable | unavailable | INCOMPLETE; no reduced-series median |
| H3-SLOW | 5 / 5 | 6603.1553 | 4324.3243 | 0.6681 | 1.4812 | report only; no numeric target |
| H3-CANCEL | 5 / 5 | 31.1577 | 38.5853 | 1.2323 | 0.7642 | report only; no numeric target |

These are closed-loop, eight-sibling batches, not 30-s saturated throughput
or population-tail estimates. The dispatch-phase start to last actual
sibling completion supplies each rate denominator; held credit remains in
latency. H2 cancel's recorded sibling phase includes target setup/credit
withholding before sibling dispatch. Handshake, reservation burn and later
reuse/drain do not supply the sibling denominator. Whole-fixture time is
reported separately and must not be substituted for that window. No new
numeric targets apply to these batch ratios.

Wire/payload scope of each successful trial:

| Scenario | Existing oracle and verified sibling payload |
| --- | --- |
| H2 slow | Incomplete 1-MiB upload; eight exact 64-B GET siblings (512 B total) while target stays unfinished; target finishes after release |
| H2 cancel | 274 reservation-burn cycles exceed 256-MiB budget; target and eight 1-MiB echoes flow-blocked across RST; eight exact echo bodies (8 MiB total); full echo and fixed GET reuse |
| H3 slow | Incomplete 256-KiB upload; eight exact 64-B GET siblings (512 B total) before target finish |
| H3 cancel | 257 ACK-confirmed incomplete-upload burn cycles exceed 64-MiB budget; in-flight reset while eight 256-KiB echoes are outstanding; eight exact bodies (2 MiB total); fixed GET reuse |

Payload totals above are calculations from exact-body wire oracles and eight
successful siblings, not an independent byte-counter measurement. H3 slow
cannot withhold QUIC receive credit through aioquic's API; its proof concerns
an unfinished upload, rather than a transport slow reader. Original target,
credit, ACK/burn, reset, reuse, status/body and exit oracles were unchanged.
Special-client cipher negotiation has its own coverage; ordinary h2load's
constrained cipher is not attributed to these clients.

Original per-trial results follow. Valid trials each report eight samples,
eight completions and no missing timing. Their sibling percentiles are the
original client outputs/source convention; individual durations were not
exported for independent rank recomputation. No percentiles or samples are
pooled. An invalid original has unavailable batch counts and timing, not
synthetic zero successes or eight fabricated failures.

| Original trial | Verdict | Sibling OK / fail / missing timing | Sibling window s | Sibling req/s | Reported p50 / p95 / p99 µs | Whole fixture s |
| --- | --- | --- | --- | --- | --- | --- |
| h2-slow-1-baseline | VALID/pass | 8 / 0 / 0 | 0.042568833 | 187.930921 | 42366.833 / 42411.417 / 42411.417 | 0.162468 |
| h2-slow-1-mojo | VALID/pass | 8 / 0 / 0 | 0.042232625 | 189.427013 | 41930.250 / 41964.000 / 41964.000 | 1.087486 |
| h2-slow-2-baseline | VALID/pass | 8 / 0 / 0 | 0.041536375 | 192.602267 | 41295.916 / 41365.042 / 41365.042 | 0.159985 |
| h2-slow-2-mojo | VALID/pass | 8 / 0 / 0 | 0.042362167 | 188.847752 | 41983.209 / 42040.583 / 42040.583 | 1.101488 |
| h2-slow-3-baseline | VALID/pass | 8 / 0 / 0 | 0.042308500 | 189.087299 | 42068.625 / 42116.083 / 42116.083 | 0.161928 |
| h2-slow-3-mojo | VALID/pass | 8 / 0 / 0 | 0.046398458 | 172.419523 | 46036.958 / 46097.291 / 46097.291 | 1.106817 |
| h2-slow-4-baseline | VALID/pass | 8 / 0 / 0 | 0.041848583 | 191.165374 | 41582.584 / 41643.084 / 41643.084 | 0.162830 |
| h2-slow-4-mojo | VALID/pass | 8 / 0 / 0 | 0.042291416 | 189.163683 | 41928.791 / 41999.667 / 41999.667 | 1.088713 |
| h2-slow-5-baseline | VALID/pass | 8 / 0 / 0 | 0.044751291 | 178.765792 | 44483.083 / 44536.666 / 44536.666 | 0.164391 |
| h2-slow-5-mojo | VALID/pass | 8 / 0 / 0 | 0.046564084 | 171.806236 | 46183.709 / 46223.500 / 46223.500 | 1.084851 |
| h2-cancel-1-baseline | VALID/pass | 8 / 0 / 0 | 0.232651500 | 34.386196 | 153845.791 / 167726.333 / 167726.333 | 16.788482 |
| h2-cancel-1-mojo | VALID/pass | 8 / 0 / 0 | 8.932523962 | 0.895604 | 4072472.461 / 6914083.004 / 6914083.004 | 294.544504 |
| h2-cancel-2-baseline | VALID/pass | 8 / 0 / 0 | 0.252157792 | 31.726166 | 160979.416 / 176497.334 / 176497.334 | 17.873605 |
| h2-cancel-2-mojo | INVALID | unavailable | unavailable | unavailable | unavailable | unavailable |
| h2-cancel-3-baseline | VALID/pass | 8 / 0 / 0 | 0.230946792 | 34.640014 | 153480.000 / 166173.750 / 166173.750 | 17.865300 |
| h2-cancel-3-mojo | VALID/pass | 8 / 0 / 0 | 8.674339379 | 0.922260 | 3925605.085 / 6733498.128 / 6733498.128 | 297.525296 |
| h2-cancel-4-baseline | VALID/pass | 8 / 0 / 0 | 0.212952542 | 37.567056 | 138932.917 / 149284.584 / 149284.584 | 17.130302 |
| h2-cancel-4-mojo | VALID/pass | 8 / 0 / 0 | 9.005420504 | 0.888354 | 4048695.419 / 6955500.128 / 6955500.128 | 293.712711 |
| h2-cancel-5-baseline | VALID/pass | 8 / 0 / 0 | 0.218854917 | 36.553897 | 138694.250 / 148204.167 / 148204.167 | 17.202829 |
| h2-cancel-5-mojo | INVALID | unavailable | unavailable | unavailable | unavailable | unavailable |
| h3-slow-1-baseline | VALID/pass | 8 / 0 / 0 | 0.001256584 | 6366.466563 | 660.042 / 857.125 / 857.125 | 0.458305 |
| h3-slow-1-mojo | VALID/pass | 8 / 0 / 0 | 0.001868375 | 4281.795673 | 1077.459 / 1292.625 / 1292.625 | 0.388709 |
| h3-slow-2-baseline | VALID/pass | 8 / 0 / 0 | 0.001197834 | 6678.721755 | 620.833 / 851.167 / 851.167 | 0.404371 |
| h3-slow-2-mojo | VALID/pass | 8 / 0 / 0 | 0.001850000 | 4324.324323 | 1142.500 / 1279.708 / 1279.708 | 0.387575 |
| h3-slow-3-baseline | VALID/pass | 8 / 0 / 0 | 0.001202083 | 6655.114497 | 619.375 / 867.416 / 867.416 | 0.422045 |
| h3-slow-3-mojo | VALID/pass | 8 / 0 / 0 | 0.001799208 | 4446.400863 | 1141.583 / 1262.042 / 1262.042 | 0.385669 |
| h3-slow-4-baseline | VALID/pass | 8 / 0 / 0 | 0.001234916 | 6478.173401 | 639.333 / 899.750 / 899.750 | 0.403375 |
| h3-slow-4-mojo | VALID/pass | 8 / 0 / 0 | 0.001788916 | 4471.981922 | 1128.333 / 1254.541 / 1254.541 | 0.394095 |
| h3-slow-5-baseline | VALID/pass | 8 / 0 / 0 | 0.001211542 | 6603.155320 | 587.916 / 879.750 / 879.750 | 0.471864 |
| h3-slow-5-mojo | VALID/pass | 8 / 0 / 0 | 0.001866042 | 4287.148951 | 1178.084 / 1303.083 / 1303.083 | 0.389027 |
| h3-cancel-1-baseline | VALID/pass | 8 / 0 / 0 | 0.247698083 | 32.297384 | 241982.750 / 243052.000 / 243052.000 | 3.758185 |
| h3-cancel-1-mojo | VALID/pass | 8 / 0 / 0 | 0.206361958 | 38.766835 | 154654.500 / 198264.667 / 198264.667 | 2.930309 |
| h3-cancel-2-baseline | VALID/pass | 8 / 0 / 0 | 0.268792542 | 29.762731 | 262409.542 / 264020.959 / 264020.959 | 3.720282 |
| h3-cancel-2-mojo | VALID/pass | 8 / 0 / 0 | 0.207336041 | 38.584705 | 157420.875 / 195089.709 / 195089.709 | 2.843898 |
| h3-cancel-3-baseline | VALID/pass | 8 / 0 / 0 | 0.257309376 | 31.090977 | 251635.417 / 254325.667 / 254325.667 | 3.763391 |
| h3-cancel-3-mojo | VALID/pass | 8 / 0 / 0 | 0.207332709 | 38.585325 | 154141.125 / 193949.292 / 193949.292 | 2.855548 |
| h3-cancel-4-baseline | VALID/pass | 8 / 0 / 0 | 0.253307500 | 31.582168 | 246870.583 / 248920.833 / 248920.833 | 3.808050 |
| h3-cancel-4-mojo | VALID/pass | 8 / 0 / 0 | 0.205562500 | 38.917604 | 157899.708 / 190230.750 / 190230.750 | 2.852699 |
| h3-cancel-5-baseline | VALID/pass | 8 / 0 / 0 | 0.256758750 | 31.157653 | 250001.333 / 252830.791 / 252830.791 | 3.839559 |
| h3-cancel-5-mojo | VALID/pass | 8 / 0 / 0 | 0.210312292 | 38.038671 | 157584.042 / 202350.167 / 202350.167 | 2.891122 |

The original epoch endpoints and clock anchor evidence are retained separately;
resource selection insets these endpoints by anchor/epoch precision
uncertainty. Printed endpoints below retain their source precision; the
retained qualification data preserves the exact parsed floats and selected ns window.

| Original trial | Sibling start epoch s | Sibling end epoch s | Anchor span µs | Anchor uncertainty µs |
| --- | --- | --- | --- | --- |
| h2-slow-1-baseline | 1791244557.4880998 | 1791244557.5306687 | 0.833 | 0.416 |
| h2-slow-1-mojo | 1791244558.5834947 | 1791244558.6257272 | 0.917 | 0.458 |
| h2-slow-2-baseline | 1791244562.8320708 | 1791244562.8736072 | 0.792 | 0.396 |
| h2-slow-2-mojo | 1791244560.7318711 | 1791244560.7742333 | 1.500 | 0.750 |
| h2-slow-3-baseline | 1791244563.9904852 | 1791244564.0327938 | 1.625 | 0.812 |
| h2-slow-3-mojo | 1791244565.0994928 | 1791244565.1458912 | 1.833 | 0.917 |
| h2-slow-4-baseline | 1791244569.3752155 | 1791244569.4170642 | 1.417 | 0.709 |
| h2-slow-4-mojo | 1791244567.2216809 | 1791244567.2639723 | 1.292 | 0.646 |
| h2-slow-5-baseline | 1791244570.4849699 | 1791244570.5297213 | 1.334 | 0.667 |
| h2-slow-5-mojo | 1791244571.6442542 | 1791244571.6908183 | 1.125 | 0.562 |
| h2-cancel-1-baseline | 1791244590.1643047 | 1791244590.3969562 | 15.208 | 7.604 |
| h2-cancel-1-mojo | 1791244875.3870015 | 1791244884.3195255 | 42.792 | 21.396 |
| h2-cancel-2-baseline | 1791245204.6915379 | 1791245204.9436955 | 29.833 | 14.917 |
| h2-cancel-2-mojo | unavailable | unavailable | unavailable | unavailable |
| h2-cancel-3-baseline | 1791245222.8582222 | 1791245223.089169 | 10.625 | 5.313 |
| h2-cancel-3-mojo | 1791245511.3124368 | 1791245519.986776 | 50.916 | 25.458 |
| h2-cancel-4-baseline | 1791245832.5380418 | 1791245832.7509944 | 34.750 | 17.375 |
| h2-cancel-4-mojo | 1791245805.2097595 | 1791245814.21518 | 12.500 | 6.250 |
| h2-cancel-5-baseline | 1791245850.7227154 | 1791245850.9415703 | 6.625 | 3.312 |
| h2-cancel-5-mojo | unavailable | unavailable | unavailable | unavailable |
| h3-slow-1-baseline | 1791246153.40341 | 1791246153.4046664 | 0.625 | 0.313 |
| h3-slow-1-mojo | 1791246154.5506334 | 1791246154.552502 | 0.750 | 0.375 |
| h3-slow-2-baseline | 1791246156.8996673 | 1791246156.900865 | 0.583 | 0.292 |
| h3-slow-2-mojo | 1791246155.6615355 | 1791246155.6633854 | 0.625 | 0.312 |
| h3-slow-3-baseline | 1791246158.1195052 | 1791246158.1207073 | 0.583 | 0.292 |
| h3-slow-3-mojo | 1791246159.2862017 | 1791246159.2880008 | 0.833 | 0.416 |
| h3-slow-4-baseline | 1791246161.6163294 | 1791246161.6175644 | 0.584 | 0.292 |
| h3-slow-4-mojo | 1791246160.3829412 | 1791246160.38473 | 0.584 | 0.292 |
| h3-slow-5-baseline | 1791246162.8280666 | 1791246162.8292782 | 0.625 | 0.313 |
| h3-slow-5-mojo | 1791246163.9829483 | 1791246163.9848144 | 0.667 | 0.334 |
| h3-cancel-1-baseline | 1791246168.642448 | 1791246168.890146 | 0.875 | 0.437 |
| h3-cancel-1-mojo | 1791246172.03254 | 1791246172.238902 | 1.042 | 0.521 |
| h3-cancel-2-baseline | 1791246180.1104715 | 1791246180.379264 | 4.667 | 2.333 |
| h3-cancel-2-mojo | 1791246176.1047873 | 1791246176.3121233 | 0.834 | 0.417 |
| h3-cancel-3-baseline | 1791246184.3737984 | 1791246184.6311078 | 1.166 | 0.583 |
| h3-cancel-3-mojo | 1791246187.7097838 | 1791246187.9171164 | 1.000 | 0.500 |
| h3-cancel-4-baseline | 1791246194.9119093 | 1791246195.165217 | 0.959 | 0.480 |
| h3-cancel-4-mojo | 1791246190.828611 | 1791246191.0341735 | 1.125 | 0.562 |
| h3-cancel-5-baseline | 1791246199.1793733 | 1791246199.436132 | 1.042 | 0.521 |
| h3-cancel-5-mojo | 1791246202.404141 | 1791246202.6144533 | 0.959 | 0.479 |

Sibling resource windows are short. Of the 38 valid originals, 34 had no
in-window server/loader snapshots; their batch CPU, RSS and FD observations
are unavailable. One Go H2 cancel original had one snapshot per process:
RSS/FD were observed but CPU had no usable interval, so CPU is unavailable.
The three valid Mojo H2 cancel originals had nine snapshots per process and
usable monotonic CPU intervals. The table includes only the four originals
with snapshots; all remaining observations stay explicitly unavailable in
the retained per-trial derived data. Both invalid originals lack a qualified
sibling window. Missing CPU is never zero; full-fixture collector trajectories
are a separate scope and cannot fill the sibling window. Boundary-spanning
CPU deltas are excluded, not prorated. Snapshot RSS/FD ranges are observations,
not continuous peaks or allocator bounds; no resource medians pool different
window coverage or ignore unavailable trials.

| Original trial | Process | In-window snapshots | CPU % | CPU coverage s | RSS range MiB | FD range |
| --- | --- | --- | --- | --- | --- | --- |
| h2-cancel-1-mojo | server | 9 | 3.5013 | 7.997135004 | 28.32–34.32 | 10–10 |
| h2-cancel-1-mojo | loader | 9 | 2.0007 | 7.997319587 | 50.38–50.93 | 4–4 |
| h2-cancel-3-mojo | server | 9 | 3.7500 | 7.999967795 | 28.66–34.66 | 10–10 |
| h2-cancel-3-mojo | loader | 9 | 1.6250 | 7.999809420 | 50.80–51.35 | 4–4 |
| h2-cancel-4-mojo | server | 9 | 3.4979 | 8.004774878 | 27.60–33.60 | 10–10 |
| h2-cancel-4-mojo | loader | 9 | 1.4991 | 8.004935129 | 51.41–51.96 | 4–4 |
| h2-cancel-5-baseline | server | 1 | unavailable | 0.000000000 | 24.45–24.45 | 8–8 |
| h2-cancel-5-baseline | loader | 1 | unavailable | 0.000000000 | 48.41–48.41 | 4–4 |

##### Retained original HTTP/2 cancel failures and follow-up

| Original trial | Raw loader stdout | Loader exit | Recorded server exit after cleanup | Sibling metrics |
| --- | --- | --- | --- | --- |
| h2-cancel-2-mojo | `scenario=cancel verdict=fail conn=single error=ScenarioError detail=upload stalled at offset 835584: no WINDOW_UPDATE` | 1 | -13 (SIGPIPE) | unavailable |
| h2-cancel-5-mojo | `scenario=cancel verdict=fail conn=single error=ScenarioError detail=upload stalled at offset 540672: no WINDOW_UPDATE` | 1 | -15 (SIGTERM) | unavailable |

Both errors arise on the driver's original 300-s deadline/no-upload-credit
path. Raw stdout is preserved; parsed `detail=upload` does not replace its
full error text. The missing `sibling_samples` parser error is a consequence
of absent batch output, not a separately successful wire result. The server
exit field is observed after cleanup: it does not establish when SIGPIPE
occurred or that SIGPIPE caused the loader's credit wait. SIGTERM likewise
remains the recorded exit scope. No transport/driver/environment cause is
established or used to reclassify either INVALID trial.

Three Mojo H2 cancel originals passed in 294.544504, 297.525296 and
293.712711 s under the unchanged 300-s ceiling; preserve those individual
passes without promoting the incomplete cell. Static review found short
65,535-B receive windows and repeated body/credit/TLS exchanges as latency
candidates. The known upload credit-return improvement is already present;
client TCP_NODELAY/ACK interaction and copying are unverified candidates.
These observations do not prove a failure cause, change the timeout or oracle,
or add a performance completion gate. Original failed trials remain evidence
for a separately planned cause investigation.

Independent terminal review verified all 395 special artifact hashes and
confirmed all 122 recorded owned PIDs and 121 process groups absent; the
original failures and cleanup records remain retained. All 40 originals ran
with unchanged source, tool/configuration, payload, deadline and schedule.

#### Separate corrected HTTP/2 cancellation series

The later cancel-only series contains exactly ten uninstrumented scenario
trials: five Go/Mojo pairs, odd Go-first and even Mojo-first. Each passes
the unchanged original wire oracle and reports eight successful siblings,
zero sibling failures and zero missing timing. This series is separate from
the original 180 attempts and their two retained INVALID trials. Neither
series is spliced or pooled, and the original H2-CANCEL row remains 3/5.

The shared client source is commit
`694db8271afa7ad72215e275693aed76bef95c34`, parent
`6c8a3ab7cd8ce8ff692486aa773c2a2fe1378404`. Its two-path change sets
TCP_NODELAY=1 after h2 ALPN validation and before the first HTTP/2 frame,
and documents the same policy for both servers. The client file SHA256 is
`cd56b0cb134d35e3a1df5068902fff035149737114740efa9adc1dd818658967`;
sibling metric code is unchanged. The existing frozen Go and Mojo H2
executables above are retained, with Mojo dynamically loading the separately
qualified Linux TLS library SHA256
`99573298f0a98dd9ec2d7c26fcdc62e1b9dece2f5afbb8458bcc1f6a434cec0e`.
All five Mojo trials have an actual library-map check before loader launch.
Original HPACK, tools, configuration and resource constraints are retained;
no new full matrix or provider-performance qualification is implied.

The original 300-s scenario deadline, 274 reservation-burn cycles,
269,353,234-B leak estimate exceeding the 268,435,456-B budget, target
response blocked at 65,535 B before reset, eight siblings blocked before/after RST,
eight exact 1-MiB echo bodies, full echo reuse and fixed-GET reuse all remain
unchanged. The eight-sibling payload total is a calculation from the exact
body oracle, not a separate transport byte counter.

| Corrected trial | Wire result | Siblings OK / fail / missing timing | Sibling window s | Sibling req/s | Reported p50 / p95 / p99 µs | Whole fixture s |
| --- | --- | --- | ---: | ---: | --- | ---: |
| h2-cancel-corrected-1-baseline | VALID/pass | 8 / 0 / 0 | 0.194637333 | 41.102084 | 110356.750 / 122532.291 / 122532.291 | 17.795048 |
| h2-cancel-corrected-1-mojo | VALID/pass | 8 / 0 / 0 | 0.338473875 | 23.635502 | 164021.208 / 227304.958 / 227304.958 | 23.825190 |
| h2-cancel-corrected-2-mojo | VALID/pass | 8 / 0 / 0 | 0.334376292 | 23.925141 | 164249.292 / 227988.042 / 227988.042 | 23.827366 |
| h2-cancel-corrected-2-baseline | VALID/pass | 8 / 0 / 0 | 0.184701458 | 43.313139 | 107937.709 / 119740.958 / 119740.958 | 17.904113 |
| h2-cancel-corrected-3-baseline | VALID/pass | 8 / 0 / 0 | 0.190694250 | 41.951973 | 111708.959 / 124273.666 / 124273.666 | 17.823848 |
| h2-cancel-corrected-3-mojo | VALID/pass | 8 / 0 / 0 | 0.327512000 | 24.426586 | 172574.292 / 233446.375 / 233446.375 | 23.739019 |
| h2-cancel-corrected-4-mojo | VALID/pass | 8 / 0 / 0 | 0.342781709 | 23.338468 | 166111.042 / 230165.000 / 230165.000 | 23.809164 |
| h2-cancel-corrected-4-baseline | VALID/pass | 8 / 0 / 0 | 0.194326709 | 41.167784 | 108858.875 / 121573.959 / 121573.959 | 17.807589 |
| h2-cancel-corrected-5-baseline | VALID/pass | 8 / 0 / 0 | 0.187251167 | 42.723365 | 102679.209 / 115815.959 / 115815.959 | 17.898597 |
| h2-cancel-corrected-5-mojo | VALID/pass | 8 / 0 / 0 | 0.345442542 | 23.158699 | 168529.583 / 232367.083 / 232367.083 | 23.751024 |

Separate-role medians and median paired ratios for only these five corrected
pairs follow. A rate is eight divided by its recorded sibling window;
handshake, burn, reuse and drain do not enter that denominator. Whole-fixture
time remains separate. These tiny batches do not estimate 30-s saturated
throughput or a population latency tail. Client-reported percentiles are
retained; no individual latency array was exported for rank recomputation.

| Corrected role | Median sibling req/s | Median p50 / p95 / p99 µs | Median whole fixture s |
| --- | ---: | --- | ---: |
| Go | 41.9520 | 108858.875 / 121573.959 / 121573.959 | 17.8238 |
| Mojo | 23.6355 | 166111.042 / 230165.000 / 230165.000 | 23.8092 |

The median paired Mojo/Go batch-rate ratio is
**0.5669** and paired batch-p99 ratio is
**1.8932**. These descriptive ratios have no added
numeric target; the ordinary matrix's throughput/p99 gates do not apply to
the corrected cancellation batch. No original-cell reduced-series median is
substituted for either ratio.

All ten sibling resource windows contain zero selected server/loader
snapshots. Their batch CPU, RSS and FD are unavailable, not zero; full-fixture
collector trajectories cannot fill the short sibling windows. Identity,
affinity and actual live FD-limit records are separate from sampled resource
counts. The retained original measurement/anchor clipping convention applies.

##### Terminal provenance postcheck failure

The overall preparation supervisor and its verify-after step both exit 1.
After all ten trials were saved, an alias-only file enumeration rejected the
normal generated `benchmarks/http/__pycache__/sample_resources.cpython-312.pyc`.
Its original assertion traceback remains retained and the expected
verified-after artifact was not produced. The batch is not reported as an
unconditional successful supervisor run.

A separate bounded read-only verifier confirmed exact original source,
tools, binaries, corrected client/native bytes and all five alias targets,
with that cache as the sole extra path. The cache header and code object match
the unchanged sampler compiled at its alias path with optimize=0. Independent
review qualified the ten individual wire trials using this supplemental
provenance, while preserving both exit-1 records. The cache bytes were not
exported for a separate local recomputation; its exact checks are reviewed
independently reviewed verifier evidence. All 200 artifacts of the corrected attempt remain retained;
all 30 registered actor groups and the outer supervisor group are absent.
Loaders/collectors exit 0 and servers receive owned TERM (-15) after completion;
this cleanup does not establish cooperative shutdown.

##### Controlled delay observation and separate TLS correction

A preceding instrumented run with TCP_NODELAY=0 reproduced the 300-s upload
deadline failure, with cumulative credit waits. A one-variable instrumented
TCP_NODELAY=1 control completed the unchanged scenario in 23.5257 s. The
controlled observation supports correcting the client's buffering policy;
queued-byte/timer observations do not establish packet-level Nagle/ACK
causality or a permanently lost WINDOW_UPDATE. These two observations stay
separate from the ten uninstrumented corrected trials and original failures.

The Linux TLS SIGPIPE fix is independently demonstrated by a real broken-peer
RED signal exit versus GREEN TLS-error return and normal child exit, preserving
signal policy/socket ownership; its focused Linux/Darwin and C-shim sanitizer
checks have their own scope. Using that library here does not prove that
SIGPIPE caused either original upload-credit failure or reclassify an INVALID
attempt. The original exit-after-cleanup scope and raw failure texts remain.

#### Reproduction inputs

Use the source/tool versions above and [README.md](README.md). After the
existing TLS/HPACK/QUIC build tasks and optimized server builds, run one
owned server at a time on CPU 0. Go TLS uses port 18442; Mojo H2 uses 18443;
aioquic H3 uses 18452; Mojo H3 uses 18453. Pin clients/collector to CPUs 1–2.
Start the matching existing server entrypoint (the native libraries and
generated fixture certificate paths must already exist):

```sh
taskset -c 0 env GOMAXPROCS=1 build/http-go -tls -addr 127.0.0.1:18442 -idle-timeout 3600s -cert build/tls/test-cert.pem -key build/tls/test-key.pem
taskset -c 0 build/http2-server
taskset -c 0 pixi run -e tls-http3 python benchmarks/http3_aioquic_baseline.py --host 127.0.0.1 --port 18452 --certificate build/tls/test-cert.pem --private-key build/tls/test-key.pem
taskset -c 0 build/http3-server
```

Use the existing exact duration-client commands below; vary `C` over 1/16/64
and `S` over 1/10, retaining fresh logs, actual exits and owned cleanup.

```sh
taskset -c 1,2 h2load --alpn-list=h2 --tls13-ciphers=TLS_AES_128_GCM_SHA256 -c "$C" -m "$S" -t 1 --warm-up-time=10s -D 30s --log-file=request.lat https://127.0.0.1:18443/fixed
taskset -c 1,2 pixi run -e tls-http3 python benchmarks/http3_load.py --url https://127.0.0.1:18453/fixed --clients "$C" --streams "$S" --warmup 10 --duration 30
taskset -c 1,2 pixi run -e tls-http2 python benchmarks/http/http2_scenarios.py --url https://127.0.0.1:18443/fixed --scenario slow --siblings 8
taskset -c 1,2 pixi run -e tls-http3 python benchmarks/http/http3_scenarios.py --url https://127.0.0.1:18453/fixed --scenario cancel --siblings 8
```

Switch each URL to its baseline port for the paired baseline. Run both
`slow` and `cancel` for each protocol without overriding their existing
payloads/deadlines. Netem uses [LINUX_NETWORK.md](LINUX_NETWORK.md)'s owned
namespace wrapper with `--delay-ms 10 --loss-percent 1`, one trial at a time.
Resource capture uses [sample_resources.py](sample_resources.py), preserving
actual process identity and full raw records before selecting windows.

Allocation and syscall results need a separate supported-tool report with
its coverage and overhead. Allocation instrumentation is not provided by
this prepared tool set: absent evidence is unavailable, not zero allocations
or a new installation gate. Formal observations above preserve the incomplete H2 cancel cell.
Allocation/syscall profiler results remain unavailable without their own qualified evidence.
