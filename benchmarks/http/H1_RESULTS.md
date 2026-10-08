# HTTP/1.1 results — current comparison and retained history

The current numerical comparison and its recorded source/tool/binary provenance are available in [H1_RESULTS.tables.json](H1_RESULTS.tables.json).

The current matched comparison uses benchmark policy 93 (Go TCP SO_KEEPALIVE OFF, with HTTP connection reuse unchanged) and the unchanged frozen Mojo runtime 87. All 120 original-schedule trials are valid. Fixed 64 B throughput passes the original ≥0.90 criterion at 64 and 1,024 connections, with paired ratios 1.0203 and 1.0869. The separate five-pair planned-arrival LATENCY cell at 250 requests/s passes the original ≤1.2 p99 criterion with ratio 0.9074. JSON and echo observations receive no added numerical targets; the large-body throughput gap remains visible.

The first section below retains the qualified current comparison, including its rates, latencies, errors, classified cutoffs, resource coverage and source limits. The historical section preserves the complete earlier v5 report. Its asymmetric TCP maintenance policy, old R500 latency, invalid rows, failed original soaks, traced controls and historical Darwin observations remain separate evidence. No old row is replaced, spliced into a current aggregate or relabeled as policy 93. Whole-allocator/RSS bounds and an exact kernel cause are not established.

## Current maintained-cohort — passed (one Go → Mojo pair)

The separately identified policy 93 pair completed 1,800 s per role at 250
planned requests/s, with the original 9,900 idle + 100 actually used active
sockets. Both roles completed all 450,000 scheduled requests successfully,
validated 28,800,000 response bytes, and recorded zero errors, cutoffs,
dropped or unstarted arrivals. Each role also validated all 2,500 warmup
requests. Original idle postflight confirmed all 9,900 sockets; all 100
original active sockets were used, with zero replacements or early closes.

| Role | Valid/criterion | Measured success / scheduled | Errors / cutoff / dropped / unstarted | Final original idle / active used | Planned-start p99 ms |
| --- | --- | ---: | --- | --- | ---: |
| Go | Pass | 450,000 / 450,000 | 0 / 0 / 0 / 0 | 9,900 / 100 | 3.173749 |
| Mojo | Pass | 450,000 / 450,000 | 0 / 0 / 0 / 0 | 9,900 / 100 | 2.590850 |

This is one maintained-cohort pair, separate from the 120-trial
comparison and its five-pair LATENCY gate. The latency scalars are descriptive;
raw individual samples are not exported and their ranks are not independently
reconstructed. The complete counts, epochs, cohort checks, scalar latency/start
lag, clipped resources, quarter coverage and provenance are in the machine
table's `maintained_cohort` key.

| Actor | CPU % | Observed CPU interval s | Sampled RSS bytes | Sampled FD | Snapshots |
| --- | ---: | ---: | --- | --- | ---: |
| Go server | 4.764869 | 1799.000003111 | 218,673,152–277,929,984 | 10,007 | 1,800 |
| Go loader | 10.861591 | 1798.999790235 | 93,257,728–146,034,688 | 10,006 | 1,800 |
| Mojo server | 3.181768 | 1798.999814529 | 53,563,392–53,567,488 | 10,009 | 1,800 |
| Mojo loader | 10.631465 | 1798.999455696 | 91,049,984–143,839,232 | 10,006 | 1,800 |

Each actor has 450 clipped snapshots per 450 s quarter. Mojo server FD is
10,009 in every snapshot; RSS rises by one 4,096-byte page, then all later
samples show 53,567,488 B from 68.836275879 s through the last capture. Go server FD
is 10,007 throughout; RSS grows early and all later samples show
277,929,984 B from 673.845189090 s,
with its last two quarters constant. The maximum gaps between snapshots are
0.994585751 s (Go server), 1.014559126 s (Go loader), 1.025084042 s
(Mojo server) and 1.025678084 s (Mojo loader). This satisfies the original
sampled server stability criterion; discrete captures do not establish a
continuous maximum or whole-allocator/RSS cap. Loader RSS grows while retaining
successful-latency samples and is reported separately, without claiming all
process RSS stayed constant.

Independent terminal qualification verified 118 artifacts, 23 zero-exit host
steps, all eight owned PIDs and seven groups absent, and exact source/binary/
tool/container constraints before and after. Its summary SHA256 is
`173d91c6e51b2c16fa7504b19901004abbb6ae21f1019ee45cd71160eae6a439`;
the reviewed terminal checker SHA256 is
`690949e50655ac6ec6082b1c9afd3b08a730150570975cb81370f7dd7f227874`.
No kernel cause or success of either old failed soak is inferred. This pair
does not supply a global Issue-completion or unrelated native/H2 verdict.

## Current matched H1 comparison — TCP keepalive OFF

All 120 original H1 trials were valid: five alternating Go/Mojo pairs in each of 12 cells. The original fixed 64 B throughput criteria passed at 64 and 1,024 connections, with paired Mojo/Go medians of 1.0203 and 1.0869 respectively (required ≥0.90). The independently qualified fixed-arrival comparison at 250 requests/s had a paired p99 median of 0.9074 (required ≤1.2). JSON and echo results remain descriptive: the 64 KiB echo throughput was about 5% of Go in these measurements, and its p99 latency was higher. No JSON or body-size numerical target is introduced.

### Source, policy and execution conditions

Go benchmark source is the clean local policy 93 projection `9ebb9ee120e979cd305ac9109ff276754ee593b7`. Mojo uses the unchanged frozen runtime 87 binary. Real constructor checks qualify TCP SO_KEEPALIVE OFF and TCP_NODELAY enabled for the Go baseline and common loader socket families; HTTP connection reuse, body/status validation, timeouts and fixed-arrival accounting are unchanged. This policy aligns the previously unequal background TCP maintenance setting; the results do not establish an exact kernel cause for earlier failures.

This is plaintext HTTP/1.1 in the owned Linux arm64 container: CPUs 0, 1, 2; 2 GiB, disconnected bridge and unchanged capability settings. The server is affined to CPU 0 with `GOMAXPROCS=1` for Go; loader and collector use CPUs 1, 2, with loader `GOMAXPROCS=2`. Live soft/hard FD limits were 1,048,576. Both servers use a 3,600 s idle timeout; Mojo has `max_connections=10,000` and configured `total_buffer_budget=268,435,456` B. The budget is not a whole-allocator/RSS cap.

| Provenance | Recorded value |
| --- | --- |
| Observed trial-window span (UTC) | 2026-10-06T03:40:42.369078+00:00 to 2026-10-06T05:03:10.991020+00:00 |
| Mojo compiler | 1.1.0 (8189361e), original optimized runtime 87 build |
| Go toolchain | 1.26.4, new policy 93 benchmark binaries |
| Mojo H1 binary SHA256 | `8f85d51d16f062b3449847dcb6b3a45a119be3bce5033443e9370c78f2cfeaaf` |
| Go baseline SHA256 | `b6ed0f7905d1c3e696e4e49f118c40ee4acdc03d480fe229eb881e4beeea67cb` |
| Common Go loader SHA256 | `641367c6bcc7085df581f14957f954a486b8561fbc4c0c20b6e7de0d8405b7b2` |
| Source/module binding | Frozen runtime 87 manifest; policy 93 actual 16-file Go module map, six changed Go paths; original 14-file history retained |

