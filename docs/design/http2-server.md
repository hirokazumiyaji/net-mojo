# HTTP/2 server implementation

## Protocol boundary

HTTP/2 uses the existing TLS connection with ALPN `h2`. The HTTP/2 adapter
lives under `net/http/_http2/`; it owns HTTP/2 connection and stream state and
adapts validated requests to the existing HTTP handler contract. HTTP/1.1
parsing and encoding remain protocol specific. Server push is not supported.

## PR 1: bounded frame parser

The first implementation slice adds a socket independent frame parser. It
parses the fixed nine byte frame header and payload from a byte span, returning
`need_more`, `complete`, or `error` with the consumed byte count. It accepts
unknown frame types for later connection layer handling, ignores the reserved
stream identifier bit as required by RFC 9113, and enforces the configured
maximum payload length before exposing a frame. It does not retain caller memory or allocate based on an
unvalidated payload length. Callers own buffering and may pass the next frame
as trailing input.

This slice does not negotiate SETTINGS, validate frame-type-specific lengths,
manage streams, or decode HPACK. Those checks belong to the connection layer
and subsequent PRs. The frame parser has one configured maximum frame payload;
the connection layer will later ensure this stays consistent with the
negotiated `SETTINGS_MAX_FRAME_SIZE`.

The separate client preface parser compares incrementally against the fixed
24-byte connection preface. It consumes exactly those bytes and leaves any
following frame bytes with the caller. It does not enforce when the preface is
required in connection state.

`Http2FrameReader` retains partial bytes for one bounded frame, returns an owned
payload and exact consumed byte count, and leaves coalesced following frames
with the caller.

`Http2ServerConnectionInput` composes preface/SETTINGS bootstrap, the frame
reader, and control dispatcher. It emits protocol output, returns stream frames
for the request layer, and preserves exact input consumption across calls.

The SETTINGS payload codec reads and writes six-byte identifier/value entries
in network byte order. Parsing rejects a trailing partial entry and preserves
unknown identifiers unchanged; connection-level validation, duplicate handling,
and negotiation remain with the connection state machine.

## TLS server entry

After TLS selects ALPN `h2`, `Server` uses `Http2RequestSession` to exchange
the client preface and SETTINGS, assemble bounded requests, and call the shared
handler. It encodes each buffered response with a connection-owned HPACK
deflater and queues its HEADERS and DATA frames through the reactor-owned
connection. The optional HPACK shim is loaded when the first request headers
arrive. It returns connection and stream receive credit after request DATA is
copied into the bounded body buffer. Responses stay within current connection
send credit and the peer's initial stream window; a response body that does not
fit the shared budget at enqueue time is refused on that stream with
RST_STREAM(REFUSED_STREAM) and sibling streams keep running.

