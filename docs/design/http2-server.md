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

The SETTINGS payload codec reads and writes six-byte identifier/value entries
in network byte order. Parsing rejects a trailing partial entry and preserves
unknown identifiers unchanged; connection-level validation, duplicate handling,
and negotiation remain with the connection state machine.

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
The cap is independent of the peer's `SETTINGS_MAX_CONCURRENT_STREAMS`, which
limits streams initiated by this server.

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
compression errors as terminal for that decoder.

`Http2FlowWindow` tracks send and receive credit separately for a connection
or stream. DATA debits the corresponding window, and receive credit can be
restored only for bytes the application has consumed. The debit includes the
full DATA payload, including padding. SETTINGS initial-window changes adjust
stream send windows; the connection send window remains fixed.

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
The response adapter emits `:status`, lowercases regular names, rejects
connection-specific fields, and derives Content-Length from the buffered body.
Outbound header blocks are split into HEADERS and CONTINUATION frames, and
buffered bodies into DATA frames, under peer frame-size and total wire-byte caps.

## Follow-up connection work

The connection layer will require the client connection preface, send server
SETTINGS, validate frame sequencing and type-specific constraints, and map
connection errors separately from stream errors. A bounded stream table and
HPACK decoder will enforce concurrent stream, decoded header, and dynamic
table limits before requests reach the shared handler.

Connection and stream flow-control windows are tracked independently. DATA
consumption returns receive credit even while the bounded buffered handler is
reading a body larger than the initial window. The writer schedules control
frames promptly and rotates among writable streams so a stalled stream cannot
block connection reads or unrelated responses. RST_STREAM, GOAWAY, and drain
operate on stream or connection state as specified by RFC 9113.

## Verification sequence

The frame parser slice uses wire fixtures for incomplete headers and payloads,
maximum and oversized payload lengths, ignored reserved stream bits, unknown
frame types, and multiple concatenated frames. The client preface parser tests
every incomplete prefix, mismatch rejection, and the consumed byte count. Later
connection PRs add protocol state, flow-control, shutdown, and independent-client
interoperability tests.