Each trial has its original 10 s nominal warmup schedule, a fully drained warmup before measurement, and 30 s measuring interval. The 11 closed-loop cells measure throughput at their fixed concurrency. LATENCY uses 64 worker slots at 250 planned arrivals/s, selected from the already declared capacity ladder after the retained old R500 lost-arrival result; no new pilot or rate fallback was run in this series.

Independent review qualified all 1,992 exported artifact hashes, all 21 host-step exits, 360 actor groups and the owned phase/job, with 362 registered PIDs and 361 groups absent at terminal. Source, binary, tool and container constraints matched before/after. The preexisting unrelated zombie 329 was present before and after and was not signalled.

### Throughput

Per-role values are medians of five independent trial rates. The ratio is the median of the five within-pair Mojo/Go ratios; it is not obtained by dividing the two displayed role medians. All rows have 5/5 valid pairs. Rounded display values retain full precision in [H1_RESULTS.tables.json](H1_RESULTS.tables.json).

| Cell | Workload | Go req/s | Mojo req/s | Paired throughput ratio | Original numerical scope |
| --- | --- | ---: | ---: | ---: | --- |
| F1 | Fixed 64 B; 1 connection | 20,225.4 | 19,680.3 | 0.9719 | Descriptive |
| F64 | Fixed 64 B; 64 connections | 127,003.5 | 129,180.3 | 1.0203 | ≥0.90: pass |
| F1024 | Fixed 64 B; 1,024 connections | 117,514.0 | 127,006.6 | 1.0869 | ≥0.90: pass |
| J64 | JSON 1 KiB; 64 connections | 123,542.3 | 65,826.7 | 0.5342 | Descriptive |
| E1CL | Echo 1 KiB; Content-Length; 64 connections | 114,888.8 | 40,405.6 | 0.3527 | Descriptive |
| E64CL | Echo 64 KiB; Content-Length; 64 connections | 23,414.2 | 1,193.0 | 0.0508 | Descriptive |
| E1CH | Echo 1 KiB; chunked; 64 connections | 92,436.6 | 37,071.1 | 0.4010 | Descriptive |
| E64CH | Echo 64 KiB; chunked; 64 connections | 23,256.9 | 1,206.8 | 0.0515 | Descriptive |
| I10000 | 9,900 original idle + 100 active | 103,256.0 | 103,310.1 | 1.0404 | Descriptive |
| CHURN | Fixed 64 B; 64 workers; new connection/request | 46,190.5 | 45,020.8 | 0.9439 | Descriptive |
| SLOW | Fixed 64 B; 64 active + three original slow clients | 109,622.0 | 109,718.1 | 0.9939 | Descriptive |
| LATENCY | Fixed 64 B; 64 workers; 250 planned arrivals/s | 250.0 | 250.0 | 1.0000 | Fixed-arrival rate, no throughput target |

The complete series contains 236,504,824 successful measured completions and 16,369 classified measured cutoffs, with zero errors. Closed-loop requests still in flight at the cutoff remain classified; no cutoff row was discarded or replaced. Successful completions determine throughput, validated body totals and the reported completion-latency population.

### Reported successful-completion latency

Each per-role percentile entry is the median of that reported percentile across five trials, in milliseconds. Percentile samples are not pooled across trials. H1 individual latency samples are not exported, so the raw quantile ranks are not independently reconstructed here. The paired p99 column independently recomputes the median of the five within-pair ratios.

| Cell | Go p50 ms | Go p95 ms | Go p99 ms | Mojo p50 ms | Mojo p95 ms | Mojo p99 ms | Paired p99 ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| F1 | 0.049250 | 0.059334 | 0.069667 | 0.051792 | 0.058625 | 0.066833 | 0.9774 |
| F64 | 0.395042 | 1.038125 | 3.571666 | 0.402500 | 0.945833 | 3.531500 | 0.9912 |
| F1024 | 8.373500 | 13.418500 | 16.126334 | 7.802875 | 12.729500 | 15.729875 | 0.9492 |
| J64 | 0.408125 | 1.097583 | 3.547292 | 0.957333 | 1.208625 | 1.912625 | 0.5378 |
| E1CL | 0.466458 | 1.118791 | 3.407083 | 1.565792 | 1.683458 | 3.116292 | 0.9119 |
| E64CL | 2.209125 | 5.329333 | 15.593583 | 53.173041 | 56.057917 | 75.186417 | 4.7844 |
| E1CH | 0.555500 | 1.549458 | 3.763500 | 1.701167 | 1.943250 | 3.386208 | 0.8993 |
| E64CH | 2.229333 | 4.728417 | 19.702375 | 52.541042 | 55.599792 | 73.572125 | 3.7082 |
| I10000 | 0.767083 | 2.725125 | 4.608834 | 0.766125 | 2.437750 | 4.541333 | 0.9611 |
| CHURN | 1.258292 | 2.493375 | 3.350958 | 1.291458 | 2.590167 | 3.501083 | 1.0448 |
| SLOW | 0.466833 | 1.280292 | 3.655416 | 0.457250 | 1.243625 | 3.720583 | 1.0178 |
| LATENCY | 0.928134 | 1.598256 | 2.342676 | 0.851505 | 1.532595 | 2.097254 | 0.9074 |

LATENCY measures from the planned arrival until successful full-response validation, including start lag; its separate service-latency records are not substituted. All 10 trials completed the 2,500 warmup and 7,500 measured planned arrivals with zero dropped, unstarted, error or cutoff counts. The original clipped CPU admission was qualified for every trial: server <80%, loader <160%, each with at least 2 s of observed CPU intervals. The resulting p99 ratio 0.9073573572923963 passes the original ≤1.2 condition. Other rows’ p99 ratios are descriptive and do not receive that fixed-arrival acceptance gate.

### Clipped resources

CPU values below are medians of the five per-trial percentages. 100% represents one logical CPU; the loader has two CPUs available. RSS and FD ranges are the minimum/maximum sampled values across the five measuring windows, not whole-process-lifetime peaks, allocator caps or 30-minute stability results. Warmup and drain are excluded. CPU intervals span approximately 29 s per 30 s window (actual retained coverage 28.993140514–29.004674847 s), based on positive monotonic deltas between matching running PID/start-token records. Samples straddling the boundaries are excluded without prorating; CPU/RSS/FD use `capture_begin >= start` and `capture_end < end`.

