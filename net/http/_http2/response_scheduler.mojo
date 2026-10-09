"""Fairly schedules queued HTTP/2 response bodies across streams.

HEADERS are HPACK-encoded lazily, at the moment the scheduler is about to
emit them. Encoding and wire emission happen atomically in the same drain
step, so encode order equals wire order on the single connection deflater
and streams cancelled before their HEADERS reach the wire never touch the
dynamic table. Trailers are hand-encoded as literal never-indexed (no
dynamic table insertion) by the enqueue site and emitted as a separate
HEADERS block with END_STREAM after the body.
"""

from .control_frames import encode_rst_stream_frame
from .frame_encoder import encode_frame
from .hpack import Http2HpackDeflater
from .request_session import Http2RequestSession
from .response_frames import encode_headers_block
from .response_headers import (
    Http2ResponseHeadersResult,
    encode_http2_minimal_500_fields,
)


comptime _EMIT_OK: Int = 0
comptime _EMIT_DEFLATER_FAILED: Int = 1
comptime _EMIT_RST: Int = 2


@fieldwise_init
struct _PendingHttp2Response(Movable):
    var stream_id: UInt32
    var header_fields: List[Byte]
    var header_field_count: Int
    var reserved_header_bytes: Int
    var reserved_body_bytes: Int
    var reserved_trailer_bytes: Int
    var max_header_list_size: Int
    var max_header_fields: Int
    var compressed_capacity: Int
    var headers_sent: Bool
    var body: List[Byte]
    var body_offset: Int
    var trailers: List[Byte]
    var trailer_field_count: Int
    var trailers_offset: Int
    var trailers_sent: Bool
    var cancelled: Bool


@fieldwise_init
struct Http2ScheduledOutput(Movable):
    var wire: List[Byte]
    var completed_streams: List[UInt32]
    var released_bytes: Int
    var deflater_failed: Bool


@fieldwise_init
struct Http2PeerResetResult(Movable):
    var released_bytes: Int
    var kept_headers: Bool


