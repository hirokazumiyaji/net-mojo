# net package design

This document records the design rationale behind the `net` package: the goals it
serves, the constraints it accepts, and the reasons behind each significant
decision. Usage instructions are out of scope here.

## Goals

- Provide synchronous IPv4/IPv6 addressing, OS name resolution, TCP, UDP, and
  Unix stream sockets for Mojo 1.0.0.
- Keep core `net` dependent on Mojo `std` and the documented libc/POSIX ABI,
  with no C shim or third-party runtime. Optional protocol features may add
  isolated native dependencies.
- Make descriptor ownership, timeout semantics, and partial I/O explicit in the
  type signatures rather than in prose.
- Stay warning-clean under `--Werror` on both supported targets.

## Non-goals for the initial release

Asynchronous I/O, a custom DNS client, raw IP and multicast
APIs, Linux abstract Unix sockets, Unix datagram sockets, Happy Eyeballs,
Windows, and 32-bit ABIs are all out of scope. Each of them either requires a
runtime the package does not want to own (async) or an ABI surface that
cannot be verified on the supported matrix. HTTPS is an opt-in OpenSSL-backed
feature and does not add a dependency to core `net`.

## Module layout

| Module | Responsibility |
| --- | --- |
| `net/ip.mojo` | `IPAddress`, `AddressFamily`, textual parsing and formatting |
| `net/address.mojo` | `SocketAddress`, host/port splitting, zones, `getaddrinfo` |
| `net/error.mojo` | `NetError`, `NetErrorKind` |
| `net/timeout.mojo` | `Timeout` and the internal absolute `_Deadline` |
| `net/tcp.mojo`, `net/udp.mojo`, `net/unix.mojo` | Protocol-specific public types |
| `net/poll.mojo` | Single-threaded readiness multiplexing (`Poller`) |
| `net/_sys/` | POSIX bindings, ABI layout checks, per-platform constants |

Only `net/_sys/` performs low-level socket `external_call`. `net/address.mojo`
additionally calls libc directly for name resolution and zone handling
(`getaddrinfo`/`freeaddrinfo`, `if_nametoindex`/`if_indextoname`), so an ABI
change is confined to those two places.

### Platform constants

`net/_sys/darwin.mojo` and `net/_sys/linux.mojo` hold the constants and struct
layouts that differ between the two targets (`AF_INET6`, `SOCK_CLOEXEC`, errno
values, `sockaddr` prefix layout, `MSG_*` flags). `net/_sys/common.mojo` selects
between them at compile time. ABI safety is enforced by `_verify_abi_layouts()`,
a `comptime assert` bundle invoked from the three ABI-storage constructors
(`_OwnedFD`, `_RawSocketAddress`, `_ResolverHints`) and from the
`net/address.mojo` zone helpers (`_resolve_zone`, `_format_zone`), which
call libc without building any of those three types: it rejects unsupported
targets and pins the size of each FFI struct, so an ABI drift fails the build
instead of corrupting memory at runtime. Every FFI path runs at least one of
these checks, so an unsupported target still fails to build without repeating
the check on every entry path.

## Descriptor ownership

`_OwnedFD` is a move-only RAII wrapper. `__deinit__` takes the raw value and
closes it only when it is still valid, so a moved-from descriptor is never
closed twice, and an error path that unwinds before a connection is constructed
still releases the socket. `TCPConn`, `TCPListener`, `UDPConn`, `UnixConn`, and
`UnixListener` are `Movable` but not `Copyable` for the same reason: duplicating
a connection value would duplicate ownership of the descriptor.

Descriptors are created close-on-exec: `SOCK_CLOEXEC` and `accept4` on Linux,
`fcntl(FD_CLOEXEC)` immediately after `socket`/`accept` on macOS, where those
atomic variants do not exist. Linux needs no follow-up `fcntl` at all; macOS
reads the status flags once and sets what is missing (`F_GETFL`, then
`F_SETFL` and `F_SETFD` only as needed) instead of reading everything back
to verify. `accept` captures the peer address into the same syscall, so
`TCPListener.accept_with_address` returns it without a `getpeername` round
trip. Writes avoid killing the process on a closed peer
via `MSG_NOSIGNAL` on Linux and the `SO_NOSIGPIPE` socket option on macOS; both
turn a broken pipe into an ordinary `EPIPE` error.

## Timeouts and deadlines

The public API accepts a relative `Optional[Timeout]`. Each operation converts it
once, at entry, into an absolute `_Deadline`. Everything below that point works
against the deadline, so a call that internally retries (`connect` then `poll`,
an interrupted `recv`, a `write_all` loop) cannot extend its own budget by
restarting the clock.