| Cell | Go server CPU % | Go loader CPU % | Mojo server CPU % | Mojo loader CPU % |
| --- | ---: | ---: | ---: | ---: |
| F1 | 42.55 | 71.55 | 36.97 | 71.03 |
| F64 | 93.76 | 121.21 | 97.31 | 118.31 |
| F1024 | 99.79 | 148.96 | 99.45 | 156.35 |
| J64 | 93.07 | 124.69 | 99.97 | 107.27 |
| E1CL | 96.38 | 119.90 | 100.00 | 92.10 |
| E64CL | 98.21 | 162.69 | 100.00 | 16.66 |
| E1CH | 96.24 | 123.24 | 99.97 | 95.59 |
| E64CH | 98.76 | 155.38 | 100.00 | 15.76 |
| I10000 | 90.31 | 149.46 | 88.45 | 150.62 |
| CHURN | 88.07 | 191.59 | 79.86 | 193.72 |
| SLOW | 94.48 | 133.51 | 94.83 | 137.24 |
| LATENCY | 3.86 | 9.45 | 2.59 | 9.17 |

CHURN’s loader medians are near its two-CPU allocation; that limitation remains visible rather than being used to discard rows or add a qualification threshold. The high Go 64 KiB echo loader CPU and low Mojo echo throughput also remain reported without a new target or an inferred cause. Loader RSS includes its own retained successful-latency samples and is separate from server resource use.

| Cell | Role | Server sampled RSS MiB | Server sampled FD | Loader sampled RSS MiB | Loader sampled FD |
| --- | --- | ---: | ---: | ---: | ---: |
| F1 | Go | 13.86–15.88 | 8 | 13.18–23.00 | 7 |
| F1 | Mojo | 16.01–17.76 | 10 | 13.38–23.12 | 7 |
| F64 | Go | 13.72–15.77 | 71 | 14.98–85.29 | 70 |
| F64 | Mojo | 16.02–17.33 | 73 | 15.07–85.35 | 70 |
| F1024 | Go | 41.02–43.15 | 1031 | 63.61–122.81 | 1030 |
| F1024 | Mojo | 18.19–19.77 | 1033 | 62.84–145.38 | 1030 |
| J64 | Go | 13.95–15.97 | 71 | 15.28–83.31 | 70 |
| J64 | Mojo | 16.25–16.96 | 73 | 14.91–48.72 | 70 |
| E1CL | Go | 13.61–16.05 | 71 | 15.20–71.23 | 70 |
| E1CL | Mojo | 16.12–17.41 | 73 | 14.62–36.45 | 70 |
| E64CL | Go | 13.91–16.18 | 71 | 17.01–29.14 | 70 |
| E64CL | Mojo | 25.05–26.42 | 73 | 14.04–20.45 | 70 |
| E1CH | Go | 13.78–16.11 | 71 | 14.93–58.94 | 70 |
| E1CH | Mojo | 16.09–16.89 | 73 | 15.13–36.44 | 70 |
| E64CH | Go | 13.44–16.18 | 71 | 17.00–28.73 | 70 |
| E64CH | Mojo | 24.22–26.28 | 73 | 15.39–21.20 | 70 |
| I10000 | Go | 331.17–337.36 | 10007 | 118.46–173.68 | 10006 |
| I10000 | Mojo | 50.08–51.95 | 10009 | 118.46–173.74 | 10006 |
| CHURN | Go | 13.40–16.12 | 8–70 | 15.41–42.50 | 29–70 |
| CHURN | Mojo | 16.20–17.71 | 26–67 | 14.88–36.43 | 26–70 |
| SLOW | Go | 13.84–18.14 | 74 | 16.71–73.23 | 73 |
| SLOW | Mojo | 20.45–23.87 | 76 | 16.87–73.23 | 73 |
| LATENCY | Go | 13.37–15.87 | 9–13 | 15.04–15.98 | 8–12 |
| LATENCY | Mojo | 16.39–17.69 | 10–18 | 13.10–15.98 | 7–15 |

I10000’s original-socket proof is independent of FD counts: all 10 trials initially confirmed 9,900 idle and 100 active sockets, actually used all 100 original active sockets, made zero replacement attempts/early active closes, and completed the original 9,900 idle postflight probes. This is the original 30 s workload evidence, separate from the qualified 1,800 s one-pair outcome above.

SLOW retained all three original slow clients (headers, body and response reader), measured incomplete traffic and exact validated payload checks, including 1 MiB reader bodies. Their original start/final/used/closed counts passed. Server-send-pressure remains explicitly unverified; no EAGAIN or new pressure criterion is inferred.

### Clock and passive-context limits

All three passive namespace records per trial lie outside the actual 30 s measuring window. Their producer 450 s quarter labels are retained metadata, not measuring-window snapshots, socket survival counts or a cause proof. Settings/qdisc records matched before/after according to the qualified packet.

Three nominal UNIX warmup-end-to-measurement-start gaps are negative: F1-2-go −148,843 ns, F1-3-mojo −69,385 ns and F1-5-go −99,176 ns. The exact loader source with SHA256 prefix `5075912` drains every warmup worker through the result channel before starting the measured phase, with time.Time monotonic deadline comparisons. The serialized nominal warmup deadline is not the actual drain-completion epoch. These signed fields are preserved without inferring measured-phase overlap or an exact clock cause.

### Retained history and remaining scope

Every earlier original H1 attempt, invalid arrival row, R500 latency series, ON-policy soak and historical platform/CPU/syscall comparison remains unchanged in its own epoch. None supplies replacement rows or current-policy targets in this table. Those results retain their original socket policy and provenance; they do not substitute rows in this matched OFF-policy series.

H2 current-policy phases and the separately qualified matched 250 req/s, 30-minute Go→Mojo pair retain distinct evidence. The pair outcome above does not replace current120 rows or supply a new five-pair performance gate. No whole-RSS bound, exact kernel cause, Issue completion or remote publication is claimed here. The retained independent terminal qualification is the raw-evidence authority; the public table records its hashes and summary values without publishing the underlying raw packet.

### Public tables and reproduction references

The full-precision current numeric derivative is [H1_RESULTS.tables.json](H1_RESULTS.tables.json), SHA256 `f5226aee2c8668f2f2761be31d8989c2063d2ef52164255f1093ea4be583dbec`. The independently qualified terminal summary is identified by SHA256 `42973f004e2955e2c833964e495e83b143f5bc84bde2069b4e529149cf5f4cb7`; the public table retains reviewed artifact/count/source/binary/tool hashes, while raw execution and ownership records remain retained separately. This hash is a provenance identifier, not an exported raw packet or a new measurement.

For current H1 reproduction, use benchmark policy 93 and the source/tool versions above with the [HTTP procedure](README.md), [resource sampler](sample_resources.py), [H1 entrypoint](../http1_server.mojo) and independent [Go baseline/loader module](../http_go). Retain the 10 s warmup plus drain, 30 s measured windows and alternating five-pair schedule; current LATENCY is 250 planned arrivals/s. For the separate maintained-cohort pair, run Go then Mojo once each with `-connections 100 -idle-connections 9900 -rate 250 -warmup 10s -duration 1800s`, retaining the same 64 B response, 3,600 s server idle timeout, source/tool versions, CPU/FD/container settings and original-socket postflight checks. Historical reproduction inputs below retain their historical policies and rates.

## Retained historical v5 record

