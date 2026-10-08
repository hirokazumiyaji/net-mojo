"""Fairly schedules queued HTTP/2 response bodies across streams.

HEADERS are HPACK-encoded lazily, at the moment the scheduler is about to
emit them. Encoding and wire emission happen atomically in the same drain
step, so encode order equals wire order on the single connection deflater
and streams cancelled before their HEADERS reach the wire never touch the
dynamic table.
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
    var max_header_list_size: Int
    var max_header_fields: Int
    var compressed_capacity: Int
    var headers_sent: Bool
    var body: List[Byte]
    var body_offset: Int
    var end_on_headers: Bool
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
        end_on_headers: Bool = False,
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
        var response = _PendingHttp2Response(
            stream_id=stream_id,
            header_fields=header_fields^,
            header_field_count=header_field_count,
            max_header_list_size=max_header_list_size,
            max_header_fields=max_header_fields,
            compressed_capacity=compressed_capacity,
            headers_sent=False,
            body=body^,
            body_offset=0,
            end_on_headers=end_on_headers,
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
        var released = len(self._responses[index].header_fields) + len(
            self._responses[index].body
        )
        self._remove(index)
        return released

    def on_peer_reset(mut self, stream_id: UInt32) -> Http2PeerResetResult:
        # Encode and emission are atomic in `drain`, so a pending entry is
        # either not-yet-emitted (headers_sent=False, deflater untouched)
        # or already-emitted (headers_sent=True, HPACK dynamic table has
        # the stream's fields). Not-yet-emitted means no frame has reached
        # the wire for this stream: drop the entry with no HPACK or
        # protocol consequence. After emission we clear the body so drain
        # finishes the stream with a server-sent RST_STREAM(CANCEL).
        var index = self._find(stream_id)
        if index < 0:
            return Http2PeerResetResult(released_bytes=0, kept_headers=False)
        if not self._responses[index].headers_sent:
            var released = len(self._responses[index].header_fields) + len(
                self._responses[index].body
            )
            self._remove(index)
            return Http2PeerResetResult(
                released_bytes=released, kept_headers=False
            )
        var body_bytes = len(self._responses[index].body) - (
            self._responses[index].body_offset
        )
        self._responses[index].body = List[Byte]()
        self._responses[index].body_offset = 0
        self._responses[index].cancelled = True
        return Http2PeerResetResult(
            released_bytes=body_bytes, kept_headers=True
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
                    released += len(self._responses[index].header_fields) + len(
                        self._responses[index].body
                    )
                    self._remove(index)
                    continue
                var capacity = self._responses[index].compressed_capacity
                var worst_frames = (
                    capacity + max_frame_size - 1
                ) // max_frame_size
                if worst_frames < 1:
                    worst_frames = 1
                var upper_bound = capacity + worst_frames * 9
                if max_output_bytes - len(output) < upper_bound:
                    break
                var emit_result = self._encode_and_emit_headers(
                    index, deflater, date, max_frame_size, output
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
                    released += len(self._responses[index].header_fields) + len(
                        self._responses[index].body
                    )
                    self._remove(index)
                    skipped = 0
                    continue
                self._responses[index].headers_sent = True
                skipped = 0
                if len(self._responses[index].body) == 0 and (
                    not self._responses[index].cancelled
                ):
                    session.finish_response(stream_id)
                    completed.append(stream_id)
                    released += len(self._responses[index].header_fields)
                    self._remove(index)
                    continue

            if self._responses[index].cancelled:
                if not self._responses[index].end_on_headers:
                    var rst = encode_rst_stream_frame(stream_id, UInt32(8))
                    if not rst.is_complete() or len(rst.wire) > (
                        max_output_bytes - len(output)
                    ):
                        break
                    output.extend(Span(rst.wire))
                session.finish_response(stream_id)
                completed.append(stream_id)
                released += len(self._responses[index].header_fields)
                self._remove(index)
                continue

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
                remaining_body, min(max_frame_size, min(credit, output_room))
            )
            var end_stream = payload_length == remaining_body
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
                released += len(self._responses[index].header_fields) + len(
                    self._responses[index].body
                )
                self._remove(index)
            elif len(self._responses) > 0:
                self._next_index = (index + 1) % len(self._responses)

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
            self._responses[index].end_on_headers = True
            self._responses[index].body = List[Byte]()
            self._responses[index].body_offset = 0
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
            self._responses[index].end_on_headers,
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
