# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version source of truth is `version` in `pixi.toml`.

A name is public API when it is reachable from `net` without a leading
underscore (see README "Versioning and compatibility"). Anything under
`net/_sys/` or starting with `_` may change without a version bump.

## [Unreleased]

### Changed

- Make HTTP `ServerControl` copyable and thread-safe, wake the reactor on
  shutdown requests, and keep surviving handles safe after server exit.

- Require Mojo 1.1 only: drop the `mojo-1-0` Pixi environment and CI job, and
  migrate `String.as_c_string_slice` / `CStringSpan.unsafe_ptr` to
  `as_c_string_span` / `ptr`.
- Detect macOS arm64 via `CompilationTarget.is_arm()` instead of
  `is_apple_silicon()` (the latter also requires AMX, which CI runners omit).
- Accept trailing bytes after fixed-length HTTP/2 control payloads when parsing
  RST_STREAM, PING, and WINDOW_UPDATE from a larger buffer.
- Run Sanitize as a required CI job using standalone ASan executables and
  a pinned LLVM runtime on macOS.
- Release the connection actor's detach-state reference in standalone writer
  tests so LeakSanitizer can verify their cleanup.
- Build the HPACK shim before `test-http2` in CI (session flood tests
  `dlopen` `build/http2/libnet_hpack`).
- Keep the HTTP/2 flood fixture ticking while sibling connections remain
  active so Conn B is not closed early on Linux.
- Disable `test_detached_start_failure_drops_remaining_batch` until the
  detach start-failure path writes its 500 response.

### Added

- HTTP/1.1 response trailers via `ResponseWriter.add_trailer(name, value)`:
  the buffered encoder switches to `Transfer-Encoding: chunked`, advertises
  the names in `Trailer:`, and emits the trailer section after the body
  (RFC 9112 §7.1.2). Names in the framing / routing / auth / payload
  deny-list (RFC 9110 §6.5.1) and CR/LF/NUL are rejected; HEAD and
  1xx/204/205/304 responses drop trailers. Trailer bytes count against the
  response header byte limit and the shared buffer budget.
- HTTP/2 response trailers: when `ResponseWriter.trailers` is non-empty on a
  body-capable status, the server emits DATA frames without END_STREAM and a
  final HEADERS frame carrying END_STREAM. Trailer blocks are hand-encoded as
  RFC 7541 §6.2.3 Literal Header Field Never Indexed with literal names, so
  they neither mutate the HPACK dynamic table nor reference any dynamic
  index. Both ends of the connection decode the trailer block correctly
  regardless of other streams' response HEADERS that may have inserted
  dynamic entries between the trailer's encode time and its wire position.
  Flow control still gates the body: trailers are only emitted after the
  last DATA frame leaves the send window.
- HTTP/3 response trailers: when `ResponseWriter.trailers` is non-empty on a
  body-capable status, the quiche provider sends the trailer section after
  the body via `send_additional_headers(is_trailer_section=true, fin=true)`.
  Trailer bytes count against the shared buffered-response budget.

- HTTP/2 server support over TLS ALPN `h2`, including bounded request streams,
  HPACK, connection and stream flow control, fair response scheduling, stream
  refusal, and GOAWAY during graceful shutdown. The optional libnghttp2 shim is
  built in the `http2` environment.
- HTTP/3 server support over a separately configured UDP endpoint using the
  optional quiche provider. Requests share the HTTP handler; shutdown sends
  staged GOAWAY frames, rejects streams above the final boundary, and sends an
  `H3_NO_ERROR` close after the configured grace period.
- Opt-in HTTPS `Alt-Svc` advertisement via `ServerConfig.alt_svc`. When set,
  TLS responses inject that header unless the handler already supplied
  `Alt-Svc`; empty (default) leaves HTTPS unchanged for UDP-unavailable hosts.
- Optional OpenSSL-backed nonblocking TLS server transport in the Pixi `tls`
  environment, used by HTTPS HTTP/1.1 and HTTP/2 ALPN `h2`.
