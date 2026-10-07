"""Fairly schedules queued HTTP/2 response bodies across streams."""

from .control_frames import encode_rst_stream_frame
from .frame_encoder import encode_frame
from .request_session import Http2RequestSession


@fieldwise_init
struct _PendingHttp2Response(Movable):
    var stream_id: UInt32
    var headers: List[Byte]
    var body: List[Byte]
    var body_offset: Int
    var headers_offset: Int
    var headers_sent: Bool
    var end_on_headers: Bool
    var cancelled: Bool


@fieldwise_init
struct Http2ScheduledOutput(Movable):
    var wire: List[Byte]
    var completed_streams: List[UInt32]
    var released_bytes: Int


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
        var headers: List[Byte],
        var body: List[Byte],
        end_on_headers: Bool = False,
    ) -> Bool:
        if stream_id == UInt32(0) or len(headers) == 0:
            return False
        for i in range(len(self._responses)):
            if self._responses[i].stream_id == stream_id:
                return False
        var response = _PendingHttp2Response(
            stream_id=stream_id,
            headers=headers^,
            body=body^,
            body_offset=0,
            headers_offset=0,
            headers_sent=False,
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
        var released = len(self._responses[index].headers) + len(
            self._responses[index].body
        )
        self._remove(index)
        return released

    def on_peer_reset(mut self, stream_id: UInt32) -> Http2PeerResetResult:
        # Dropping the already-HPACK-encoded header block would desync the
        # deflater; keep headers so drain still ships them and release only
        # the body budget here. The body is replaced with an empty list and
        # drain emits RST_STREAM(CANCEL) after headers to close the stream.
        var index = self._find(stream_id)
        if index < 0:
            return Http2PeerResetResult(released_bytes=0, kept_headers=False)
        if not self._responses[index].headers_sent:
            var body_bytes = len(self._responses[index].body)
            self._responses[index].body = List[Byte]()
            self._responses[index].body_offset = 0
            self._responses[index].cancelled = True
            return Http2PeerResetResult(
                released_bytes=body_bytes, kept_headers=True
            )
        var released = len(self._responses[index].headers) + len(
            self._responses[index].body
        )
        self._remove(index)
        return Http2PeerResetResult(released_bytes=released, kept_headers=False)

    def has_unsent_headers(self, stream_id: UInt32) -> Bool:
        var index = self._find(stream_id)
        if index < 0:
            return False
        return not self._responses[index].headers_sent

    def drain(
        mut self,
        mut session: Http2RequestSession,
        max_frame_size: Int,
        max_output_bytes: Int,
    ) -> Http2ScheduledOutput:
        var output = List[Byte]()
        var completed = List[UInt32]()
        var released = 0
        if max_frame_size < 1 or max_output_bytes < 9:
            return Http2ScheduledOutput(
                wire=output^, completed_streams=completed^, released_bytes=0
            )

        var skipped = 0
        while len(self._responses) > 0:
            if self._next_index >= len(self._responses):
                self._next_index = 0
            var index = self._next_index
            var stream_id = self._responses[index].stream_id
            if not self._responses[index].headers_sent:
                var remaining_headers = len(self._responses[index].headers) - (
                    self._responses[index].headers_offset
                )
                var header_room = max_output_bytes - len(output)
                if header_room <= 0:
                    break
                var header_chunk = remaining_headers
                if header_chunk > header_room:
                    header_chunk = header_room
                var start = self._responses[index].headers_offset
                output.extend(
                    Span(self._responses[index].headers)[
                        start : start + header_chunk
                    ]
                )
                self._responses[index].headers_offset = start + header_chunk
                skipped = 0
                if self._responses[index].headers_offset < len(
                    self._responses[index].headers
                ):
                    break
                self._responses[index].headers_sent = True
                if len(self._responses[index].body) == 0 and (
                    not self._responses[index].cancelled
                ):
                    session.finish_response(stream_id)
                    completed.append(stream_id)
                    released += len(self._responses[index].headers)
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
                released += len(self._responses[index].headers)
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
                released += len(self._responses[index].headers) + len(
                    self._responses[index].body
                )
                self._remove(index)
            elif len(self._responses) > 0:
                self._next_index = (index + 1) % len(self._responses)

        return Http2ScheduledOutput(
            wire=output^, completed_streams=completed^, released_bytes=released
        )

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