The following report is frozen historical text. All its numerical values, failures, diagnostics, reproduction inputs and evidence limits are retained verbatim; only Markdown heading depth changes. Its opening verdict and final “Static preparation only; not run” row describe that earlier snapshot, not the current policy 93 campaign or the completed R250 pair above. Older preparation/status wording is not adopted as a present-day result. The earlier Go server/common loader enabled TCP keepalive while the Mojo accepted server did not; those comparisons are explicitly separate from the current aligned OFF-policy results.

## HTTP/1.1 Linux ARM64 results — draft

This original 120-trial series meets the fixed-64-B throughput target at
64 and 1,024 connections. JSON and echo throughput is lower than the Go
baseline in the same environment and remains follow-up work. This draft
records that result without adding a new performance threshold.

There are 118 valid trials and two invalid fixed-arrival warmups. All 120
attempts remain retained; none was replaced. The original fixed-arrival p99 verdict
is unavailable because only four of the required five pairs are valid.
A separate corrected-loader series at 500 requests/s now has five valid
pairs, with a paired p99 ratio of 0.9712 against the unchanged 1.2 target.
Both original 30-minute soaks completed active traffic but failed their
original idle-cohort postflight; that qualification remains unresolved.
The separate syscall and short idle diagnostics, historical Darwin comparison
and exact example witnesses are reported below. HTTP/2/HTTP/3 results are
reported separately and are not H1 qualification.

### Sources and conditions

The measured production server, baseline, loader, handlers, parser and
locked toolchain inputs correspond to source commit
`ef57bcdd17a9dc1df8194272c327ddccae86611e`. Their selected source bytes
were compared with that commit. These results precede the subsequent
fixed-arrival warmup correction. The separate corrected-loader results
below identify their changed loader source explicitly.

| Condition | Recorded value |
| --- | --- |
| Host and Linux | Apple M2 Pro Docker VM; aarch64, `7.0.14-linuxkit` |
| Container | 2 GiB memory; CPU IDs 0–2; disconnected external bridge network; loopback |
| Server / loader affinity | Server CPU 0; loader and collector CPUs 1–2 |
| Go baseline and loader | Go 1.26.4 linux/arm64; server `GOMAXPROCS=1`, loader `GOMAXPROCS=2` |
| Mojo server and parser | Mojo 1.1.0 (`8189361e`), AOT `-O3`, production `Server.serve` |
| FD limit | Actual server and loader soft/hard `RLIMIT_NOFILE`: 1,048,576 / 1,048,576 |
| Duration | 10 s warmup, 30 s measurement, five pairs per cell; alternating server order |
| HTTP behavior | Plain HTTP/1.1; keepalive except CHURN; exact status, media type and payload validation |
| Server deadlines | 5 s headers, 30 s body, 30 s write; benchmark idle timeout 3,600 s on both servers |
| Ordinary loader | 5 s request timeout; saturated closed loop except fixed-arrival latency |

`GET /fixed` returns 64 `a` bytes. `GET /json` returns the same exact 1,024-B
JSON on both servers. Echo cells use `POST /echo`, 64 ordinary workers, and
exact 1-KiB or 64-KiB payloads, separately with Content-Length or chunked
framing. F1/F64/F1024 use 1/64/1,024 ordinary workers. There is no TLS or
packet-loss injection in these H1 trials. Linux x86_64 checks under
emulation establish functional correctness separately; no emulated
performance result is claimed here.

Recorded executable SHA256 values:

| Executable | SHA256 |
| --- | --- |
| Go server | `5a7c9db9a1df7e1da93db09664ea19a960c250a59750dbd8b99191220197ead7` |
| Mojo server | `8f85d51d16f062b3449847dcb6b3a45a119be3bce5033443e9370c78f2cfeaaf` |
| Go loader | `d590ff54968159b37951a55fc60b518fa1fc24f5377efa0fe5781f70eaff12a0` |
| Mojo parser | `c8205039c348c6a4bbf53cb7e077f81447956481047a30239fa833db5c5a05b8` |

### Complete cells

Each row has five valid paired trials. Rates are the median of each server's
five rates; ratios are the median of the five paired Mojo/Go ratios, which
need not equal the ratio of the two rate medians. Request percentiles use
sorted successful samples at index `ceil(q*n)-1`; percentiles are not pooled
across trials. These saturated p99 ratios are observations, not the
unsaturated-latency acceptance test.

| Cell | Workload | Go median req/s | Mojo median req/s | Paired req/s ratio | Go median p99 ms | Mojo median p99 ms | Paired p99 ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| F1 | Fixed 64 B, 1 connection | 18,545.3 | 19,030.1 | 1.0079 | 0.1048 | 0.0935 | 0.9312 |
| F64 | Fixed 64 B, 64 connections | 108,260.8 | 109,618.0 | 1.0125 | 3.5999 | 3.7141 | 1.0248 |
| F1024 | Fixed 64 B, 1,024 connections | 107,150.8 | 120,181.4 | 1.1114 | 17.7172 | 18.8269 | 1.0111 |
| J64 | JSON 1 KiB, 64 connections | 116,718.7 | 66,010.6 | 0.5656 | 3.5883 | 1.9039 | 0.5291 |
| E1CL | Echo 1 KiB, Content-Length | 106,300.6 | 40,547.1 | 0.3818 | 3.5009 | 3.0925 | 0.8817 |
| E64CL | Echo 64 KiB, Content-Length | 22,539.7 | 1,121.2 | 0.0497 | 13.9736 | 76.4106 | 5.4332 |
| E1CH | Echo 1 KiB, chunked | 94,976.6 | 37,801.5 | 0.3979 | 3.7167 | 3.3179 | 0.8926 |
| E64CH | Echo 64 KiB, chunked | 19,023.0 | 1,131.1 | 0.0594 | 15.2233 | 77.2942 | 5.3120 |
| I10000 | 9,900 idle + 100 active | 98,118.8 | 103,519.1 | 1.0458 | 4.7662 | 4.5444 | 0.9555 |
| CHURN | Fixed 64 B, connection per request | 41,132.4 | 42,375.4 | 1.0325 | 3.7843 | 3.4807 | 0.9350 |
| SLOW | 64 active + three slow profiles | 104,063.2 | 107,049.7 | 1.0262 | 3.5791 | 3.7285 | 1.0374 |

F64 and F1024 exceed the existing ≥0.90 throughput criterion, with paired
medians 1.0125 and 1.1114. JSON is 0.5656 of Go throughput; 1-KiB echo is
0.3818/0.3979 and 64-KiB echo is 0.0497/0.0594 for Content-Length/chunked.
Those gaps are retained rather than hidden by the passing fixed-response
cells; this series alone does not identify their cause.

#### Payload rates and latency distribution

Each value below is the median of five individual trials for that server,
shown **Go / Mojo**. p50/p95 use the same successful samples and percentile
method as p99 above. Response rates use the recorded
`response_bytes_per_second`; request-body rates use the recorded
`request_body_bytes / elapsed_seconds`. Values are converted to MiB/s
(1 MiB = 1,048,576 B). They count validated ordinary-workload payload,
not headers, chunk framing, TCP bytes or the additional slow-profile traffic.
Error percentage is `100 * errors / started`; every trial in these complete
cells recorded zero errors. Cutoff counts remain separate as reported below.

