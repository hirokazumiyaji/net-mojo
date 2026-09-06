# net package design

This document records the design rationale behind the `net` package: the goals it
serves, the constraints it accepts, and the reasons behind each significant
decision. Usage instructions are out of scope here.

## Goals

- Provide synchronous IPv4/IPv6 addressing, OS name resolution, TCP, UDP, and
  Unix stream sockets for Mojo 1.0.0.
- Depend on Mojo `std` and the documented libc/POSIX ABI only, with no C shim
  and no third-party runtime.
- Make descriptor ownership, timeout semantics, and partial I/O explicit in the
  type signatures rather than in prose.
- Stay warning-clean under `--Werror` on both supported targets.

## Non-goals for the initial release

Asynchronous I/O, cancellation, a custom DNS client, TLS, raw IP and multicast
APIs, Linux abstract Unix sockets, Unix datagram sockets, Happy Eyeballs,
Windows, and 32-bit ABIs are all out of scope. Each of them either requires a
runtime the package does not want to own (async, TLS) or an ABI surface that
cannot be verified on the supported matrix.

## Module layout

| Module | Responsibility |
| --- | --- |
| `net/ip.mojo` | `IPAddress`, `AddressFamily`, textual parsing and formatting |
| `net/address.mojo` | `SocketAddress`, host/port splitting, zones, `getaddrinfo` |
| `net/error.mojo` | `NetError`, `NetErrorKind` |
| `net/timeout.mojo` | `Timeout` and the internal absolute `_Deadline` |
| `net/tcp.mojo`, `net/udp.mojo`, `net/unix.mojo` | Protocol-specific public types |
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
atomic variants do not exist. Writes avoid killing the process on a closed peer
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
and a message. The kind is a small value struct rather than an enum so that it
stays `Copyable`/`Hashable` and can be compared without pattern matching, and it
formats as its name (`timeout`, `invalid_address`, ...) so log output and test
failures are readable. `errno` is preserved rather than being flattened into the
message, which lets callers branch on the raw system error when they need to.

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

## Testing

Tests are split per module (`test_core`, `test_ip`, `test_address`, `test_sys`,
`test_tcp`, `test_udp`, `test_unix`) and run with `--Werror`. Socket tests bind
loopback with an ephemeral port so they neither collide nor reach the network.
Examples double as end-to-end checks: each one verifies its own payload and
exits non-zero on mismatch. Benchmarks report measurements only and define no
pass/fail thresholds, so they cannot fail CI for timing reasons.

`pixi run test` runs the full suite; per-module tasks (`pixi run test-tcp`, ...)
match what CI executes step by step.
