# Issue #42 remaining work — design

Date: 2026-09-30  
Issue: [#42](https://github.com/hirokazumiyaji/net-mojo/issues/42)  
Approved approach: correctness → product features → measured Phase 10 benchmarks (option A).  
Out of scope: CI workflow / job changes.

## Goal

Close the remaining non-CI gaps so HTTP/1.1, HTTP/2, and HTTP/3 share the handler contract, enforce flood and resource bounds, advertise HTTP/3 via Alt-Svc, and record reproducible protocol benchmarks with real numbers.

## Current baseline

Phases 0–6 and the core of Phases 7–9 are already in tree on `main` (through PR #69 and follow-ups). The Issue #42 remaining stack closes the gaps below on **open sibling PRs** ([#71](https://github.com/hirokazumiyaji/net-mojo/pull/71)–[#81](https://github.com/hirokazumiyaji/net-mojo/pull/81)). This ops-docs branch is stacked on the benchmark PRs (#79–#81) only; PRs #71–#78 live on other branches and are **not** present as code in this worktree tip.

| Area | Gap (pre-stack) | Stack status |
| --- | --- | --- |
| HTTP/2 | No control-frame / RST rate limits or storm tests | [#71](https://github.com/hirokazumiyaji/net-mojo/pull/71)–[#72](https://github.com/hirokazumiyaji/net-mojo/pull/72) (sibling branches) |
| QUIC | 0-RTT not explicitly disabled; reorder/duplicate/NAT stress missing; quiche transport memory outside budgets; UDP send saturation untested | [#73](https://github.com/hirokazumiyaji/net-mojo/pull/73)–[#76](https://github.com/hirokazumiyaji/net-mojo/pull/76) (sibling branches) |
| HTTP/3 | No Alt-Svc; broader reorder/reset stress incomplete | [#77](https://github.com/hirokazumiyaji/net-mojo/pull/77)–[#78](https://github.com/hirokazumiyaji/net-mojo/pull/78) (sibling branches) |
| Phase 10 | No HTTP/2 or HTTP/3 harnesses or recorded results | [#79](https://github.com/hirokazumiyaji/net-mojo/pull/79)–[#81](https://github.com/hirokazumiyaji/net-mojo/pull/81) (this stack) |

Deferred (not required to close #42): HTTP/2 response trailers; full H1↔H2 application-contract mirror suite; enabling 0-RTT; CI workflow edits. macOS end-to-end Mojo HTTP/3 validation is **not** deferred: the checked `http3` workflow runs `quic-suite`, `http3-client-test`, package smoke, and the example build on `macos-14` (`.github/workflows/ci.yml`), so the independent aioquic client already drives the Mojo fixture on macOS.

## Design principles

1. Small reviewable PRs; each PR lands green tests and can merge independently when dependencies allow.
2. Prefer extending existing modules (`ServerConfig`, `_http2/frame_dispatcher`, `net/quic/provider`, `Server`) over new packages.
3. HTTP/3 remains in the quiche provider; do not invent `net/http/_http3/`.
4. Benchmarks follow the Phase 0 procedure in `benchmarks/http/README.md` (warmup 10 s, measure 30 s, ≥5 runs) and record machine, toolchain, and settings with every table.
5. No CI edits in this effort.

## PR plan

### PR 1 — HTTP/2 control / RST rate limits

**Problem.** RFC 9113 allows peers to flood PING, empty SETTINGS ACK paths, WINDOW_UPDATE, and RST_STREAM. The dispatcher accepts each frame without a connection-local token bucket.

**Design.**

- Add `ServerConfig` fields (defaults conservative, documented):
  - `http2_max_control_frames_per_second: Int = 1000`
  - `http2_max_resets_per_second: Int = 100`
  - Sliding 1-second windows counted on the connection session (monotonic clock already used for deadlines).
- On exceed: emit `GOAWAY` with `ENHANCE_YOUR_CALM` (or `PROTOCOL_ERROR` if that code is not yet wired) and begin drain; do not process further application DATA/HEADERS on that connection.
- Count: PING (non-ACK), SETTINGS (non-ACK), WINDOW_UPDATE, PRIORITY if present, and RST_STREAM (separate reset counter).

**Tests.** Unit tests that inject N+1 control frames / RSTs within one second and assert GOAWAY + no further request completion.

**Files.** `net/http/config.mojo`, `net/http/_http2/frame_dispatcher.mojo` and/or `request_session.mojo`, `tests/test_http2.mojo`, brief note in `docs/design/http2-server.md`.

### PR 2 — HTTP/2 reset-storm / control-flood regression

Depends on PR 1. Adds TLS-level or in-process session tests that simulate mixed flood patterns (RST storm while another stream is healthy) and assert only the flooded connection is closed while other TCP/TLS connections continue. May extend `scripts/test_https_server.py` if unit injection is insufficient.

### PR 3 — QUIC: explicitly disable 0-RTT

**Design.** In `net/quic/provider/src/lib.rs` config construction, call the quiche API that disables early data / 0-RTT (or assert `enable_early_data` is never set and add an explicit `disable`/`set_enable_early_data(false)` equivalent). Document in `docs/design/quic-transport.md`.

**Tests.** Rust unit test that reads config flags / rejects early-data tickets if the API exposes them.

### PR 4 — QUIC packet reorder / duplicate / NAT rebinding stress

**Design.** Extend provider tests (preferred) and/or `scripts/test_http3_server.py`:

- Duplicate: deliver the same client datagram twice; connection still completes a request.
- Reorder: swap two consecutive handshake or 1-RTT datagrams; timers drive recovery.
- NAT rebinding: change the observed client UDP address mid-connection; connection continues or cleanly times out without leaking CID routes / fds.

Do not implement full path migration features beyond what quiche already supports; assert resource cleanup either way.

### PR 5 — QUIC transport memory accounting

**Design.**

- Expose a provider-reported estimate of quiche connection memory (quiche’s own stats if available; otherwise `connections.len()` × measured per-conn RSS delta from a calibration probe).
- Add `ServerConfig` / provider limit `quic_max_transport_memory_bytes` (initial default: document as soft estimate; refuse new connections when exceeded).
- Keep existing 64 MiB app request/response queue caps unchanged.
- Update `docs/design/http3-server.md` Remaining section.

**Tests.** Force many idle connections or large crypto state until admission refuses; assert no unbounded map growth after close.

### PR 6 — UDP send backpressure saturation test

**Design.** Fixture that fills the UDP send path until `try_send` would-block, then drains and completes a request. Assert pending datagrams are preserved (already claimed in `tasks/todo.md`) and no drop-without-retry on would-block.

**Files.** `tests/test_quic_provider.mojo` and/or Rust tests; possibly `net/quic/__init__.mojo` only if API needs a test hook.

### PR 7 — HTTPS Alt-Svc for HTTP/3

**Design.**

- `ServerConfig` (or dedicated `Http3Advertise` options): `alt_svc_value: Optional[String]` / `advertise_http3: Bool` plus authority/port used in the value.
- When an HTTPS (TLS) response is finalized and HTTP/3 is configured on the same `Server`, inject `Alt-Svc: h3=":port"; ma=…` unless the handler already set `Alt-Svc`.
- Clear docs: advertisement is opt-in via config when a QUIC endpoint is attached; UDP-unavailable environments still serve HTTPS without H3.
- Example `http3_hello.mojo` / HTTPS path updated to set the advertise config for same host/port.

**Tests.** HTTPS response includes Alt-Svc when enabled; absent when disabled; handler-supplied Alt-Svc wins.

### PR 8 — HTTP/3 reorder + reset-storm interoperability

Depends on PR 4. aioquic/quiche client scripts: reorder application datagrams; reset-storm one stream while siblings complete; assert ALPN `h3` and no false success on HTTPS-only.

### PR 9 — HTTP/2 TLS benchmark + Go HTTP/2 baseline (measured)

**Design.**

- Extend or sibling `benchmarks/http_go` with TLS + HTTP/2 (`golang.org/x/net/http2` or std with `ForceAttemptHTTP2`) matching `/fixed`, `/json`, `/echo`.
- Mojo harness: optimized HTTPS+H2 server binary or scripted `examples/http2_hello`-class server under the same handlers.
- Record tables in `benchmarks/http/README.md`: toolchain, OpenSSL, ALPN `h2`, conn counts, concurrent streams (1 and N), req/s, p50/p95/p99, CPU, RSS, fd.
- Run Phase 0 procedure on the developer machine; label host model / OS; if targets miss, record shortfall without cutting features.

### PR 10 — HTTP/3 benchmark + pinned baseline (measured)

**Design.**

- Pin an independent H3 baseline (aioquic or quiche example server at locked version).
- Mojo H3 fixture under same handlers as H2/H1 benches.
- README tables: RTT loopback, optional induced loss %, concurrent streams, CPU/RSS.
- Same measurement procedure as PR 9.

### PR 11 — Multiplex matrix (measured)

**Design.** Vary connections × streams independently; include slow-stream, cancel, and one loss scenario each for H2 and H3. Append matrix tables and interpretation (targets vs actual) to `benchmarks/http/README.md`.

### PR 12 — Ops docs + design sync

**Design.**

- README / `docs/design/net-package.md`: same origin TCP HTTPS + UDP H3, certs, limits, shutdown, dependency update notes; Alt-Svc behavior.
- Fix stale “`_http3/` later” comments in `net/http/request.mojo`.
- Mark Remaining items done in `http3-server.md` / `quic-transport.md` / `tasks/todo.md` where PRs landed.
- Still no CI YAML changes.

## Error and resource contracts (cross-cutting)

| Case | Behavior |
| --- | --- |
| H2 control/RST flood | GOAWAY + drain; other connections unaffected |
| QUIC over transport memory | Refuse new connections; existing drain normally |
| Alt-Svc misconfig (no H3 endpoint) | Do not advertise; log/doc only |
| Bench target miss | Keep features; record profile note |

## Testing strategy

- Prefer failing tests first per slice (existing suite style in `tests/test_http2.mojo`, Rust `#[test]`, `scripts/test_http3_server.py`).
- After each PR: run the affected pixi tasks only (not full CI matrix edits).
- Benchmarks: store raw run logs under `benchmarks/http/results/` (gitignored if huge) or summarize only committed tables in README; prefer committed summary tables + command lines to reproduce.

## Success criteria for #42 (non-CI)

- [x] PRs 1–8 implemented on the open stack ([#71](https://github.com/hirokazumiyaji/net-mojo/pull/71)–[#78](https://github.com/hirokazumiyaji/net-mojo/pull/78); sibling branches — code not in this worktree tip).
- [ ] PRs 9–11 with real numbers in `benchmarks/http/README.md` ([#79](https://github.com/hirokazumiyaji/net-mojo/pull/79)–[#81](https://github.com/hirokazumiyaji/net-mojo/pull/81); this branch stack). Connections × streams, slow, and cancel are measured on both stacks under a labeled shortened procedure. Still outstanding: an HTTP/2 loss measurement (pf/dummynet needs root, and the 5% client-side datagram drop only covers H3), so this criterion stays unchecked until the H2 loss row has real numbers.
- [x] PR 12 docs match the intended ops model and record stack status honestly (this PR; no claim that #71–#78 code lives here).
- [x] Shared handler serves H1/H2/H3; TLS ALPN `h2` and QUIC ALPN `h3` verified by independent clients (already on `main`; extended by #78).
- [x] Flood bounds, explicit 0-RTT off, Alt-Svc, transport memory story documented and tested (#71–#77 on sibling branches; ops docs here).

Merge of #71–#81 into `main` remains the integration gate; this checklist tracks implementation on the open PR stack, not merge status.

## Non-goals

- CI job additions or sanitizer matrix expansion.
- Server push, CONNECT, 0-RTT enablement, multicore worker model.
- HTTP/2 response trailers and full H1 contract mirror (follow-ups).
- Replacing quiche with a from-scratch QUIC stack.