| Cell | p50 ms (Go / Mojo) | p95 ms (Go / Mojo) | Response payload MiB/s (Go / Mojo) | Request body MiB/s (Go / Mojo) | Errors (Go / Mojo) |
| --- | ---: | ---: | ---: | ---: | ---: |
| F1 | 0.0517 / 0.0514 | 0.0726 / 0.0699 | 1.1319 / 1.1615 | 0.0000 / 0.0000 | 0% / 0% |
| F64 | 0.4768 / 0.4660 | 1.2705 / 1.2438 | 6.6077 / 6.6906 | 0.0000 / 0.0000 | 0% / 0% |
| F1024 | 9.1601 / 8.1491 | 14.8029 / 14.1657 | 6.5400 / 7.3353 | 0.0000 / 0.0000 | 0% / 0% |
| J64 | 0.4325 / 0.9484 | 1.1808 / 1.2480 | 113.9831 / 64.4635 | 0.0000 / 0.0000 | 0% / 0% |
| E1CL | 0.4984 / 1.5520 | 1.2563 / 1.7657 | 103.8091 / 39.5967 | 103.8091 / 39.5967 | 0% / 0% |
| E64CL | 2.2865 / 56.7025 | 6.1805 / 58.3757 | 1408.7313 / 70.0771 | 1408.7313 / 70.0771 | 0% / 0% |
| E1CH | 0.5595 / 1.6655 | 1.4223 / 1.8751 | 92.7506 / 36.9155 | 92.7506 / 36.9155 | 0% / 0% |
| E64CH | 2.6157 / 56.0568 | 8.2506 / 58.8390 | 1188.9354 / 70.6937 | 1188.9354 / 70.6937 | 0% / 0% |
| I10000 | 0.8136 / 0.7846 | 2.6467 / 2.1463 | 5.9887 / 6.3183 | 0.0000 / 0.0000 | 0% / 0% |
| CHURN | 1.4328 / 1.3613 | 2.7919 / 2.7596 | 2.5105 / 2.5864 | 0.0000 / 0.0000 | 0% / 0% |
| SLOW | 0.5049 / 0.4809 | 1.3452 / 1.2814 | 6.3515 / 6.5338 | 0.0000 / 0.0000 | 0% / 0% |

### Resource observations

The following ranges cover the five trials per server, using captures
wholly inside the recorded wall-epoch measurement window. CPU is one-core
percent; RSS is MiB; FD is the open-descriptor count. CPU deltas spanning a
window boundary are excluded, not prorated. Most trials have 30 retained
snapshots and about 29 s of CPU coverage; Mojo E1CH has one trial with 31
snapshots and 30.0005 s coverage. Captures are filtered using recorded
wall epochs, while CPU interval durations use the collector monotonic
clock. Small differences between those clock mappings are observed; the
30.0005-s value does not establish a longer workload. These sampled ranges
are not allocation limits or continuous peak-memory measurements.

| Cell | Go: CPU / RSS / FD | Mojo: CPU / RSS / FD |
| --- | --- | --- |
| F1 | 42.2–42.5% / 13.85–13.88 / 8–8 | 35.8–36.4% / 16.32–17.75 / 10–10 |
| F64 | 93.6–94.7% / 15.87–15.95 / 71–71 | 92.9–94.7% / 16.88–17.42 / 73–73 |
| F1024 | 99.0–99.7% / 41.03–41.30 / 1031–1031 | 93.1–99.0% / 18.07–19.41 / 1033–1033 |
| J64 | 93.6–93.9% / 13.50–15.95 / 71–71 | 99.9–99.9% / 16.33–17.94 / 73–73 |
| E1CL | 95.0–96.9% / 13.80–16.08 / 71–71 | 99.8–100.0% / 16.39–17.88 / 73–73 |
| E64CL | 96.2–97.3% / 13.68–16.16 / 71–71 | 99.9–100.0% / 24.21–26.22 / 73–73 |
| E1CH | 96.4–96.7% / 13.74–16.12 / 71–71 | 98.1–100.0% / 16.45–17.46 / 9–73 |
| E64CH | 93.3–95.6% / 13.73–16.20 / 71–71 | 100.0–100.0% / 25.17–26.00 / 73–73 |
| I10000 | 90.8–91.4% / 331.16–334.77 / 10007–10007 | 89.7–90.9% / 50.22–51.41 / 10009–10009 |
| CHURN | 88.2–89.5% / 13.77–16.10 / 8–63 | 79.0–80.7% / 16.20–17.02 / 17–56 |
| SLOW | 95.6–96.1% / 13.70–17.02 / 74–74 | 94.8–95.4% / 20.80–22.80 / 76–76 |

Across the 118 valid trials, Go has 125,283,693 successful requests, zero
errors and 8,186 cutoff requests; Mojo has 95,104,855 successes, zero errors
and 8,184 cutoffs. Success counts equal latency sample counts and validated
payload-byte counts reconcile with the selected workload. A cutoff is a
request finishing at or after the measurement boundary and is excluded
from successful samples. Go and Mojo have 1,770 and 1,771 retained server
snapshots respectively, including the eight valid fixed-arrival trials.
The loader is observed separately: CHURN uses 189.3–190.4% CPU for Go and
192.2–194.0% for Mojo on its two CPUs, so this case is close to loader
capacity and cannot establish unlimited server scaling.

The idle cell confirms 9,900 original idle sockets and 100 original active
sockets before/after each trial, all 100 active sockets used during
measurement, and zero replacements. It is a 30-s measured exposure after
warmup, not a 30-minute soak or proof of a memory bound under every workload.

The slow cell adds one original socket of each kind. Every socket was
confirmed initially/finally, used in measurement and closed afterward.
In each 30-s window, slow headers remained incomplete for 29.9895–29.9929 s
with 119–120 drip bytes; bodies for 29.9946–29.9974 s with
121,856–122,880 drip bytes and two validated echo cycles. Readers consumed
7,798,784–7,864,320 paced bytes in 119–120 quanta, with seven fully
validated 1-MiB responses and an incomplete phase of 29.9752–29.9993 s.
Readers requested a 65,536-B receive buffer; Linux reported 131,072 B.
These are actual overlapping traffic measurements. The original series
marks server-side send pressure unverified; unread client bytes alone do
not prove backpressure.

### Fixed arrivals and parser scope

A separate 3-s warmup/10-s pilot selected 1,000 requests/s, with valid
responses on both servers. Observed server CPU was 6.44% for Go and 5.11%
for Mojo; loader CPU was 14.11%/15.33%. That pilot supported an unsaturated
load choice, not the five-pair p99 verdict.

In the original formal fixed-arrival series, both second-pair loaders
rejected warmup: 10,000 arrivals were scheduled and 9,999 started/succeeded,
with one unstarted arrival and no response errors. Their loader exits were
1. Four valid pairs cannot supply the required five-pair median or a p99
pass. That original-series verdict remains unavailable; the separate
corrected series below does not splice or replace its trials.

#### Separate corrected fixed-arrival series