Three cases are distinguished deliberately:

- `None` — no deadline. `poll` is given `-1`, the POSIX idiom for an indefinite
  wait, so the thread is not woken periodically for no reason.
- Zero — do not wait. The immediate attempt is made, and a would-block result is
  reported as a timeout rather than being retried.
- Positive — wait until the deadline, then report `NetErrorKind.timeout()`.

`_wait` recomputes the remaining milliseconds on each iteration and clamps to
`Int32.MAX` for the `poll` argument. `EINTR` restarts the wait against the same
deadline instead of surfacing to the caller.

## Errors

`NetError` carries a `NetErrorKind`, the failing operation, an optional errno,
a message, and an optional resolver status. The kind is a small value struct rather than an enum so that it
stays `Copyable`/`Hashable` and can be compared without pattern matching, and it
formats as its name (`timeout`, `invalid_address`, ...) so log output and test
failures are readable. `errno` is preserved rather than being flattened into the
message, which lets callers branch on the raw system error when they need to
(`has_errno`, e.g. for `EAFNOSUPPORT` fallback). System-call failures render
the libc `strerror` text as the message and append the number at display time
(`connect: Connection refused (errno 61)`), so production logs identify the
cause without extra lookups. Name-resolution failures keep the `getaddrinfo`
`EAI_*` code in the separate `resolver_status` field — never in `errno`, which
is reserved for real errnos — with the `gai_strerror` text as the message
(`resolve socket address: ... (resolver status N)`).

## Addresses

`IPAddress` stores 16 bytes plus a family tag; IPv4 values keep their four bytes
in the leading positions. Formatting follows RFC 5952: lowercase hexadecimal, no
leading zeros, and a single longest run of zero groups compressed to `::`.
IPv4-mapped addresses render in mixed notation (`::ffff:192.0.2.1`).
IPv4-mapped addresses parse and round-trip.

`SocketAddress` adds a port and an IPv6 scope ID. Textual forms accept both
numeric zones (`[fe80::1%3]:443`) and interface names (`[fe80::1%en0]:443`);
names are resolved with `if_nametoindex`. Formatting reverses that with
`if_indextoname` and falls back to the decimal scope ID when the index has no
name, and parsing accepts everything formatting emits, so `String(address)`
round-trips through `SocketAddress.parse`.

`split_host_port` implements the host/port grammar without resolving anything:
bracketed IPv6 literals are required to carry brackets, an unbracketed literal
with a colon is rejected, ports are bounded to five digits and 16 bits, and
embedded NUL bytes are rejected before any value reaches libc. Listeners use the
same routine with an empty host allowed, so `:0` means "any address, ephemeral
port". A wildcard IPv6 bind (`:port`, `[::]:port`) is dual-stack
(`IPV6_V6ONLY=0`), accepting IPv4 clients too, and falls back to `0.0.0.0`
where IPv6 is unavailable; pass `ipv6_only=True` for a v6-only socket.
A specific IPv6 address such as `[::1]` stays v6-only.

## Name resolution

`resolve_socket_addresses` tries a numeric parse first and only calls
`getaddrinfo` when that fails, so literal addresses never touch the resolver.
Resolution is the OS's synchronous `getaddrinfo`; the package does not implement
a DNS client. The candidate list preserves the order the OS returned and scans
at most the first 64 `addrinfo` chain entries (skipped non-INET families
count toward the scan, so a chain leading with 64 unusable entries yields no
candidates) to bound the work a hostile resolver can create. The
`addrinfo` chain is freed on both the success and error paths.

Resolver time is deliberately outside the connect timeout: `getaddrinfo` offers
no portable deadline, so charging its duration to the caller's timeout would
make the deadline unenforceable. `dial_*` starts the deadline after resolution
and attempts each candidate in order, remembering the last error and skipping
families the host does not support.

## I/O semantics

Stream reads are allowed to be partial, and the count is returned rather than
looping internally, which is what a caller framing its own protocol needs.
A return of `0` means the peer shut down its write side (EOF) — except on
an empty buffer, where `0` only means nothing was requested. `write_all`
loops until every byte is written or an error occurs, since a partial
write is almost never useful to a caller. UDP separates the two modes it can be
in: `dial_udp` returns a connected socket exposing `read`/`write`, `listen_udp`
returns an unconnected one exposing `recv_from`/`send_to`, and using the wrong
pair raises `invalid_state` instead of silently doing something surprising.
`UDPReceiveResult` reports truncation explicitly, so a datagram larger than the
buffer is detected rather than being silently cut.

