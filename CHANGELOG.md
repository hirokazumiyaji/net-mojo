# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version source of truth is `version` in `pixi.toml`.

A name is public API when it is reachable from `net` without a leading
underscore (see README "Versioning and compatibility"). Anything under
`net/_sys/` or starting with `_` may change without a version bump.

## [Unreleased]

### Added

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
