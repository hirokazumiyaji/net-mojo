# QUIC provider receive fuzzing

Run `pixi run -e tls-http3 fuzz-quic-recv`. The build installs pinned
`cargo-fuzz` 0.13.2 and nightly Rust 2026-10-01 under ignored `build/fuzz/`,
then compiles the real provider and patched quiche dependency with Rust
coverage and AddressSanitizer. A working `rustup` launcher is required.
BoringSSL is built by quiche's normal CMake path and is not itself sanitizer
instrumented by this task.

Inputs contain a sequence of two-byte big-endian lengths and datagram bytes.
An incomplete final datagram uses its available tail; a lone length byte is
ignored. Empty datagrams exercise the ABI's ordinary rejection path. Every
input gets a fresh provider server configured with generated test certificates,
loopback address strings, at most four connections and 2 MiB of transport memory.
The target accepts at most 8192 bytes and processes at most 32 datagrams. It
makes no socket calls to an external server.

Seeds include short, truncated and unsupported headers and independent aioquic
Initial packets to reach the provider's connection admission and TLS receive
paths. The Initial seed's random connection ID and TLS random bytes are retained
in `build/fuzz/quic-recv-corpus` alongside evolved libFuzzer inputs. Keep that
corpus outside tracked source. Ordinary harness tests cover packet splitting,
packet count limits and malformed provider inputs.

PR smoke runs for 60 seconds on Linux x86_64, Linux arm64 and macOS arm64.
Nightly runs use 1800 seconds on both Linux platforms. Corpus caches persist
between runs; crash/timeout/oom/leak inputs and JSON reproduction metadata are
retained with the complete target log as artifacts for 14 days. A fresh build may take longer than fuzzing.

```sh
pixi run -e tls-http3 fuzz-quic-recv --seconds 5 --seed 227
pixi run -e tls-http3 fuzz-quic-recv --replay build/fuzz/quic-recv-crash-HASH
```

Use the same revision and pinned compiler to replay retained inputs. No
long-running results are claimed until the scheduled workflow is merged and
has actually run.
