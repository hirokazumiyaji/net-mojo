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
