# Fuzz smoke targets

Issue #227 is delivered in stages. This first stage covers HTTP/1 `parse_one`,
Host/authority validation, and the native HPACK encode/decode boundary. The
HTTP/2 frame, IP/address and QUIC targets, nightly corpus evolution, minimization
and h2spec conformance follow in separate PRs.

Run `pixi run -e fuzz fuzz-smoke`. It compiles the Mojo replay target with ASan
and the native HPACK target with libFuzzer, ASan and UBSan. HPACK runs for 60
seconds, with a 10 second per-input timeout, 2 GiB RSS limit and 8192 byte input
limit. The native build also verifies that a valid serialized header reaches successful
encoding, so fuzz-control choices cannot silently disable that path.
The HTTP/1 and authority targets replay seed prefixes and 10,000 seeded
mutations each; their process timeout is 60 seconds. `fuzz-http1`,
`fuzz-authority`, and `fuzz-hpack` run targets individually.

The mutation driver covers insertion, replacement, truncation, deletion and
repetition of bytes. Seed inputs include complete and incomplete requests,
Content-Length and chunked/trailer bodies, conflicting framing, absolute-form
request targets, IPv6 authorities, invalid escapes, NUL and invalid UTF-8.
Authority inputs use `String(from_utf8_lossy=...)`, matching the parser's owned
text representation: the target exercises authority validation rather than
an unchecked UTF-8 constructor. The Mojo target has no coverage feedback.
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
