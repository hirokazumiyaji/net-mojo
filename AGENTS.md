# Repository Guidelines

## Project Structure & Module Organization

`net/` contains the public Mojo networking package. Core socket and OS bindings live in `net/` and `net/_sys/`; HTTP is under `net/http/`, with optional TLS and QUIC providers in `net/tls/` and `net/quic/`. Keep public imports in the package API and implementation details internal. `tests/` holds Mojo test programs, `examples/` has runnable loopback examples, and `benchmarks/` contains measurement programs plus an independent Go HTTP baseline. Design contracts live in `docs/design/`; build scripts are in `scripts/`.

## Build, Test, and Development Commands

Install the pinned toolchain with `pixi install --frozen`. Run `pixi run format` to format Mojo source. Run `pixi run test` for the core suite or a focused task such as `pixi run test-tcp` or `pixi run test-http-server`. `pixi run sanitize` runs the sanitizer suite. Optional provider checks require their feature environment, for example `pixi run -e tls-http2 tls-suite` or `pixi run -e tls-http3 quic-suite`. Use `pixi run package` to build distributable artifacts. Benchmarks are run with `pixi run benchmark-*` and report measurements without pass/fail thresholds.

## Coding Style & Naming Conventions

Use Mojo formatting via `pixi run format`; follow existing four-space indentation, `snake_case` functions and variables, and `PascalCase` types. Keep internal implementation names prefixed with `_` and preserve the public API boundary documented in `README.md`. Prefer focused changes that match neighboring module structure and documented design contracts.

## Testing Guidelines

Add or update the relevant `tests/test_*.mojo` program for behavior changes, then run its matching Pixi task and the full `pixi run test` suite when practical. Tests are warning-clean (`--Werror`). TLS, HTTP/2, and HTTP/3 behavior has dedicated feature environments and interoperability tasks; use those when changing provider paths. CI runs formatting, tests, package smoke checks, and separate sanitizer steps.

## Commit & Pull Request Guidelines

Recent history uses concise imperative subjects, often with prefixes such as `docs:`, `test:`, and `ci:`. Keep commits focused and explain the reason when it is not clear from the subject. Pull requests should summarize behavior and rationale, link the relevant issue, list validation commands and results, and call out platform or optional-provider impact. Include before/after examples when changing public API behavior.

## Security & Configuration

Do not commit real credentials or deployment certificates. TLS examples use generated test certificates; replace them for deployment. Keep optional native provider dependencies out of core-only changes unless required.