The corrected loader is from source commit
`e6cc162beadce4971f98455eb02e46ceccb5a7d6`; its executable SHA256 is
`e9e633c2260f9a82ec7d911b2f217ba0b737ac3a630ea374d6ac16d8a267b6db`.
Its 14 recorded Go source inputs match that commit. The original server
binaries, server source and resource constraints above are unchanged.
The loader offers all nominal warmup slots and drains them before starting
measurement; measured scheduling and cutoff/admission rules are unchanged.

The corrected 1,000-requests/s series retains all ten attempts. All warmups
started and completed their 10,000 offered requests, but only seven measured
trials were valid. Three trials each left one of 30,000 measured arrivals
unstarted. That series has no complete five-pair p99 verdict.

After those observed failures, the bounded capacity procedure was explicitly
clarified: consider the already defined candidates 500 → 250 → 125
requests/s, in that order. Each candidate receives one 3-s warmup/10-s
pilot. Eligibility requires valid zero-lost-arrival work, at least 2 s
observed CPU coverage, server CPU below 80% of one core and loader CPU
below 160% of its two cores. An eligible candidate then receives one
complete alternating five-pair series, with 10-s planned warmup plus drain
and 30-s measurement. Select the first complete admission/resource-valid
series, never by its p99. Do not replace rows, splice older pairs, repeat a
candidate or change the 1.2 p99 target. This is a later declared procedure
clarification, not a claim that the original protocol already specified
full-series fallback.

The first remaining candidate, 500 requests/s, passed its pilot and all ten
formal trials. Each warmup started/completed 5,000 requests; each measured
trial started all 15,000 slots, with no dropped or unstarted arrivals and
zero response errors. Across five trials Go completed 74,999 requests with
one cutoff; Mojo completed 75,000 with zero cutoffs. The median individual
p99 values are 2.8864 ms for Go and 2.6886 ms for Mojo; the median of the
five paired p99 ratios is **0.9712**, within the unchanged **≤1.2** target.
These schedule-to-completion latencies include loader start lag; they are
not just request service time. Server CPU ranges are 5.10–5.21% for Go
and 3.52–3.59% for Mojo; loader CPU ranges are 12.45–13.17% and
12.66–13.00%, using the same recorded-window clipping method. Later
candidates were not needed. All original and corrected attempts remain
retained separately.

At the selected 500 requests/s, the individual-trial median p50/p95
values are 0.8897/1.5619 ms for Go and
0.8571/1.5297 ms for Mojo. Both have median recorded response
payload rates of 32,000 B/s, zero request-body payload and a zero
`errors / started` rate in every trial. These remain separate server
medians, not pooled samples or paired-ratio statistics.

The original 1,800-s soaks and separate syscall diagnosis are reported
below. Their scopes do not establish HTTP/2/HTTP/3 qualification.

The separate parser benchmark has five trials on CPU 0, with median times
669.89585 ns for the 42-B small GET, 5,314.2918 ns for the 1,120-B JSON POST,
and 55,855.917 ns for the 16,574-B chunked input. These are the existing
parser benchmark's input-size timings, not network throughput or a Go
comparison.

### Original 30-minute soaks: idle-cohort qualification failed

Both original 1,800-s trials at the selected 500 requests/s completed
900,000 started/successful fixed responses and 57,600,000 response payload
bytes. Both have zero measured response errors, cutoffs, dropped or
unstarted arrivals and zero request-body payload. All 100 original active
sockets were used, with zero replacement attempts or early active closes.
Those active-traffic results do not make either overall soak valid.

| Server | req/s | Response payload B/s | p50 / p95 / p99 ms | Overall result |
| --- | ---: | ---: | ---: | --- |
| Go | 500 | 32,000 | 0.8967 / 1.5615 / 3.0101 | invalid idle cohort; exit 1 |
| Mojo | 500 | 32,000 | 0.7811 / 1.5742 / 2.8976 | invalid idle cohort; exit 1 |

Each trial initially confirmed all 9,900 original idle sockets. Postflight
stopped at the first failing original socket: Go revalidated a **prefix of
408**, then received write `ECONNRESET`; Mojo revalidated a **prefix of
2,628**, then received write `ETIMEDOUT`. Those prefixes are not a census
of surviving sockets. Both attempts and their failed loader verdicts remain
retained; neither was replaced. The maintained-10,000-socket soak criterion
is unresolved, and these are not a fair resource comparison of two proven
intact 10,000-socket cohorts.

| Process | CPU | Sampled RSS MiB | FD range | Snapshots / CPU coverage |
| --- | ---: | ---: | ---: | ---: |
| Go server | 5.48% | 117.41–297.27 | 2861–10007 | 1800 / 1798.9997 s |
| Go loader | 13.45% | 95.22–157.41 | 10006–10006 | 1800 / 1798.9937 s |
| Mojo server | 3.67% | 50.20–50.20 | 10009–10009 | 1800 / 1799.0005 s |
| Mojo loader | 12.71% | 97.25–157.33 | 10006–10006 | 1800 / 1799.0003 s |

Mojo's server has FD 10,009 and RSS **52,633,600 B** in every one of its
1,800 measured snapshots. Its declared global buffer budget is
268,435,456 B and maximum connection count is 10,000. Constant userspace
FD/RSS does not prove original socket liveness, complete kernel teardown,
or an allocator/RSS bound. Go's server observations by four consecutive
450-s quarters are below; each quarter contains 450 retained snapshots.
Mojo's same four quarters retain the constant FD/RSS just stated.

| Quarter | Snapshots | Go server FD range | Go server RSS MiB |
| --- | ---: | ---: | ---: |
| 1 | 450 | 2873–10007 | 117.41–297.27 |
| 2 | 450 | 2873–2873 | 117.44–204.05 |
| 3 | 450 | 2861–2873 | 204.05–204.05 |
| 4 | 450 | 2861–2861 | 204.05–204.05 |

The closure cause is unknown. The Go FD-drop timing is compatible with a
TCP keepalive-expiry hypothesis, but effective per-socket settings, probe
state and packets were not captured during either soak. Global challenge-ACK
exhaustion is not supported by the available evidence. No hypothesis is
promoted to a cause or used to reinterpret the failed cohort verdicts.

### Separate 180-second idle diagnostics

Both separate traced diagnostics passed at 500 requests/s: each measured
90,000 successful requests, 5,760,000 validated response payload bytes,
zero response errors, cutoffs, dropped or unstarted arrivals, and no request
body. Each initially and finally confirmed all 9,900 original idle sockets
and all 100 active sockets, with no replacements or active closes before
the measurement deadline. They used the original H1 server binaries and
the corrected loader identified above, with 10-s warmup and 180-s measurement.

| Server | Measurement s | Successful requests | Initial / final idle | Original active used | Setup s | p50 / p95 / p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Go | 180 | 90,000 | 9,900 / 9,900 | 100 | 10.6917 | 1.3174 / 2.0057 / 2.8675 |
| Mojo | 180 | 90,000 | 9,900 / 9,900 | 100 | 7.5753 | 1.3678 / 2.5776 / 3.8658 |

