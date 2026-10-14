# WebSocket server

`net.http.websocket` implements RFC 6455 over HTTP/1.1 Upgrade. It does not
negotiate extensions or compression. HTTP/2 extended CONNECT (RFC 8441),
HTTP/3 WebSocket (RFC 9220), and a public WebSocket client are later phases.

## Ownership

Call `websocket_accept(request, writer, config)` on the HTTP loop. It returns
a movable `WebSocketUpgrade` containing the hijack sender, the selected
subprotocol, and configuration. The issue's original raw `HijackSender`
return sketch would discard negotiated subprotocol metadata before adoption.

Transfer the upgrade to a worker and call `websocket_adopt(upgrade^)` there.
Adoption waits until switching headers have drained; blocking adoption on the
HTTP loop would prevent that handoff. `WebSocketConn` has one owning worker.
The worker drives `read_message`, `write_text`, `write_binary`, `write_ping`,
`write_pong`, and consuming `close`. The handler owns any Origin allowlist;
accepting an Upgrade does not apply an Origin policy.

`selected_subprotocol()` returns the negotiated token. `close_info()` retains
the peer's code and UTF-8 reason. Empty Close payloads are represented by
1005 locally; that sentinel is never sent on the wire.

## Limits and deadlines

Defaults are 1 MiB per frame/message and 64 data fragments per message.
Control frames do not count toward that fragment limit. Incoming client
frames must be masked; outgoing server frames are unmasked. Text and Close
reasons are validated as UTF-8, including incomplete codepoints across data
fragments. Close reasons are always validated even if text validation is
explicitly disabled.

`read_deadline` bounds one complete `read_message` operation, including all
fragments and interleaved controls. The default is 30 seconds. This is a
stronger bound than a separately restarted per-frame timer: Ping/Pong traffic
cannot keep one message read pending indefinitely. `write_deadline` bounds
one whole message write, including outgoing fragmentation; default 10 seconds.

`ping_interval` is disabled by default. When enabled, keepalive is driven by
synchronous reads. Its timeout accounting pauses between `read_message`
calls, so application processing time does not expire a Pong already queued
on the transport. There is no background thread. A missing matching Pong
while the read driver runs closes with 1011.

Consuming `close` sends a validated Close frame, waits for the peer's Close
under one read deadline, then closes the owned transport. In-flight Ping is
answered during that wait. Keepalive scheduling stops during Close. TLS
shutdown is not invoked because the raw transport's shutdown API has no
bounded timeout. Automatic control writes, including Close replies, share the active read
operation budget. Transport EOF and I/O timeout terminate further protocol
I/O. A write timeout aborts the transport: a partial frame or outstanding TLS
retry cannot safely be replaced by a new Close frame. Keepalive failure sends
1011 while framing is intact.

## Transport boundary

`DuplexStream` requires owning `read`, `write`, and consuming `close` methods.
The default adapter owns a `HijackedConn`, including buffered switched bytes
and TLS retry state. Closed connections consume the stream immediately while
retaining Close metadata. The codec does not require TCP or TLS. In-memory streams
exercise the same contract in tests. A future extended-CONNECT stream adapter
can reuse framing and message handling without altering the HTTP/1 hijack API.


## Reproducible conformance

Install the frozen environment, then run:

```sh
pixi run test-http-websocket
pixi run sanitize-http-websocket
pixi run -e tls-websocket websocket-interop
pixi run -e tls-websocket websocket-tls-interop
pixi run -e tls-websocket websocket-interop-sanitize
pixi run -e websocket autobahn-ws
pixi run websocket-package-smoke
```

The independent Python client is `websockets==15.0.1`, driven through its
asyncio API so one TLS driver handles reads and writes. It verifies the generated
fixture certificate and HTTP/1.1 ALPN. WS and WSS cover a coalesced Upgrade and
first frame, 1 MiB text/binary messages, fragmented messages, Ping/Pong, sibling
connections, Close metadata, and ignored extension offers.

Autobahn uses the unmodified `wstest` CLI in
`crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`,
built from upstream revision `6ed6f439dc7ed0d7432fe2cf7481b110905ecc5c`.
Groups 1–7 and 9 are selected; compression groups 12/13 are excluded.
The fixture raises message/frame limits to 64 MiB for upstream large-payload
cases. Each run gets a fresh report directory under `build/websocket-autobahn`.
Every scheduled case must have a report; failures, missing cases, and non-strict
verdicts fail the task. Upstream informational verdicts are retained.

Docker is required. Linux uses host networking; Docker Desktop on macOS uses
`host.docker.internal`, both targeting this repository's own loopback fixture.
CI runs independent WS/WSS and ASan on all three supported platforms and Docker
conformance on Linux x64/ARM64, using pinned amd64 image emulation on ARM64.
Hosted macOS runners lack the Docker daemon needed by the upstream suite.


## Shared parser replay targets

The #227 shared deterministic replay harness exposes `websocket-frames` and
`websocket-utf8`. Standard masked frame vectors and UTF-8 text form bounded
seeds. Whole-frame and byte-at-a-time decoding must agree on rejection codes,
completion, opcode/FIN and payload; whole and byte-at-a-time UTF-8 validation
must agree on validity and completion. Replay batches retain length-prefixed
inputs, each capped at 8192 bytes. Ordinary protocol rejection is expected.

```sh
pixi run -e websocket fuzz-websocket-frames --iterations 10000 --seed 236
pixi run -e websocket fuzz-websocket-utf8 --iterations 10000 --seed 236
python3 scripts/run_fuzz.py websocket-frames --replay build/fuzz/websocket-frames-seed-236.bin
python3 scripts/run_fuzz_nightly.py websocket-utf8 --seconds 5 --iterations 1000 --seed 236
```

Both targets use the existing shared runner and ASan parser binary. Their
retained batches also work with the shared input reducer after the #227
harness is composed.
