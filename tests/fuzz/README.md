# Fuzz smoke targets

Issue #227 is delivered in stages. Current targets cover HTTP/1 `parse_one`,
Host/authority validation, HTTP/2 complete and incremental frame parsing,
IP/socket address parsing and formatting, and the native and Mojo HPACK
encode/decode boundaries. QUIC targets, nightly corpus evolution, minimization
and h2spec conformance follow in separate PRs.

Run `pixi run -e fuzz fuzz-smoke`. It compiles the Mojo replay target with ASan
in the existing `sanitize` environment and the native HPACK target with
libFuzzer, ASan and UBSan in `fuzz`. The separate build environments keep the
native compiler sysroot out of Mojo linking. HPACK runs for 60
seconds, with a 10 second per-input timeout, 2 GiB RSS limit and 8192 byte input
limit. The native build also verifies that a valid serialized header reaches successful
encoding, so fuzz-control choices cannot silently disable that path.
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