Unix socket paths are never unlinked by the package. Removing a path is only
safe once every descriptor bound to it is closed, and only the caller knows
when that is true.

## Multiplexing

One thread serves many connections with `Poller` (`net/poll.mojo`), a
level-triggered readiness set built on `poll(2)`: register each socket's
`raw_fd()`, call `wait` with an optional `Timeout`, then use `try_read` /
`try_write` / `try_accept` / `try_recv_from` / `try_send_to` on the ready
indices. This is the minimal multiplexing step — it reuses the package's
existing non-blocking descriptors and per-fd `poll` logic, so an event loop
needs no threads. `poll(2)` scans every registration on each call; an
epoll/kqueue backend is a future optimization that keeps this API.

`try_*` methods make exactly one syscall attempt: `EINTR` is retried and a
would-block socket reports `NetErrorKind.timeout()` instead of waiting, so
the loop can move on to the next ready descriptor. A readable registration
also covers hangup and error conditions, so a closed peer surfaces as `0`
(EOF) or a system error on the next `try_*` call rather than hanging the
loop.

`net/_reactor.mojo` is the internal readiness layer used by `net.http`.
It keeps the `Poller` contract (single-owner sockets, `raw_fd()` borrows,
exactly one owner closes) and adds stable slot+generation tokens, interest
updates, and ready-event batches. The production backend is epoll on Linux
and kqueue on macOS (`net/_sys/readiness.mojo`, level-triggered, no
runtime fallback); the poll implementation served as the baseline and is
not on the production path. Ready events drive only touched connections
through a slot map with token-equality checks, so idle connections cost
no per-tick full-table scan; deadlines expire through an indexed min-heap
and the wait timeout peeks the heap minimum. Per-arch ABI layouts
(`epoll_event` packed vs aligned, `kevent` size/offsets, token
round-trip) are pinned by build-time checks covered in `test_sys`.

`raw_fd()` borrows the descriptor number; ownership stays with the socket.
The owner must keep each registered socket alive until it is removed:
Mojo destroys a move-only value at its last use, so an unreferenced socket
may be closed while `wait` still watches its number, and a recycled number
can then report readiness for the wrong socket. Hold every registered
socket in a live binding or close it explicitly.

Threads and cancellation build on the same borrow rule. Connection and
listener objects are single-owner and are never shared across threads:
the toolchain provides no `Send`-style marker, so the premise is
documented instead of typed — hand out plain fd numbers (`Int32` from
`raw_fd()`) and keep exactly one owner that closes. `shutdown()` takes a
non-mutating `self` and maps to a single syscall, so calling it from
another thread while `read` blocks elsewhere is sound; the blocked read
returns promptly (EOF or an error) instead of waiting out its deadline.
`close()` keeps exclusive (`mut`) access: never race a close against
in-flight I/O on the same descriptor. `Poller` itself is single-threaded
state; drive it from one thread. Async I/O remains future work pending
language support.

## HTTP/1.1 origin server

`net/http/` is a plaintext HTTP/1.1 origin server built on the reactor
above. The full contract lives in `docs/design/http-server.md`; this
section records only the package-level boundaries.

- Import from `net.http`, never re-exported through `net`. The parser
  (`_parser`) and encoder (`_encoder`) are socket-independent; HTTP
  semantics never leak into `net/_sys`.
- One event loop owns the listener and the connection table. `serve`
  takes listener ownership; `tick` runs one iteration and returns
  `False` once the listener is gone and no connection remains. Tests
  drive `tick` directly for deterministic I/O.
- Handlers (`Handler.handle`) run synchronously on the loop thread and
  see bounded buffered requests only: the full body (up to
  `max_body_bytes`) arrives before the call. `Request` views and
  `ResponseWriter` live only for the call; retaining means copying,
  and the connection owns the queued response until it is sent.
- One global `BufferBudget` counts wire bytes in receive buffers and
  queued responses. Admission failures become 503+close, handler
  overruns and raises become 500+close without leaking details, and a
  slow reader pauses further reads so kernel buffers absorb the
  backpressure instead of user memory.
- Deadlines are absolute monotonic timestamps fixed at phase entry
  (header/body/write/idle/shutdown grace); receiving one more byte
  never extends them. Shutdown stops accepting, closes idle
  connections at once, and drains in-flight requests within the grace
  period.