All five completed snapshots at loader-anchor 15/120/140/150/160 seconds
preserve 10,000 reciprocal established pairs with unchanged per-role
fd/inode/tuple/state identities. These anchor times are not measurement
offsets, and the sequential snapshots are not an atomic or continuous census.
Observed server FD counts remain 10,007 for Go and 10,009 for Mojo at these
snapshots. Full configured-filter traces record 10,000 successful connected
descriptor closes per role only after each measurement deadline; terminal
FD drops describe cleanup. This does not establish cooperative server shutdown.

Actual successful socket calls show NODELAY=1 on all connected endpoints.
Go server and both loaders set keepalive=1, idle=15 s, interval=15 s and
probes=9 on all 10,000 connections. The Mojo server has no traced keepalive
option call or sampled keepalive timer. This asymmetry is observed in these
diagnostics; it does not identify the original soak failure. Namespace-wide
whole-lifetime keepalive counter deltas are 240,000 for Go and 118,800 for
Mojo, with no increase in the selected reset/timeout/abort/retransmit counters.
The configured syscall traces contain no EPIPE, ECONNRESET or ETIMEDOUT return;
they do not cover every kernel event or packet.

Tracing changes scheduling and spreads initialization: setup is 10.6917 s
for Go and 7.5753 s for Mojo, compared with 0.9359/0.9215 s in the original
failed soaks. A renewed namespace in later preparation also does not establish
a cause or fix. These are two short diagnostic passes, not five-pair latency
comparisons, uninstrumented resource comparisons, or maintained 30-minute proof.
Both original 1,800-s failures and the unknown cause remain unchanged.

### Separate syscall diagnostic and adjacent controls

Six distinct trials used the same 64-connection fixed-64-B workload:
control-before, traced and control-after for each server, with 10-s warmup
and 30-s measurement. All six have valid exact responses, zero response
errors and zero request-body payload. These diagnostic rows remain separate
from the five-pair formal aggregates. The resource collector sampled the
actual owned server child, not the tracer.

| Trial | req/s | Response payload MiB/s | p50 / p95 / p99 ms | Successes / cutoffs |
| --- | ---: | ---: | ---: | ---: |
| go-control-before | 108,407.2 | 6.6166 | 0.4672 / 1.2917 / 3.6903 | 3,252,215 / 64 |
| go-traced | 33,442.4 | 2.0412 | 1.9092 / 3.6033 / 4.0098 | 1,003,272 / 64 |
| go-control-after | 106,932.4 | 6.5266 | 0.4867 / 1.2926 / 3.6232 | 3,207,972 / 64 |
| mojo-control-before | 110,490.9 | 6.7438 | 0.4690 / 1.2090 / 3.7043 | 3,314,727 / 64 |
| mojo-traced | 35,228.5 | 2.1502 | 1.7935 / 2.0152 / 3.5078 | 1,056,855 / 64 |
| mojo-control-after | 114,487.3 | 6.9878 | 0.4814 / 1.1290 / 2.3335 | 3,434,619 / 64 |

| Trial | Actual server CPU | Server RSS MiB | Server FD |
| --- | ---: | ---: | ---: |
| go-control-before | 93.55% | 13.88–13.96 | 71–71 |
| go-traced | 61.31% | 15.98–15.98 | 71–71 |
| go-control-after | 94.62% | 15.94–15.94 | 71–71 |
| mojo-control-before | 95.28% | 17.13–17.13 | 73–73 |
| mojo-traced | 58.28% | 17.20–17.20 | 73–73 |
| mojo-control-after | 95.80% | 17.41–17.41 | 73–73 |

Each diagnostic trial has 30 retained server snapshots and about 29 s of
CPU coverage under the same recorded-window clipping method. The tracer
and its child shared CPU 0; loader/collector remained on CPUs 1–2. Compare
the traced trial with **both** adjacent controls:

| Server | req/s traced / before, after | req/s traced / control mean | p99 traced / before, after |
| --- | ---: | ---: | ---: |
| Go | 0.3085 / 0.3127 | 0.3106 | 1.0866 / 1.1067 |
| Mojo | 0.3188 / 0.3077 | 0.3132 | 0.9470 / 1.5033 |

Observed traced rates are only about 31% of the adjacent control mean.
These comparisons include normal trial-to-trial drift and are not an
isolated causal estimate of tracer overhead or evidence of a causal p99
improvement. In particular, Mojo's traced p99 is below its before-control
value and above its after-control value.

`strace -f -c` totals cover the **whole owned child lifetime across all
threads**, including startup, warmup, measurement, drain and shutdown:

| Server | Syscall calls | Syscall error returns | Timed syscall seconds |
| --- | ---: | ---: | ---: |
| Go | 4,005,249 | 1,317,717 | 37.824279 |
| Mojo | 4,245,931 | 51 | 6.851193 |

Go records 2,646,367 reads, 1,328,593 writes, 134 epoll control calls and
24,744 epoll waits. Mojo records 1,407,621 recvfrom, 1,407,556 sendto,
1,407,689 epoll control calls and 22,586 epoll waits. Syscall error returns
are not HTTP response-error counts. The saved wall-time bracket describes
the tracer invocation, not exact child start/end. Summed syscall time is
not on-CPU time, per-request cost or allocation measurement; waits and
whole-lifetime activity cannot be assigned to the formal measurement window.

Post-profile metadata identifies strace 6.8, executable SHA256
`33b3ea325915f1213dc477d80e0f0b2b09ffeff5e81d98b25a35320fbcbcaf42`.
That executable was hashed **after** the six trials, not independently
before them. The paired source/tool/binary before/after checks cover the
server/loader and Go/Mojo toolchains, not a claimed pre-profile strace hash.
Separate shortened allocation and syscall counts for the Mojo H1 server and a
parallel Go H1 baseline at the current main SHA are recorded in
[LINUX_REMEASURE_RESULTS.md](LINUX_REMEASURE_RESULTS.md); they do not replace
the published H1 series, and the two sets of allocator counts (Mojo libc
malloc, Go runtime `MemStats`) measure different allocator layers.

To reproduce the six-trial diagnostic, use the same original server and
corrected loader inputs: for each server run F64 control-before, then launch
only its owned child with `taskset -c 0 strace -f -c -o syscalls.txt` plus
the same server argv, then run F64 control-after. Keep `GOMAXPROCS=1` for
the Go server and pin the unchanged 10-s/30-s loader to CPUs 1–2 with
`GOMAXPROCS=2`. Record the exact server child identity/resources, full raw
summary and all exits/cleanup; do not attach to unrelated processes or
substitute this diagnostic for formal throughput results.

### Historical Darwin poll / kqueue comparison

All ten historical trials are valid across five matched repetitions, with
alternating poll-first/kqueue-first order. Each uses 64 closed-loop keepalive
connections, exact fixed 64-B GET responses, no request body, 10-s warmup,
30-s measurement and a 5-s request timeout. Each reports zero response errors
and 64 boundary cutoffs excluded from successful samples. The body/sample/
started/cutoff counters reconcile per trial; percentiles are not pooled.
The historical server prints maximum connections 10,000, buffer budget
268,435,456 B, 5-s header and 30-s body/write deadlines, a 60-s idle timeout,
and per-tick accept/byte/request caps of 64/65,536/16. These historical
defaults differ from the Linux campaign's 3,600-s benchmark idle timeout.

