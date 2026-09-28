# QUIC UDP Transport Implementation Plan

> **For agentic workers:** Execute this plan inline, using test-driven development and committing each testable slice.

**Goal:** Drive a quiche server connection from UDP packets and deadlines.

**Architecture:** Keep UDP socket ownership in Mojo and quiche protocol state in the optional Rust provider. Define a small datagram boundary that accepts a packet and peer address, advances one connection, and exposes pending output and the next timer deadline.

**Tech Stack:** Mojo `UDPConn` and `Reactor`, Rust quiche 0.29.3, C ABI.

**Spec:** GitHub Issue #42, Phase 8 and Phase 9; provider choice in `docs/design/quic-transport.md`.

## Global Constraints

- Keep the QUIC provider optional; default and HTTP/2 environments must not acquire Rust or quiche dependencies.
- Use quiche for QUIC loss recovery, congestion control, TLS integration, and HTTP/3/QPACK.
- Keep the UDP socket owned by the Mojo server and use nonblocking readiness.
- Bound packet size and per-turn work; keep connection state owned by the event loop.

## Review Focus

- A received Initial creates one connection and produces a routable server response.
- A datagram from a second peer cannot be delivered to the first peer's connection.
- A connection timeout is surfaced even if no UDP packet arrives.
- A nonblocking send that cannot complete retains pending output for a later writable event.
- Socket descriptors remain owned by `UDPConn` through provider calls.

### Task 1: Provider datagram boundary

**Files:** `net/quic/provider/src/lib.rs`, `net/quic/provider/net_quic_provider.h`, `net/quic/provider/shim.c`, `net/quic/__init__.mojo`, `tests/test_quic_provider.mojo`, and Rust provider tests.

**Interfaces:** The provider accepts a datagram plus local and remote addresses, stores connections by connection ID, returns pending datagrams with their destination, and reports the next timeout. The exact C representation must match `SocketAddress` and remain independent of socket ownership.

- [x] Write a localhost UDP integration test that exchanges the QUIC/TLS handshake through the provider and asserts ALPN `h3`.
- [x] Run the test to confirm that it fails because the provider datagram boundary is absent.
- [x] Implement connection lookup, Initial acceptance, packet receive/send, and timer advancement with bounded datagram buffers.
- [x] Run the provider test and full `quic-suite` on Linux x86_64.
- [x] Review the diff, record results in `tasks/todo.md`, and commit this independently testable transport slice.

## Review

- The UDP test fails before implementation with the missing `QuicServer` API and passes after adding it.
- Linux x86_64 `quic-suite`, Rust format check, shell syntax check, and `git diff --check` pass.
- This task implements the provider state boundary only. C/Mojo socket integration, connection limits, HTTP/3 request streams, and send fairness remain later slices.