- `serve_tls` opts into OpenSSL-backed TLS and routes negotiated `h2` and
  `http/1.1` connections through their protocol adapters; a handshake deadline
  bounds incomplete peers. Core `net` and plaintext server builds remain
  OpenSSL-free. HTTP/3 uses a separately configured QUIC UDP endpoint and the
  same shared `Request`/`Headers`/`Handler`/`ResponseWriter` semantics; wire
  formats and state machines stay per protocol. There is no `net/http/_http3/`
  package — HTTP/3 framing stays in the quiche provider.
- Same-origin ops model: one `Server` may own a TCP TLS listener and a QUIC UDP
  endpoint on the same host:port (`examples/http3_hello.mojo`). Reuse the same
  certificate and key for both stacks; example PEMs under `build/tls/` are for
  local smoke only. Only `header_deadline`, `body_deadline`, `idle_timeout`,
  and `write_deadline` are forwarded to the QUIC endpoint
  (`Server.add_quic_endpoint`); `tls_handshake_timeout`,
  `detached_response_timeout`, and `stream_idle_timeout` have no effect on
  HTTP/3, and `shutdown_grace` orchestrates both stacks at the `Server`
  level. Connection and memory bounds are enforced per stack, not shared:
  `max_connections` caps TCP and QUIC independently (up to the configured
  count in each), `total_buffer_budget` covers the HTTP connection path while
  the QUIC provider enforces its own transport-memory limit plus separate
  fixed 64 MiB request/response caps. Size the process for the sum of both
  stacks. HTTP/2 stream caps and the Issue #42 flood / QUIC transport-memory
  knobs land on sibling PRs [#71](https://github.com/hirokazumiyaji/net-mojo/pull/71)–[#75](https://github.com/hirokazumiyaji/net-mojo/pull/75).
- `Alt-Svc` advertisement is opt-in ([PR #77](https://github.com/hirokazumiyaji/net-mojo/pull/77)):
  set `ServerConfig.alt_svc` (for example `h3=":443"; ma=86400`) when a QUIC
  endpoint is attached; leave it empty when QUIC is unavailable so HTTPS does
  not advertise H3. Handler-supplied `Alt-Svc` wins. Misconfigured advertisement
  without a listening H3 endpoint is a documentation/ops error only.
- Shutdown remains cooperative and single-threaded (`request_shutdown` between
  `tick`s): stop accepting, close idle TCP, drain in-flight work through
  `shutdown_grace`, and for HTTP/3 send staged GOAWAY then `H3_NO_ERROR` close.
  Cross-thread shutdown with a wakeup fd is still future work.
- Dependency updates: bump OpenSSL / libnghttp2 ranges in `pixi.toml` and
  refresh `pixi.lock`; bump quiche in `net/quic/provider` and refresh its
  `Cargo.lock`; rebuild optional `tls-http2` / `tls-http3` artifacts and re-run
  those suites. Do not fold provider upgrades into core `net` CI matrix edits
  without an explicit follow-up.

## Testing

Tests are split per module (`test_core`, `test_ip`, `test_address`, `test_sys`,
`test_tcp`, `test_udp`, `test_unix`) and run with `--Werror`. Socket tests bind
loopback with an ephemeral port so they neither collide nor reach the network.
Examples double as end-to-end checks: each one verifies its own payload and
exits non-zero on mismatch. Benchmarks report measurements only and define no
pass/fail thresholds, so they cannot fail CI for timing reasons.

HTTP adds `test_http_api`, `test_http_parser`, `test_http_response`,
`test_reactor`, `test_http_server`, `test_http2`, `test_http_detach`, and
`test_actor` plus `benchmark-http-parse` and `benchmark-http-server`. Parser
coverage includes splits at every byte boundary, a seed-recorded (seed 42)
randomized fragmentation case, a
malformed corpus mapped to 400/413/414/431/505/417, and overflow/limit
tables. `package_smoke` verifies the precompiled `build/net.mojoc`
artifact serves both the TCP round-trip and the `net.http` codec.
`tls-http2 http2-package-smoke` and `tls-http3 http3-package-smoke` also load
the optional HPACK and QUIC providers through that precompiled artifact.
Sanitizer steps (`sanitize-sys`, `sanitize-tcp`, `sanitize-udp`, `sanitize-unix`,
`sanitize-actor`, `sanitize-http2`, `sanitize-http-detach`) and fd-leak checks
(`test_sys`, `test_reactor`) keep
running in CI; long RSS/soak runs and formal 30 s x 5 performance
comparisons stay manual and are recorded in `benchmarks/http/README.md`.

`pixi run test` and `pixi run sanitize` run the full test and sanitizer suites locally; per-module tasks (`pixi run test-tcp`, `pixi run sanitize-tcp`, ...) match what CI executes step by step.
