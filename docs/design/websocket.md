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