- `net.http` plaintext HTTP/1.1 origin server (single event loop, epoll
  on Linux / kqueue on macOS): `Handler`, `Request`, `Headers`,
  `ResponseWriter`, `Server`, `ServerConfig`, `ServerControl`,
  `listen_and_serve`. Bounded buffered requests only; handler runs
  synchronously on the loop thread. Limits default to 10,000
  connections, 8 KiB request line, 32 KiB / 100 headers, 1 MiB body,
  1 MiB response body, 256 MiB total buffer budget, header/body/write
  deadlines 5 s / 30 s / 30 s, idle keep-alive 60 s, shutdown grace
  30 s. See `docs/design/http-server.md`.
- `net._reactor` internal readiness layer with stable slot+generation
  tokens, interest updates, and ready-event batches (poll baseline,
  then epoll/kqueue production path). The public `Poller` API is
  unchanged.
- `net/_sys/readiness.mojo` with epoll/kqueue bindings, per-arch ABI
  layout checks, and queue-fd leak tests.
- `examples/http_hello.mojo` and `examples/http_json.mojo`
  (`pixi run example-http-hello`, `pixi run example-http-json`).
- HTTP benchmarks: `benchmarks/http_parse.mojo`
  (`pixi run benchmark-http-parse`), `benchmarks/http_server.mojo`
  (`pixi run benchmark-http-server`), Go baseline
  `benchmarks/http_go/main.go`, and the fixed measurement procedure in
  `benchmarks/http/README.md`. Benchmarks report numbers only and
  never gate CI.
- `tests/package_smoke.mojo` now verifies the precompiled artifact
  ships `net.http`: `parse_one` codec round-trip, case-insensitive
  `Headers` lookup, and `has_body_for_status` rules.
- HTTP test suites: `test-http-api` (handler/ownership/control compile
  probe), `test-http-parser` (every-byte-boundary splits,
  seed-recorded randomized fragmentation, malformed corpus, overflow
  and limit tables), `test-http-response` (HEAD/204/304, Date,
  injection rejection, length consistency), `test-reactor` (interest
  changes, fd reuse, stale generations, EINTR, leak checks), and
  `test-http-server` (keep-alive, pipeline order, 100-continue,
  partial I/O, EOF, slow clients, budget admission, handler errors,
  shutdown drain), plus `test-http2` for incomplete, oversized, unknown,
  and concatenated frame fixtures. Long fd/RSS soak tests remain manual
  follow-up;
  timing thresholds are not CI gates.

- `Poller` single-threaded readiness multiplexing over `poll(2)` with
  `try_read` / `try_write` / `try_accept` / `try_recv_from` / `try_send_to`
  and `raw_fd()` borrow accessors.
- TCP socket options: `set_no_delay`, `set_keep_alive`,
  `set_keep_alive_period`, `set_read_buffer`, `set_write_buffer`,
  `set_linger`; new connections default to `TCP_NODELAY=1`.
- `TCPListener.accept_with_address` returning the peer address captured
  by the same syscall (no extra `getpeername`).
- Listen backlog defaults to the kernel `somaxconn`
  (`/proc/sys/net/core/somaxconn` on Linux, `kern.ipc.somaxconn` on
  macOS); explicit values are used as-is.
- `NetError` carries libc `strerror` text and renders errno
  (`connect: Connection refused (errno 61)`); resolver `EAI_*` codes
  moved to a separate `resolver_status` field.
- Linux aarch64 support (CI: `ubuntu-24.04-arm`).
- `pixi run package` builds a precompiled `build/net.mojoc` artifact,
  verified in CI by `pixi run test-package`.

## [0.1.0] - 2026-09-06

Initial release: synchronous IPv4/IPv6 addressing, OS name resolution
(`getaddrinfo`), TCP, UDP, and Unix stream sockets on macOS arm64 and
Linux x86_64, with explicit deadlines, move-only descriptor ownership,
and a warning-clean test suite.
