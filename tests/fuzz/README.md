# Fuzz smoke targets

Issue #227 is delivered in stages. Current targets cover HTTP/1 `parse_one`,
Host/authority validation, HTTP/2 complete and incremental frame parsing,
IP/socket address parsing and formatting, and the native and Mojo HPACK
encode/decode boundaries. Nightly runs retain evolving native corpora and
reproducible Mojo batches. QUIC targets, minimization and h2spec conformance
follow in separate PRs.

Run `pixi run -e fuzz fuzz-smoke`. It compiles the Mojo replay target with ASan
in the existing `sanitize` environment and the native HPACK target with
libFuzzer, ASan and UBSan in `fuzz`. The separate build environments keep the
native compiler sysroot out of Mojo linking. HPACK runs for 60
seconds, with a 10 second per-input timeout, 2 GiB RSS limit and 8192 byte input
limit. The native build also replays the tracked `x: y` regression fixture and verifies
successful encoding, so fuzz-control choices cannot silently disable that path.
The same fixture is checked for exact decoded contents by ordinary `hpack-test`
and is seeded into both native and Mojo replay targets.
The six Mojo targets replay seed prefixes and 10,000 seeded
mutations each; their process timeout is 60 seconds. `fuzz-http1`,
`fuzz-authority`, `fuzz-http2-frames`, `fuzz-ip`, `fuzz-address`,
`fuzz-hpack-mojo`, and `fuzz-hpack` run targets individually.

The mutation driver covers insertion, replacement, truncation, deletion and
repetition of bytes. Seed inputs include complete and incomplete requests,
Content-Length and chunked/trailer bodies, conflicting framing, absolute-form
request targets, IPv6 authorities, invalid escapes, NUL and invalid UTF-8.
Authority inputs use `String(from_utf8_lossy=...)`, matching the parser's owned
text representation: the target exercises authority validation rather than
an unchecked UTF-8 constructor. IP and socket address targets treat only
`invalid_address` as an expected parse rejection; other errors fail the run.
The frame target parses concatenated frames and replays them through the bounded
incremental reader with variable input chunk sizes. The HPACK Mojo target creates
fresh inflater/deflater handles per input so malformed blocks do not poison later
cases, and checks successful encoded blocks through a fresh decoder.
The Mojo targets have no coverage feedback.
The shared shim loaded by the Mojo HPACK target is built without native
sanitizer instrumentation; the separate native target instruments that same shim.
libnghttp2 itself is the prebuilt dependency; the shim and harness are sanitizer
instrumented, while coverage feedback concerns their compiled code.

Generated batches stay under ignored `build/fuzz/`. Each record contains a
four-byte big-endian length followed by exactly that many bytes. The driver
prints the command to replay the complete batch before starting the target:

```sh
pixi run -e fuzz python3 scripts/run_fuzz.py http1 --replay build/fuzz/http1-seed-227.bin
```

A crash fails the task, and CI uploads the target binaries, exact input batches,
HPACK corpus and libFuzzer crash artifacts. Replay the same binary/toolchain and
batch to reproduce a Mojo failure. For native failures, invoke
`pixi run -e fuzz build/fuzz/hpack build/fuzz/crash-<hash>`.
Use `--seed`, `--iterations`, and `--seconds` on `scripts/run_fuzz.py` to adjust
local exploration. Keep minimized, reviewed regressions in ordinary parser or
HPACK tests; evolving corpora remain outside tracked source.

## Scheduled replay

`fuzz-nightly.yml` runs all seven targets independently on Linux x86_64 and
arm64 at 17:41 UTC daily. Manual dispatch accepts a 1–1800 second target budget;
the default is 1800 seconds. Each job has a 40 minute limit, including builds.
The scheduled workflow starts once it exists on the default branch.

```sh
pixi run -e fuzz fuzz-nightly http2-frames --seconds 30 --seed 227
pixi run -e fuzz fuzz-nightly hpack --seconds 30 --seed 227
pixi run -e fuzz fuzz-nightly-test
```

Mojo runs repeated 10,000-mutation batches with successive seeds until its
budget expires. A batch already started may continue for up to its 60 second
process timeout. Only the current batch and its JSON target, seed, iteration
count and round are retained, including on failure; storage does not grow with
runtime. Replay the downloaded `*-nightly.bin` with the smoke replay command
above and its JSON target. Native HPACK uses libFuzzer's time budget and
retains its corpus across workflow runs using an OS-specific cache.
Artifacts contain reproduction metadata, the current Mojo batch and native
crash/timeout/oom/leak inputs for 14 days. Native metadata records its seed, budget,
input limit and corpus path. Use the same commit and pinned toolchain when
rebuilding a target to replay downloaded inputs.