This compares poll revision `094c36537ce586f022ddce2d0e8a64b5ddd6f7a5`
with kqueue revision `a9eb55f0703e5ed2addda13bbf3141b84c4f461b`, built
with Mojo 1.0.0 (`ed45d567`) on Darwin 27.0.0 arm64. Both use the same
benchmark handler and unchanged historical adapter. The compiled runtime
diff covers `net/_reactor.mojo`, `net/_sys/darwin.mojo`,
`net/_sys/linux.mojo`, `net/_sys/readiness.mojo` and `net/http/server.mojo`,
including dispatch, fairness and deadline bookkeeping. The whole repository
revisions differ in ten paths. This measures the complete historical runtime
change; it does not isolate the readiness syscall or qualify the current
Linux server against Go.

| Historical runtime | Median req/s | Median response MiB/s | Median p50 / p95 / p99 ms | Errors |
| --- | ---: | ---: | ---: | ---: |
| poll | 28,791.6 | 1.7573 | 2.1910 / 2.3403 / 3.8801 | 0% |
| kqueue | 27,914.9 | 1.7038 | 2.2798 / 2.4254 / 2.5103 | 0% |

The median of the five paired kqueue/poll throughput ratios is
**0.9678**, and the median paired p99 ratio is **0.6455**.
These are descriptive observations without a new threshold or performance
pass/fail verdict. They differ from ratios of the separate runtime medians.

| Historical runtime | Server CPU % | Sampled server RSS bytes | Server FD | Loader CPU % | Collector own CPU % |
| --- | ---: | ---: | ---: | ---: | ---: |
| poll | 99.689–99.723 | 13,467,648–13,484,032 | 68–68 | 82.972–85.174 | 2.340–2.384 |
| kqueue | 99.689–99.698 | 13,484,032–13,500,416 | 69–69 | 83.308–84.217 | 2.325–2.379 |

All 30 resource points per trial fall inside the recorded measurement window.
CPU uses the approximately 29-s first-to-last cumulative-time subset, with
10-ms CPU resolution and 29 intervals; it is not whole-window CPU. Collector
CPU is its own whole-run overhead. RSS/FD are sampled values, not continuous
maxima or allocation bounds. No uninstrumented control measures collector
overhead. No process affinity, effective quota or per-child effective FD limit
is recorded; the loader uses GOMAXPROCS=2. The inherited parent FD limits
are not asserted as the children's effective limits or evidence of client
or host unsaturation.

Source/tool/binary hashes match before and after execution. All 30 owned
trial processes were reaped with groups absent; loaders and collectors
exit 0, and servers receive intentional TERM after completion. This cleanup
does not prove cooperative shutdown. The retained build history includes
the initial missing-stdlib invocation failure and successful-build Crashpad
warnings; neither is erased or relabeled as a measured workload failure.

Recorded executable SHA256 values for this separate historical comparison:

| Executable | SHA256 |
| --- | --- |
| poll | `492bc7f1ced33b2b226cc43beb914cc390f504a5daa143f9960de73a338a116e` |
| kqueue | `d97f229cfb37ecaa0a24817c0a84acc84f4c9ad7f32a0403da2e5726b5747d87` |
| Closed-loop loader | `eb2875f594d4a4d963fefb4431276d8a561e08542eff56edf7fbad49b425804e` |

The historical loader is the reviewed closed-loop binary, distinct from the
later corrected fixed-arrival loader. The unchanged historical adapter and
matched handler identify this witness's scope; it does not add a new public
historical benchmark entrypoint or substitute modern toolchain builds.

### Exact Hello and JSON example witnesses

Both original example selfchecks and six independent Go wire cases passed
with three warning-clean O3 builds and unchanged 304 source files plus
11 links. The wire cases cover Hello GET/missing route and JSON GET,
Content-Length echo, chunked echo and missing route, validating exact status,
body and header/framing expectations. All owned groups are absent after
cleanup. The initial sandbox compiler failure remains retained. Servers
were cleaned up with owned TERM; these witnesses add no cooperative-shutdown
or continuous FD-bound claim.

### Reproduction inputs

For the original matrix, use the original source commit and toolchain
versions above. For corrected latency, build the loader from its separately
identified corrected commit while preserving the original server source.
Use the workload table in
[README.md](README.md), and the existing server/loader entrypoints. The
following Linux commands build those entrypoints without a new benchmark
engine:

```sh
pixi install --frozen
mkdir -p build/bench/h1
GOTOOLCHAIN=local go -C benchmarks/http_go build -p=1 -buildvcs=false -o ../../build/bench/h1/http-go .
GOTOOLCHAIN=local go -C benchmarks/http_go build -p=1 -buildvcs=false -o ../../build/bench/h1/http-load ./cmd/http-load
pixi run --frozen --no-install mojo build -O3 -Xlinker -ldl -I . benchmarks/http1_server.mojo -o build/bench/h1/http1-server
```

Run one owned server at a time on CPU 0: Go with `GOMAXPROCS=1`,
`-addr 127.0.0.1:18080 -idle-timeout 3600s`; Mojo listens on port 18081.
Run the loader on CPUs 1–2 with `GOMAXPROCS=2`, the matching `/fixed` URL,
`-connections 64 -warmup 10s -duration 30s`, retaining its JSON and exit.
Repeat five pairs, alternating Go-first/Mojo-first. Use `/json` for J64;
`/echo -body-size 1024` or `65536`, optionally `-chunked`, for echo;
`-connections 100 -idle-connections 9900` for idle;
for the retained original soak attempts add `-rate 500 -duration 1800s`
with the corrected loader and unchanged server idle timeout;
`-keepalive=false` for CHURN; and
`-slow-headers 1 -slow-bodies 1 -slow-readers 1` for slow clients.
Collect the owned server and loader using
[sample_resources.py](sample_resources.py), retain actual phase windows,
and discard only out-of-window resource captures, never failed attempts.
These inputs describe reproduction; this draft does not publish a new
campaign runner or certify the unresolved maintained-cohort soak criterion.

### Maintained-cohort evidence still pending

| Evidence | Current status |
| --- | --- |
| Original Go and Mojo 1,800-s soaks | Both retained invalid original idle cohorts; cause unknown |
| Separate Go and Mojo traced 180-s diagnostics | Both pass their short diagnostic oracle; no 30-minute proof |
| One fresh Go → Mojo 1,800-s pair | Static preparation only; not run and no result claimed |

The prepared fresh pair retains the same corrected H1 loader, original server
binaries, 100 active plus 9,900 original idle connections, 500 requests/s,
64-B response, warmup, deadlines and strict final original-cohort checks.
It has no replacement sockets, acceptance waiver, new threshold or automatic
retry. Preparation and a renewed namespace do not resolve the old failures.
The maintained-10,000-connection 30-minute criterion remains unresolved.