struct Http2ResponseScheduler(Movable):
    var _responses: List[_PendingHttp2Response]
    var _next_index: Int

    def __init__(out self):
        self._responses = List[_PendingHttp2Response]()
        self._next_index = 0

    def enqueue(
        mut self,
        stream_id: UInt32,
        var header_fields: List[Byte],
        header_field_count: Int,
        max_header_list_size: Int,
        max_header_fields: Int,
        compressed_capacity: Int,
        var body: List[Byte],
        var trailers: List[Byte] = List[Byte](),
        trailer_field_count: Int = 0,
    ) -> Bool:
        if stream_id == UInt32(0) or header_field_count <= 0:
            return False
        if max_header_list_size < 0 or max_header_fields < 1:
            return False
        if compressed_capacity < 1:
            return False
        for i in range(len(self._responses)):
            if self._responses[i].stream_id == stream_id:
                return False
        var reserved_header_bytes = len(header_fields)
        var reserved_body_bytes = len(body)
        var reserved_trailer_bytes = len(trailers)
        var response = _PendingHttp2Response(
            stream_id=stream_id,
            header_fields=header_fields^,
            header_field_count=header_field_count,
            reserved_header_bytes=reserved_header_bytes,
            reserved_body_bytes=reserved_body_bytes,
            reserved_trailer_bytes=reserved_trailer_bytes,
            max_header_list_size=max_header_list_size,
            max_header_fields=max_header_fields,
            compressed_capacity=compressed_capacity,
            headers_sent=False,
            body=body^,
            body_offset=0,
            trailers=trailers^,
            trailer_field_count=trailer_field_count,
            trailers_offset=0,
            trailers_sent=False,
            cancelled=False,
        )
        self._responses.append(response^)
        return True

    def queued_count(self) -> Int:
        return len(self._responses)

    def cancel(mut self, stream_id: UInt32) -> Int:
        var index = self._find(stream_id)
        if index < 0:
            return 0
        var released = (
            self._responses[index].reserved_header_bytes
            + self._responses[index].reserved_body_bytes
            + self._responses[index].reserved_trailer_bytes
        )
        self._remove(index)
        return released

    def on_peer_reset(mut self, stream_id: UInt32) -> Http2PeerResetResult:
        # Encode and HEADERS emission are atomic in `drain`, so a pending
        # entry is either not-yet-emitted (headers_sent=False, deflater
        # untouched) or already-emitted (headers_sent=True, the stream's
        # fields are in the HPACK dynamic table). Not-yet-emitted means no
        # frame has reached the wire: drop with no HPACK or protocol
        # consequence. After emission we clear the body and trailers so
        # drain finishes with a server-sent RST_STREAM(CANCEL).
        var index = self._find(stream_id)
        if index < 0:
            return Http2PeerResetResult(released_bytes=0, kept_headers=False)
        if not self._responses[index].headers_sent:
            var released = (
                self._responses[index].reserved_header_bytes
                + self._responses[index].reserved_body_bytes
                + self._responses[index].reserved_trailer_bytes
            )
            self._remove(index)
            return Http2PeerResetResult(
                released_bytes=released, kept_headers=False
            )
        var body_bytes = self._responses[index].reserved_body_bytes
        var trailer_bytes = self._responses[index].reserved_trailer_bytes
        self._responses[index].body = List[Byte]()
        self._responses[index].body_offset = 0
        self._responses[index].reserved_body_bytes = 0
        self._responses[index].trailers = List[Byte]()
        self._responses[index].trailers_offset = 0
        self._responses[index].reserved_trailer_bytes = 0
        self._responses[index].cancelled = True
        return Http2PeerResetResult(
            released_bytes=body_bytes + trailer_bytes, kept_headers=True
        )

    def has_unsent_headers(self, stream_id: UInt32) -> Bool:
        var index = self._find(stream_id)
        if index < 0:
            return False
        return not self._responses[index].headers_sent

    def drain(
        mut self,
        mut session: Http2RequestSession,
        mut deflater: Http2HpackDeflater,
        date: StringSlice,
        max_frame_size: Int,
        max_output_bytes: Int,
    ) -> Http2ScheduledOutput:
        var output = List[Byte]()
        var completed = List[UInt32]()
        var released = 0
        if max_frame_size < 1 or max_output_bytes < 9:
            return Http2ScheduledOutput(
                wire=output^,
                completed_streams=completed^,
                released_bytes=0,
                deflater_failed=False,
            )

        var skipped = 0
        while len(self._responses) > 0:
            if self._next_index >= len(self._responses):
                self._next_index = 0
            var index = self._next_index
            var stream_id = self._responses[index].stream_id

            if not self._responses[index].headers_sent:
                if self._responses[index].cancelled:
                    released += (
                        self._responses[index].reserved_header_bytes
                        + self._responses[index].reserved_body_bytes
                        + self._responses[index].reserved_trailer_bytes
                    )
                    self._remove(index)
                    continue
                # True upper bound on the compressed block matching
                # nghttp2_hd_deflate_bound = sum(name+value+32) + 128.
                # The queued buffer carries 8 bytes of (name_len,
                # value_len) overhead per field, so add 24 bytes per
                # field plus 128 bytes head room for a dynamic-table-
                # size-update prefix (RFC 7541 §4.2) and nghttp2 slack.
                # Cap by `compressed_capacity` so the gate never asks
                # for more than the deflater can actually emit. The
                # bound tracks nghttp2_hd_deflate_bound (sum(name_len +
                # value_len + 32)); the queued buffer carries 8 bytes
                # of overhead per field already, so adding 24 bytes per
                # field reaches the native upper bound without the old
                # 128-byte slack that could push a valid response above
                # the drain batch.
                var raw_len = len(self._responses[index].header_fields)
                var hpack_bound = (
                    raw_len + 24 * self._responses[index].header_field_count
                )
                if hpack_bound > self._responses[index].compressed_capacity:
                    hpack_bound = self._responses[index].compressed_capacity
                var worst_frames = (
                    hpack_bound + max_frame_size - 1
                ) // max_frame_size
                if worst_frames < 1:
                    worst_frames = 1
                var upper_bound = hpack_bound + worst_frames * 9
                if max_output_bytes - len(output) < upper_bound:
                    # The response is admitted but its atomic drain
                    # bound exceeds this batch outright, so the drain
                    # loop would stall it forever. Rewrite it to the
                    # minimal 500 so _encode_and_emit_headers finishes
                    # the stream and sibling responses can progress.
                    if upper_bound > max_output_bytes:
                        var minimal = encode_http2_minimal_500_fields(
                            date,
                            self._responses[index].max_header_list_size,
                            self._responses[index].max_header_fields,
                        )
                        if not minimal.is_valid():
                            var rst = encode_rst_stream_frame(
                                stream_id, UInt32(2)
                            )
                            if not rst.is_complete() or len(rst.wire) > (
                                max_output_bytes - len(output)
                            ):
                                break
                            output.extend(Span(rst.wire))
                            session.finish_response(stream_id)
                            completed.append(stream_id)
                            released += (
                                self._responses[index].reserved_header_bytes
                                + self._responses[index].reserved_body_bytes
                                + self._responses[index].reserved_trailer_bytes
                            )
                            self._remove(index)
                            skipped = 0
                            continue
                        # Validate the fallback itself fits this batch
                        # before swapping it in. If even the minimal 500
                        # does not fit, RST and remove the stream
                        # instead of looping on the gate.
                        var fallback_raw = len(minimal.fields)
                        var fallback_bound = (
                            fallback_raw + 24 * minimal.field_count + 128
                        )
                        if (
                            fallback_bound
                            > self._responses[index].compressed_capacity
                        ):
                            fallback_bound = self._responses[
                                index
                            ].compressed_capacity
                        var fallback_worst_frames = (
                            fallback_bound + max_frame_size - 1
                        ) // max_frame_size
                        if fallback_worst_frames < 1:
                            fallback_worst_frames = 1
                        var fallback_bound_full = (
                            fallback_bound + fallback_worst_frames * 9
                        )
                        if max_output_bytes - len(output) < fallback_bound_full:
                            if fallback_bound_full > max_output_bytes:
                                # Even an empty batch cannot hold this
                                # fallback; RST and remove.
                                var rst = encode_rst_stream_frame(
                                    stream_id, UInt32(2)
                                )
                                if not rst.is_complete() or len(rst.wire) > (
                                    max_output_bytes - len(output)
                                ):
                                    break
                                output.extend(Span(rst.wire))
                                session.finish_response(stream_id)
                                completed.append(stream_id)
                                released += (
                                    self._responses[index].reserved_header_bytes
                                    + self._responses[index].reserved_body_bytes
                                    + self._responses[
                                        index
                                    ].reserved_trailer_bytes
                                )
                                self._remove(index)
                                skipped = 0
                                continue
                            # Only this batch is tight; wait for the next
                            # drain batch to retry the fallback.
                            break
                        self._responses[index].header_fields = minimal.fields^
                        minimal.fields = List[Byte]()
                        self._responses[
                            index
                        ].header_field_count = minimal.field_count
                        self._responses[index].body = List[Byte]()
                        self._responses[index].body_offset = 0
                        # The minimal 500 belongs to a different response
                        # than the handler built. Drop any queued
                        # trailers so metadata describing the discarded
                        # body (digests, timings) is not emitted here.
                        self._responses[index].trailers = List[Byte]()
                        self._responses[index].trailers_offset = 0
                        self._responses[index].trailer_field_count = 0
                        # The minimal 500 carries no body and no
                        # trailers; the drain's post-emit end_on_headers
                        # re-derivation (len(body) == 0 and
                        # len(trailers) == 0) therefore closes the
                        # stream on its HEADERS frame.
                        # Fall through to the usual gate on the shrunk
                        # response so the atomic emit path handles it.
                        continue
                    break
                var end_on_headers = (
                    len(self._responses[index].body) == 0
                    and len(self._responses[index].trailers) == 0
                )
                var emit_result = self._encode_and_emit_headers(
                    index,
                    deflater,
                    date,
                    max_frame_size,
                    end_on_headers,
                    output,
                )
                if emit_result == _EMIT_DEFLATER_FAILED:
                    return Http2ScheduledOutput(
                        wire=output^,
                        completed_streams=completed^,
                        released_bytes=released,
                        deflater_failed=True,
                    )
                if emit_result == _EMIT_RST:
                    var rst = encode_rst_stream_frame(stream_id, UInt32(2))
                    if not rst.is_complete() or len(rst.wire) > (
                        max_output_bytes - len(output)
                    ):
                        break
                    output.extend(Span(rst.wire))
                    session.finish_response(stream_id)
                    completed.append(stream_id)
                    released += (
                        self._responses[index].reserved_header_bytes
                        + self._responses[index].reserved_body_bytes
                        + self._responses[index].reserved_trailer_bytes
                    )
                    self._remove(index)
                    skipped = 0
                    continue
                self._responses[index].headers_sent = True
                # Release the raw field block reservation and buffer:
                # the compressed HEADERS are already in the drain's
                # output, so the server owes no further pending bytes
                # for this response's HEADERS.
                var released_header_bytes = self._responses[
                    index
                ].reserved_header_bytes
                released += released_header_bytes
                self._responses[index].reserved_header_bytes = 0
                self._responses[index].header_fields = List[Byte]()
                skipped = 0
                # Re-derive end_on_headers after emission: a fallback inside
                # _encode_and_emit_headers may have cleared body and trailers
                # to make the HEADERS frame close the stream.
                var effective_end = (
                    len(self._responses[index].body) == 0
                    and len(self._responses[index].trailers) == 0
                )
                if effective_end and not self._responses[index].cancelled:
                    session.finish_response(stream_id)
                    completed.append(stream_id)
                    released += (
                        self._responses[index].reserved_body_bytes
                        + self._responses[index].reserved_trailer_bytes
                    )
                    self._remove(index)
                    continue

            if self._responses[index].cancelled:
                # Peer already sent RST_STREAM: RFC 9113 §5.4.2 forbids
                # replying with another RST_STREAM. Any HEADERS already
                # on the wire keep the HPACK dynamic table in sync; the
                # queued DATA is dropped by discarding the entry.
                session.finish_response(stream_id)
                completed.append(stream_id)
                released += (
                    self._responses[index].reserved_header_bytes
                    + self._responses[index].reserved_body_bytes
                    + self._responses[index].reserved_trailer_bytes
                )
                self._remove(index)
                continue

            var body_done = self._responses[index].body_offset == len(
                self._responses[index].body
            )

            if not body_done:
                var remaining_body = len(self._responses[index].body) - (
                    self._responses[index].body_offset
                )
                var credit = session.send_window(stream_id)
                var output_room = max_output_bytes - len(output) - 9
                if credit <= 0 or output_room <= 0:
                    self._next_index = (index + 1) % len(self._responses)
                    skipped += 1
                    if skipped >= len(self._responses):
                        break
                    continue

                var payload_length = min(
                    remaining_body,
                    min(max_frame_size, min(credit, output_room)),
                )
                var end_stream = payload_length == remaining_body and (
                    len(self._responses[index].trailers) == 0
                )
                var flags = Byte(1) if end_stream else Byte(0)
                var frame = encode_frame(
                    Byte(0),
                    flags,
                    stream_id,
                    Span(self._responses[index].body)[
                        self._responses[index]
                        .body_offset : self._responses[index]
                        .body_offset
                        + payload_length
                    ],
                    max_frame_size,
                )
                if not frame.is_complete() or not session.consume_outbound(
                    stream_id, payload_length
                ):
                    self._next_index = (index + 1) % len(self._responses)
                    skipped += 1
                    if skipped >= len(self._responses):
                        break
                    continue
                output.extend(Span(frame.wire))
                self._responses[index].body_offset += payload_length
                skipped = 0
                if end_stream:
                    session.finish_response(stream_id)
                    completed.append(stream_id)
                    released += (
                        self._responses[index].reserved_header_bytes
                        + self._responses[index].reserved_body_bytes
                        + self._responses[index].reserved_trailer_bytes
                    )
                    self._remove(index)
                    continue
                body_done = self._responses[index].body_offset == len(
                    self._responses[index].body
                )
                if not body_done or len(self._responses[index].trailers) == 0:
                    if len(self._responses) > 0:
                        self._next_index = (index + 1) % len(self._responses)
                    continue

            if body_done and len(self._responses[index].trailers) > 0:
                # Encode the trailer header block through the deflater at
                # emission time: any pending dynamic-table-size update
                # (RFC 7541 §4.2) that followed a peer SETTINGS change
                # prefixes the trailer block, and the HPACK dynamic-table
                # state matches what the inflater will see because no
                # other block runs between encode and send on the single
                # connection deflater. The whole HEADERS + CONTINUATION
                # chain is also written to `output` atomically so later
                # control frames (PING/SETTINGS ACK, RST, other streams)
                # cannot interleave inside the block (RFC 9113 §6.10).
                ref trailer_fields = self._responses[index].trailers
                var trailer_count = self._responses[index].trailer_field_count
                var trailer_max_hls = self._responses[
                    index
                ].max_header_list_size
                var trailer_max_fields = self._responses[
                    index
                ].max_header_fields
                # nghttp2_hd_deflate_bound = sum(name+value+32) + 128.
                # Add 32 bytes to cover a dynamic-table-size-update prefix
                # (RFC 7541 §4.2) that nghttp2 may emit after a peer
                # SETTINGS change (10-byte varint worst case).
                var trailer_bound = (
                    len(trailer_fields) + 32 * trailer_count + 160
                )
                # Gate on the worst-case wire bound BEFORE calling the
                # stateful deflater: deflater.encode mutates the shared
                # dynamic table, so a deferred emission from a tight
                # drain would make the next drain re-encode against
                # entries the peer never received.
                var trailer_worst_frames = (
                    trailer_bound + max_frame_size - 1
                ) // max_frame_size
                if trailer_worst_frames < 1:
                    trailer_worst_frames = 1
                var trailer_worst_bound = (
                    trailer_bound + trailer_worst_frames * 9
                )
                if max_output_bytes - len(output) < trailer_worst_bound:
                    if trailer_worst_bound > max_output_bytes:
                        # Trailer block larger than any drain batch:
                        # finish the stream with RST(INTERNAL_ERROR)
                        # instead of deferring forever and starving
                        # queued sibling responses.
                        var rst = encode_rst_stream_frame(stream_id, UInt32(2))
                        if not rst.is_complete() or len(rst.wire) > (
                            max_output_bytes - len(output)
                        ):
                            break
                        output.extend(Span(rst.wire))
                        session.finish_response(stream_id)
                        completed.append(stream_id)
                        released += (
                            self._responses[index].reserved_header_bytes
                            + self._responses[index].reserved_body_bytes
                            + self._responses[index].reserved_trailer_bytes
                        )
                        self._remove(index)
                        skipped = 0
                        continue
                    break
                var trailer_compressed = List[Byte](
                    length=trailer_bound, fill=0
                )
                var trailer_encode = deflater.encode(
                    Span(trailer_fields),
                    trailer_max_hls,
                    trailer_max_fields,
                    Span(trailer_compressed),
                )
                if trailer_encode.is_invalid():
                    return Http2ScheduledOutput(
                        wire=output^,
                        completed_streams=completed^,
                        released_bytes=released,
                        deflater_failed=True,
                    )
                if trailer_encode.is_too_large():
                    var rst = encode_rst_stream_frame(stream_id, UInt32(2))
                    if not rst.is_complete() or len(rst.wire) > (
                        max_output_bytes - len(output)
                    ):
                        break
                    output.extend(Span(rst.wire))
                    session.finish_response(stream_id)
                    completed.append(stream_id)
                    released += (
                        self._responses[index].reserved_header_bytes
                        + self._responses[index].reserved_body_bytes
                        + self._responses[index].reserved_trailer_bytes
                    )
                    self._remove(index)
                    skipped = 0
                    continue
                var trailer_compressed_len = trailer_encode.output_length
                var trailer_frame_count = (
                    trailer_compressed_len + max_frame_size - 1
                ) // max_frame_size
                if trailer_frame_count < 1:
                    trailer_frame_count = 1
                var trailer_wire_bound = (
                    trailer_compressed_len + trailer_frame_count * 9
                )
                if max_output_bytes - len(output) < trailer_wire_bound:
                    # Full block does not fit this drain; wait for the
                    # next one. `trailer_count` and the fields buffer stay
                    # intact so the next drain repeats this encode.
                    break
                var trailer_frames = encode_headers_block(
                    stream_id,
                    Span(trailer_compressed)[0:trailer_compressed_len],
                    True,
                    max_frame_size,
                    trailer_wire_bound,
                )
                if not trailer_frames.is_complete():
                    deflater.fail()
                    return Http2ScheduledOutput(
                        wire=output^,
                        completed_streams=completed^,
                        released_bytes=released,
                        deflater_failed=True,
                    )
                _ = trailer_count
                output.extend(Span(trailer_frames.wire))
                self._responses[index].trailers_offset = len(trailer_fields)
                skipped = 0
                self._responses[index].trailers_sent = True
                session.finish_response(stream_id)
                completed.append(stream_id)
                released += (
                    self._responses[index].reserved_header_bytes
                    + self._responses[index].reserved_body_bytes
                    + self._responses[index].reserved_trailer_bytes
                )
                self._remove(index)
                continue

        return Http2ScheduledOutput(
            wire=output^,
            completed_streams=completed^,
            released_bytes=released,
            deflater_failed=False,
        )

    def _encode_and_emit_headers(
        mut self,
        index: Int,
        mut deflater: Http2HpackDeflater,
        date: StringSlice,
        max_frame_size: Int,
        end_on_headers: Bool,
        mut output: List[Byte],
    ) -> Int:
        var capacity = self._responses[index].compressed_capacity
        var max_hls = self._responses[index].max_header_list_size
        var max_fields = self._responses[index].max_header_fields
        var compressed = List[Byte](length=capacity, fill=0)
        var attempt = deflater.encode(
            Span(self._responses[index].header_fields),
            max_hls,
            max_fields,
            Span(compressed),
        )
        if attempt.is_invalid():
            return _EMIT_DEFLATER_FAILED
        var effective_end_on_headers = end_on_headers
        if attempt.is_too_large():
            var fallback = encode_http2_minimal_500_fields(
                date, max_hls, max_fields
            )
            if not fallback.is_valid():
                return _EMIT_RST
            var retry_fields = fallback.fields^
            fallback.fields = List[Byte]()
            var retry_count = fallback.field_count
            var retry = deflater.encode(
                Span(retry_fields),
                max_hls,
                max_fields,
                Span(compressed),
            )
            if retry.is_invalid():
                return _EMIT_DEFLATER_FAILED
            if retry.is_too_large():
                return _EMIT_RST
            self._responses[index].header_fields = retry_fields^
            self._responses[index].header_field_count = retry_count
            # Preserve the server's original reservation so release() refunds
            # the full budget it charged; the fallback is strictly smaller.
            effective_end_on_headers = True
            self._responses[index].body = List[Byte]()
            self._responses[index].body_offset = 0
            self._responses[index].trailers = List[Byte]()
            self._responses[index].trailers_offset = 0
            attempt = retry.copy()
        var compressed_len = attempt.output_length
        var frame_count = (
            compressed_len + max_frame_size - 1
        ) // max_frame_size
        if frame_count < 1:
            frame_count = 1
        var wire_bound = compressed_len + frame_count * 9
        var frames = encode_headers_block(
            self._responses[index].stream_id,
            Span(compressed)[0:compressed_len],
            effective_end_on_headers,
            max_frame_size,
            wire_bound,
        )
        if not frames.is_complete():
            deflater.fail()
            return _EMIT_DEFLATER_FAILED
        output.extend(Span(frames.wire))
        return _EMIT_OK

    def _find(self, stream_id: UInt32) -> Int:
        for i in range(len(self._responses)):
            if self._responses[i].stream_id == stream_id:
                return i
        return -1

    def _remove(mut self, index: Int):
        var last = self._responses.pop()
        if index < len(self._responses):
            self._responses[index] = last^
        if len(self._responses) == 0:
            self._next_index = 0
        elif self._next_index >= len(self._responses):
            self._next_index = 0