Stream-local errors do not escalate to connection errors. A client RST_STREAM
on a stream whose HPACK-encoded HEADERS have not yet been written keeps the
headers queued so they still ship (preserving the deflater's dynamic table),
followed by a server-sent RST_STREAM(CANCEL) that closes the stream. A handler
that writes connection-specific headers (`Connection`, `Keep-Alive`,
`Transfer-Encoding`, `Upgrade`, `TE`) has those fields silently stripped per
RFC 9113 §8.2.2 so a shared HTTP/1 handler cannot kill an HTTP/2 connection.
When response headers still fail to encode (e.g. the field list exceeds the
peer's `SETTINGS_MAX_HEADER_LIST_SIZE` or a `Content-Length` disagrees with the
body) and the HPACK deflater state is still intact, the response is replaced
with a minimal 500 and retried on the same stream; if the retry also fails the
stream is reset with INTERNAL_ERROR. A handler that detaches/streams on
HTTP/2 (SSE) also falls back to a stream-level 500 instead of closing the
connection. A client-sent GOAWAY marks the session draining: new peer HEADERS
are answered with RST_STREAM(REFUSED_STREAM), in-flight streams finish, the
server emits its own acknowledging GOAWAY, and the connection closes once the
scheduler and send-stream list drain. The one place where the connection still
closes under budget pressure is the aggregate request-body reservation across
all concurrent streams: that budget is shared and the server cannot know which
single stream to refuse, so the connection drops once the sum exceeds the
remaining capacity budget.

## Outbound frame encoding

The socket-independent frame encoder writes the nine-byte frame header and
payload in network byte order. It rejects a payload above the configured frame
limit or the 24-bit protocol maximum, and rejects stream identifiers with the
reserved bit set. It does not validate frame-type-specific flags or lengths.

The SETTINGS frame validator requires stream zero, checks that the parsed
payload length matches the supplied bytes, and rejects a non-empty ACK frame.
Unknown flag bits are ignored. It leaves setting-value rules and connection
sequencing to the connection state machine.

The bootstrap state waits for the full client preface, emits one empty server
SETTINGS frame, then accepts the client's initial non-ACK SETTINGS frame and
returns an empty SETTINGS ACK. Known setting values are validated before the
ACK: `ENABLE_PUSH` must be 0 or 1, `INITIAL_WINDOW_SIZE` at most 2^31-1, and
`MAX_FRAME_SIZE` in 16,384 through 16,777,215. Invalid values fail bootstrap
with the corresponding HTTP/2 connection error code and do not acknowledge.
The caller retains and extends preface bytes between incremental parse calls.
Stream processing begins in a later layer.
`Http2ConnectionBootstrap` drives that exchange over fragmented byte input,
enforces the configured inbound frame cap, and returns unconsumed bytes after
the first client SETTINGS for the frame dispatcher. It exposes a value snapshot
of negotiated peer limits for the response encoder and stream admission logic.

Initial client settings are applied in order, with duplicate identifiers using
the last value and unknown identifiers ignored. `ENABLE_PUSH` values must be 0
or 1; `INITIAL_WINDOW_SIZE` is limited to 2^31-1; `MAX_FRAME_SIZE` must be in
the range 16,384 through 16,777,215. Invalid values terminate bootstrap with
the corresponding HTTP/2 connection error code.

Later client SETTINGS frames are also applied in order and acknowledged. The
client may acknowledge the server's initial SETTINGS after its own initial
SETTINGS has been received.

Per-stream state tracks remote and local closure independently. Initial remote
HEADERS opens the request side; a later remote HEADERS block is accepted as
trailers only when it ends that side. DATA requires an open direction, and the
stream closes after both directions end or a reset is applied.

The active stream table accepts only increasing, odd client stream IDs and
keeps open and half-closed streams under an explicit local cap. Exceeding the
cap returns a refusal result for the caller to encode as `REFUSED_STREAM`.
`ServerConfig.max_http2_streams_per_connection` sets this cap and is advertised
to the peer as `SETTINGS_MAX_CONCURRENT_STREAMS`. The cap is independent of the
peer's setting, which limits streams initiated by this server.

HPACK decoding uses an optional libnghttp2 dependency behind a narrow C shim.
Each connection owns one inflater. The shim copies emitted fields into caller
storage and never returns pointers into the compressed block or the inflater's
dynamic table. It continues decoding after the decoded header-list or output
limit is exceeded, then reports the limit result so the connection can reject
the stream without desynchronizing later header blocks.
The compressed block is assembled from HEADERS and matching CONTINUATION
frames under a separate byte cap. Padding and HEADERS priority fields are
removed before the block reaches HPACK. Exceeding the compressed cap fails the
connection because skipping an HPACK block can desynchronize the dynamic table.
`Http2HpackInflater` owns the native inflater and library handle for one
connection. It writes copied fields into caller-owned output as repeated
network-order 32-bit name and value lengths followed by their raw bytes. The
caller sets the table size between blocks and applies protocol header semantics.
`Http2HpackDeflater` applies the same encoded-field contract in the outbound
direction, bounds decoded header size and field count before compression, and
keeps its dynamic table for the connection lifetime.
`Http2HeaderDecoder` combines frame assembly and decoding for one connection,
preserves HPACK state after decoded limits are exceeded, and marks framing or
compression errors as terminal for that decoder. A completed decode retains
the original HEADERS stream ID and END_STREAM bit across CONTINUATION frames.

`Http2FlowWindow` tracks send and receive credit separately for a connection
or stream. DATA debits the corresponding window, and receive credit can be
restored only for bytes the application has consumed. The debit includes the
full DATA payload, including padding. SETTINGS initial-window changes adjust
stream send windows; the connection send window remains fixed.

`Http2FrameDispatcher` is initialized with the bootstrap peer-settings snapshot, receives complete frames, and applies the connection-wide continuation sequence before dispatching control frames. It applies later SETTINGS and returns an ACK, echoes non-ACK PING frames, and reports WINDOW_UPDATE, RST_STREAM, and GOAWAY events to the stream/connection owner. Unknown and stream-specific frames remain available to their protocol layer. Connection-local **tumbling** 1-second windows (counter resets when `now - window_start >= 1s`; not a sliding timestamp deque) cap non-ACK PING/SETTINGS, WINDOW_UPDATE, and PRIORITY via `ServerConfig.http2_max_control_frames_per_second` (default 1000) and RST_STREAM via `http2_max_resets_per_second` (default 100). New client HEADERS have an independent `ServerConfig.http2_max_new_streams_per_second` cap (default 1,000,000). It counts increasing odd stream IDs before HPACK decoding, including attempts refused by the concurrent-stream cap; CONTINUATION and trailers do not increment it. A zero cap refuses the first new stream. Exceeding any cap signals a flood; `Http2RequestSession` encodes GOAWAY with `ENHANCE_YOUR_CALM` (error code 11) using the session `_last_stream_id`, marks the session failed while entering drain so the server flushes the frame and then closes the connection once pending output reaches zero, and refuses further request completion on that connection.

`Http2ContinuationSequence` is checked before dispatching each complete frame.
It rejects orphan CONTINUATION frames, stream changes, interleaved frames while
a header block is open, and client-sent PUSH_PROMISE frames.
WINDOW_UPDATE parsing accepts connection or stream IDs, masks the reserved bit,
rejects zero increments, and applies the increment to the selected send window.
DATA frame validation exposes the unpadded payload range and END_STREAM flag,
and rejects connection-stream use, length mismatches, and invalid padding.
A per-request body collector appends only that unpadded range, stops at
END_STREAM, and enforces its configured byte limit.
PING validation can generate an exact opaque-data ACK, RST_STREAM exposes the
stream and error code, and GOAWAY parsing and encoding preserve the last-stream
limit and error code.
Decoded HPACK fields are validated for pseudo-header ordering and uniqueness,
lowercase regular names, forbidden connection-specific fields, `TE: trailers`,
and matching Host/authority before conversion to the shared `Request` type.
Trailing header blocks are decoded separately and reject pseudo-headers and
fields that affect framing or routing.
Per-stream request assembly applies the stream half-close rules while attaching
validated request headers, bounded body bytes, and separate trailers.
`Http2RequestSession` owns the connection input, one header decoder, and the
bounded in-progress request streams; each call yields at most one completed
shared `Request` and leaves later coalesced frames for the next call.
The response adapter emits `:status`, lowercases regular names, rejects
connection-specific fields, and derives Content-Length from the buffered body.
Outbound header blocks are split into HEADERS and CONTINUATION frames, and
buffered bodies into DATA frames, under peer frame-size and total wire-byte caps.
The shared response encoder composes header adaptation, connection-owned HPACK
compression, and frame generation; output failure after compression makes that
deflater terminal because the peer did not receive its updated table state.

## Response trailers

When `ResponseWriter.trailers` carries at least one entry on a body-capable
status, the server emits DATA frames without END_STREAM and finishes the
stream with a trailer HEADERS block (plus CONTINUATION frames when needed)
that carries END_STREAM. HEAD responses and statuses that cannot carry a
body (1xx/204/205/304) silently drop trailers before encoding. The trailer
field list rejects HTTP/1-specific hop-by-hop names and `TE` the same way
response headers do.

Trailer HPACK encoding uses Literal Header Field Never Indexed
(`NGHTTP2_NV_FLAG_NO_INDEX`) for every field. Response HEADERS are encoded
at enqueue time because the scheduler owns the HPACK deflater, so trailer
frames would otherwise need to be interleaved with other streams'
dynamic-table-mutating HEADERS. "Never Indexed" trailer entries do not
insert into either peer's dynamic table, so a trailer block encoded now and
flushed later cannot desynchronize decode order against any other stream's
response HEADERS. Trailer wire bytes are reserved against the shared
response budget on enqueue and released when the stream completes.

The response scheduler sends trailers only after the last DATA chunk leaves
the per-stream send window, so flow-blocked streams keep the trailer section
behind the final DATA frame. A client RST_STREAM before headers have been
flushed clears the pending trailer bytes along with the body; after the
headers block has been flushed, the whole entry (headers + body + trailers)
is dropped on the subsequent reset notification.

## Integrated flow control and response scheduling

The server tracks connection and stream send windows independently and applies
stream `WINDOW_UPDATE` and `SETTINGS_INITIAL_WINDOW_SIZE` changes. It buffers
responses until the peer grants enough credit, then rotates among writable
streams while continuing to read incoming connection frames. RST_STREAM cancels
the corresponding queued response and releases its buffer reservation.

TLS integration tests send requests on two streams before reading either
response, verify that each response stays on its stream, and exercise a stream
whose initial send window is zero before later granting credit. Unit tests cover
round-robin DATA scheduling, bounded payloads, header-once behavior, completion,
credit exhaustion, resumption, and reset cancellation.

Stream admission counts request streams until their response finishes. When the
local cap is reached, the server advances the client stream ID and sends
`RST_STREAM(REFUSED_STREAM)` for that stream while keeping admitted streams and
the connection usable. DATA that races with the refusal is ignored for that
closed stream.

When shutdown begins, the server sends GOAWAY with the highest admitted peer
stream ID and refuses later streams with `REFUSED_STREAM`. GOAWAY is queued
behind existing connection output, and admitted requests keep the configured
shutdown grace period to finish. At the grace deadline, remaining TCP
connections are closed.

## Verification sequence

The frame parser slice uses wire fixtures for incomplete headers and payloads,
maximum and oversized payload lengths, ignored reserved stream bits, unknown
frame types, and multiple concatenated frames. The client preface parser tests
every incomplete prefix, mismatch rejection, and the consumed byte count.
Independent TLS client tests verify response completion and the GOAWAY boundary
during graceful HTTP/2 shutdown.
