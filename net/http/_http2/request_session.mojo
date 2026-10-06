"""Assembles completed HTTP/2 requests for one connection."""

from net import Timeout
from net.http.request import HttpVersion, Request
from net.http._deadline import NO_DEADLINE, deadline_from_now

from .connection_input import (
    Http2ServerConnectionInput,
)
from .control_frames import encode_goaway_frame, encode_rst_stream_frame
from .data_frame import parse_data_frame
from .frame import FrameParseResult
from .frame_encoder import encode_frame
from .flow_window import Http2FlowWindow
from .header_decoder import Http2HeaderDecodeResult, Http2HeaderDecoder
from .request_stream import Http2RequestStream, Http2RequestStreamResult
from .settings_state import Http2PeerSettingsSnapshot


@fieldwise_init
struct Http2RequestSessionResult(Movable):
    var kind: UInt8
    var consumed: Int
    var stream_id: UInt32
    var reset_stream_id: UInt32
    var output: List[Byte]
    var request: Request

    @staticmethod
    def pending(
        consumed: Int,
        var output: List[Byte],
        reset_stream_id: UInt32 = UInt32(0),
    ) -> Self:
        return Self(
            kind=1,
            consumed=consumed,
            stream_id=UInt32(0),
            reset_stream_id=reset_stream_id,
            output=output^,
            request=Request(
                String(), String(), String(), String(), HttpVersion.http2()
            ),
        )

    @staticmethod
    def complete(
        consumed: Int,
        stream_id: UInt32,
        var output: List[Byte],
        var request: Request,
    ) -> Self:
        return Self(
            kind=2,
            consumed=consumed,
            stream_id=stream_id,
            reset_stream_id=UInt32(0),
            output=output^,
            request=request^,
        )

    @staticmethod
    def error(consumed: Int, var output: List[Byte]) -> Self:
        return Self(
            kind=3,
            consumed=consumed,
            stream_id=UInt32(0),
            reset_stream_id=UInt32(0),
            output=output^,
            request=Request(
                String(), String(), String(), String(), HttpVersion.http2()
            ),
        )

    def is_pending(self) -> Bool:
        return self.kind == 1

    def is_request(self) -> Bool:
        return self.kind == 2

    def is_error(self) -> Bool:
        return self.kind == 3

    def take_request(deinit self) -> Request:
        return self.request^


@fieldwise_init
struct _Http2RequestEntry(Movable):
    var stream_id: UInt32
    var stream: Http2RequestStream
    var receive_window: Http2FlowWindow
    var body_at: Int

    def take_request(deinit self) -> Request:
        return self.stream^.take_request()


@fieldwise_init
struct _Http2SendWindowEntry(Movable):
    var stream_id: UInt32
    var window: Http2FlowWindow


struct Http2RequestSession(Movable):
    var _input: Http2ServerConnectionInput
    var _decoder: Optional[Http2HeaderDecoder]
    var _library_path: String
    var _header_output: List[Byte]
    var _streams: List[_Http2RequestEntry]
    var _send_streams: List[_Http2SendWindowEntry]
    var _receive_window: Http2FlowWindow
    var _send_window: Http2FlowWindow
    var _max_active_streams: Int
    var _max_body_size: Int
    var _max_headers_bytes: Int
    var _max_headers_count: Int
    var _max_trailer_bytes: Int
    var _max_trailer_count: Int
    var _header_deadline: Timeout
    var _body_deadline: Timeout
    var _pending_headers_at: Int
    var _last_stream_id: UInt32
    var _draining: Bool
    var _failed: Bool

    def __init__(
        out self,
        var library_path: String,
        max_active_streams: Int,
        max_body_size: Int,
        max_headers_bytes: Int = 32768,
        max_headers_count: Int = 100,
        max_trailer_bytes: Int = 8192,
        max_trailer_count: Int = 32,
        header_deadline: Timeout = Timeout.nanoseconds(5_000_000_000),
        body_deadline: Timeout = Timeout.nanoseconds(30_000_000_000),
        max_control_frames_per_second: Int = 1000,
        max_resets_per_second: Int = 100,
        max_new_streams_per_second: Int = 1000000,
    ):
        self._input = Http2ServerConnectionInput(
            max_concurrent_streams=max_active_streams,
            max_control_frames_per_second=max_control_frames_per_second,
            max_resets_per_second=max_resets_per_second,
            max_new_streams_per_second=max_new_streams_per_second,
        )
        self._decoder = None
        self._library_path = library_path^
        var output_capacity = max_headers_bytes
        if max_trailer_bytes > output_capacity:
            output_capacity = max_trailer_bytes
        output_capacity += max_headers_count * 8
        if output_capacity < 1024:
            output_capacity = 1024
        self._header_output = List[Byte](length=output_capacity, fill=0)
        self._streams = List[_Http2RequestEntry]()
        self._send_streams = List[_Http2SendWindowEntry]()
        self._receive_window = Http2FlowWindow(65535, 65535)
        self._send_window = Http2FlowWindow(65535, 65535)
        self._max_active_streams = max_active_streams
        self._max_body_size = max_body_size
        self._max_headers_bytes = max_headers_bytes
        self._max_headers_count = max_headers_count
        self._max_trailer_bytes = max_trailer_bytes
        self._max_trailer_count = max_trailer_count
        self._header_deadline = header_deadline.copy()
        self._body_deadline = body_deadline.copy()
        self._pending_headers_at = NO_DEADLINE
        self._last_stream_id = UInt32(0)
        self._draining = False
        self._failed = (
            max_active_streams < 0
            or max_body_size < 0
            or max_headers_bytes < 0
            or max_headers_count < 0
            or max_trailer_bytes < 0
            or max_trailer_count < 0
        )

    def begin_shutdown(mut self) -> List[Byte]:
        if self._draining:
            return List[Byte]()
        self._draining = True
        var goaway = encode_goaway_frame(self._last_stream_id, UInt32(0))
        var output = List[Byte]()
        _append_session_output(output, Span(goaway.wire))
        return output^

    def next_deadline(self) -> Int:
        var best = self._pending_headers_at
        for i in range(len(self._streams)):
            var body_at = self._streams[i].body_at
            if body_at == NO_DEADLINE:
                continue
            if best == NO_DEADLINE or body_at < best:
                best = body_at
        return best

    def expire(mut self, now: Int) -> List[Byte]:
        var output = List[Byte]()
        if self._failed:
            return output^
        if (
            self._pending_headers_at != NO_DEADLINE
            and now >= self._pending_headers_at
        ):
            self._failed = True
            self._pending_headers_at = NO_DEADLINE
            return output^

        var expired = List[UInt32]()
        for i in range(len(self._streams)):
            var body_at = self._streams[i].body_at
            if body_at != NO_DEADLINE and now >= body_at:
                expired.append(self._streams[i].stream_id)
        for i in range(len(expired)):
            var stream_id = expired[i]
            var reset = encode_rst_stream_frame(stream_id, UInt32(8))
            if not reset.is_complete():
                self._failed = True
                return output^
            _append_session_output(output, Span(reset.wire))
            self._remove_stream(stream_id)
        return output^

    def consume[
        origin: Origin
    ](mut self, data: Span[Byte, origin]) raises -> Http2RequestSessionResult:
        if self._failed:
            return Http2RequestSessionResult.error(0, List[Byte]())

        var output = List[Byte]()
        var consumed = 0
        while consumed < len(data):
            var input = self._input.consume(data[consumed:])
            consumed += input.consumed
            if input.is_error():
                self._failed = True
                return Http2RequestSessionResult.error(consumed, output^)
            var initial_stream_window = Int(
                self._input.peer_settings().initial_window_size
            )
            for i in range(len(self._send_streams)):
                if not self._send_streams[i].window.update_initial_send_window(
                    initial_stream_window
                ):
                    self._failed = True
                    return Http2RequestSessionResult.error(consumed, output^)
            _append_session_output(output, Span(input.output))
            if input.is_flood():
                # Flooded: queue ENHANCE_YOUR_CALM GOAWAY and mark the
                # session failed so the server flushes pending output and
                # then closes the connection. `is_failed` gates
                # close-after-flush; leaving it false keeps the connection
                # open until idle timeout with no further readable progress.
                self._draining = True
                self._failed = True
                var goaway = encode_goaway_frame(
                    self._last_stream_id, UInt32(11)
                )
                if not goaway.is_complete():
                    self._failed = True
                    return Http2RequestSessionResult.error(consumed, output^)
                _append_session_output(output, Span(goaway.wire))
                return Http2RequestSessionResult.pending(consumed, output^)

            if (
                self._pending_headers_at == NO_DEADLINE
                and self._input.assembling_headers_stream() != UInt32(0)
            ):
                self._pending_headers_at = deadline_from_now(
                    self._header_deadline
                )

            if input.is_frame():
                var frame = FrameParseResult.complete(
                    input.frame_type,
                    input.flags,
                    input.stream_id,
                    len(input.payload),
                )
                if input.frame_type == Byte(1) or input.frame_type == Byte(9):
                    var decoded = self._consume_headers(
                        frame, Span(input.payload)
                    )
                    if decoded.is_complete():
                        self._pending_headers_at = NO_DEADLINE
                        var is_new_stream = (
                            self._find_stream(decoded.stream_id) < 0
                        )
                        if self._draining and is_new_stream:
                            var reset = encode_rst_stream_frame(
                                decoded.stream_id, UInt32(7)
                            )
                            if not reset.is_complete():
                                self._failed = True
                                return Http2RequestSessionResult.error(
                                    consumed, output^
                                )
                            _append_session_output(output, Span(reset.wire))
                            continue
                        var request_result = self._receive_headers(decoded)
                        if request_result.is_malformed():
                            var reset = encode_rst_stream_frame(
                                decoded.stream_id, UInt32(1)
                            )
                            if not reset.is_complete():
                                self._failed = True
                                return Http2RequestSessionResult.error(
                                    consumed, output^
                                )
                            _append_session_output(output, Span(reset.wire))
                            self._remove_stream(decoded.stream_id)
                            continue
                        if request_result.is_error():
                            self._failed = True
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        if request_result.is_refused():
                            var reset = encode_rst_stream_frame(
                                decoded.stream_id, UInt32(7)
                            )
                            if not reset.is_complete():
                                self._failed = True
                                return Http2RequestSessionResult.error(
                                    consumed, output^
                                )
                            _append_session_output(output, Span(reset.wire))
                            continue
                        if request_result.is_complete():
                            var request = self._take_request(decoded.stream_id)
                            return Http2RequestSessionResult.complete(
                                consumed, decoded.stream_id, output^, request^
                            )
                        if request_result.is_pending():
                            var index = self._find_stream(decoded.stream_id)
                            if (
                                index >= 0
                                and self._streams[index].body_at == NO_DEADLINE
                            ):
                                self._streams[
                                    index
                                ].body_at = deadline_from_now(
                                    self._body_deadline
                                )
                    elif decoded.is_pending():
                        if self._pending_headers_at == NO_DEADLINE:
                            self._pending_headers_at = deadline_from_now(
                                self._header_deadline
                            )
                    elif decoded.is_too_large():
                        self._pending_headers_at = NO_DEADLINE
                        var stream_id = decoded.stream_id
                        if stream_id == UInt32(0):
                            stream_id = input.stream_id
                        if stream_id > self._last_stream_id:
                            self._last_stream_id = stream_id
                        var reset = encode_rst_stream_frame(
                            stream_id, UInt32(11)
                        )
                        if not reset.is_complete():
                            self._failed = True
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        _append_session_output(output, Span(reset.wire))
                        self._remove_stream(stream_id)
                        continue
                    else:
                        self._failed = True
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                elif input.frame_type == Byte(0):
                    var request_result = self._receive_data(
                        frame, Span(input.payload), output
                    )
                    if request_result.is_malformed():
                        var reset = encode_rst_stream_frame(
                            input.stream_id, UInt32(1)
                        )
                        if not reset.is_complete():
                            self._failed = True
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        _append_session_output(output, Span(reset.wire))
                        self._remove_stream(input.stream_id)
                        continue
                    if request_result.is_error():
                        self._failed = True
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                    if request_result.is_too_large():
                        var reset = encode_rst_stream_frame(
                            input.stream_id, UInt32(11)
                        )
                        if not reset.is_complete():
                            self._failed = True
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        _append_session_output(output, Span(reset.wire))
                        self._remove_stream(input.stream_id)
                        continue
                    if request_result.is_complete():
                        var request = self._take_request(input.stream_id)
                        return Http2RequestSessionResult.complete(
                            consumed, input.stream_id, output^, request^
                        )
            elif input.is_reset():
                if input.stream_id > self._last_stream_id or (
                    input.stream_id & UInt32(1)
                ) == UInt32(0):
                    self._failed = True
                    return Http2RequestSessionResult.error(consumed, output^)
                self._remove_stream(input.stream_id)
                return Http2RequestSessionResult.pending(
                    consumed, output^, input.stream_id
                )
            elif input.is_window_update():
                if input.stream_id == UInt32(0):
                    if not self._send_window.apply_window_update(
                        Int(input.value)
                    ):
                        self._failed = True
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                else:
                    var send_index = self._find_send_stream(input.stream_id)
                    if send_index >= 0 and not self._send_streams[
                        send_index
                    ].window.apply_window_update(Int(input.value)):
                        self._failed = True
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )

            if input.consumed == 0:
                break

        return Http2RequestSessionResult.pending(consumed, output^)

    def _consume_headers[
        origin: Origin
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, origin],
    ) raises -> Http2HeaderDecodeResult:
        var for_trailers = self._find_stream(frame.stream_id) >= 0
        var max_bytes = self._max_headers_bytes
        var max_count = self._max_headers_count
        if for_trailers:
            max_bytes = self._max_trailer_bytes
            max_count = self._max_trailer_count
        if not self._decoder:
            var assembler_limit = self._max_headers_bytes
            if self._max_trailer_bytes > assembler_limit:
                assembler_limit = self._max_trailer_bytes
            self._decoder = Optional(
                Http2HeaderDecoder(
                    String(self._library_path), 4096, assembler_limit
                )
            )
        return self._decoder.value().consume(
            frame, payload, max_bytes, max_count, Span(self._header_output)
        )

    def _receive_headers(
        mut self,
        decoded: Http2HeaderDecodeResult,
    ) raises -> Http2RequestStreamResult:
        var index = self._find_stream(decoded.stream_id)
        if index < 0:
            if (
                decoded.stream_id == UInt32(0)
                or (decoded.stream_id & UInt32(1)) == UInt32(0)
                or decoded.stream_id <= self._last_stream_id
            ):
                return Http2RequestStreamResult.error()
            self._last_stream_id = decoded.stream_id
            if len(self._send_streams) >= self._max_active_streams:
                return Http2RequestStreamResult.refused()
            var stream = Http2RequestStream(self._max_body_size)
            var receive_window = Http2FlowWindow(65535, 65535)
            var entry = _Http2RequestEntry(
                stream_id=decoded.stream_id,
                stream=stream^,
                receive_window=receive_window^,
                body_at=NO_DEADLINE,
            )
            self._streams.append(entry^)
            var initial_send_window = Http2FlowWindow(
                Int(self._input.peer_settings().initial_window_size), 65535
            )
            var send_entry = _Http2SendWindowEntry(
                stream_id=decoded.stream_id, window=initial_send_window^
            )
            self._send_streams.append(send_entry^)
            index = len(self._streams) - 1

        return self._streams[index].stream.receive_headers(
            Span(self._header_output)[0 : decoded.output_length],
            decoded.field_count,
            decoded.end_stream,
        )

    def _receive_data[
        origin: Origin
    ](
        mut self,
        frame: FrameParseResult,
        payload: Span[Byte, origin],
        mut output: List[Byte],
    ) -> Http2RequestStreamResult:
        var index = self._find_stream(frame.stream_id)
        var data = parse_data_frame(frame, payload)
        if not data.is_valid():
            return Http2RequestStreamResult.error()
        if index < 0:
            if (frame.stream_id & UInt32(1)) == UInt32(
                1
            ) and frame.stream_id <= self._last_stream_id:
                # DATA may already be in flight before the peer sees RST/END.
                # Still account for connection flow control and return credit.
                if frame.payload_length > 0:
                    if not self._receive_window.receive_data(
                        frame.payload_length
                    ):
                        return Http2RequestStreamResult.error()
                    if not self._receive_window.release_received(
                        frame.payload_length
                    ):
                        return Http2RequestStreamResult.error()
                    _append_window_update(
                        output, UInt32(0), frame.payload_length
                    )
                return Http2RequestStreamResult.pending()
            return Http2RequestStreamResult.error()
        if not self._receive_window.receive_data(
            frame.payload_length
        ) or not self._streams[index].receive_window.receive_data(
            frame.payload_length
        ):
            return Http2RequestStreamResult.error()
        var received = self._streams[index].stream.receive_data(data, payload)
        if received.is_too_large():
            if not self._receive_window.release_received(frame.payload_length):
                return Http2RequestStreamResult.error()
            _append_window_update(output, UInt32(0), frame.payload_length)
            return received^
        if received.is_malformed():
            if frame.payload_length > 0:
                if not self._receive_window.release_received(
                    frame.payload_length
                ):
                    return Http2RequestStreamResult.error()
                _append_window_update(output, UInt32(0), frame.payload_length)
            return received^
        if not received.is_pending() and not received.is_complete():
            return received^
        if frame.payload_length > 0:
            if not self._receive_window.release_received(
                frame.payload_length
            ) or not self._streams[index].receive_window.release_received(
                frame.payload_length
            ):
                return Http2RequestStreamResult.error()
            _append_window_update(output, UInt32(0), frame.payload_length)
            _append_window_update(output, frame.stream_id, frame.payload_length)
        return received^

    def _find_stream(self, stream_id: UInt32) -> Int:
        for i in range(len(self._streams)):
            if self._streams[i].stream_id == stream_id:
                return i
        return -1

    def buffered_body_bytes(self) -> Int:
        var total = 0
        for i in range(len(self._streams)):
            total += self._streams[i].stream.buffered_body_bytes()
        return total

    def buffered_request_bytes(self) -> Int:
        var total = 0
        for i in range(len(self._streams)):
            total += self._streams[i].stream.buffered_body_bytes()
            total += self._streams[i].stream.buffered_header_bytes()
        return total

    def is_failed(self) -> Bool:
        return self._failed

    def is_draining(self) -> Bool:
        return self._draining

    def peer_settings(self) -> Http2PeerSettingsSnapshot:
        return self._input.peer_settings()

    def send_window(self, stream_id: UInt32) -> Int:
        var index = self._find_send_stream(stream_id)
        if index < 0:
            return 0
        return min(
            self._send_window.send_window(),
            self._send_streams[index].window.send_window(),
        )

    def consume_outbound(mut self, stream_id: UInt32, amount: Int) -> Bool:
        var index = self._find_send_stream(stream_id)
        if index < 0 or amount > self.send_window(stream_id):
            return False
        if not self._send_window.consume_outbound(amount):
            return False
        return self._send_streams[index].window.consume_outbound(amount)

    def finish_response(mut self, stream_id: UInt32):
        var index = self._find_send_stream(stream_id)
        if index >= 0:
            var last = self._send_streams.pop()
            if index < len(self._send_streams):
                self._send_streams[index] = last^

    def _find_send_stream(self, stream_id: UInt32) -> Int:
        for i in range(len(self._send_streams)):
            if self._send_streams[i].stream_id == stream_id:
                return i
        return -1

    def _take_request(mut self, stream_id: UInt32) -> Request:
        var entry = self._streams.pop(self._find_stream(stream_id))
        return entry^.take_request()

    def _remove_stream(mut self, stream_id: UInt32):
        var index = self._find_stream(stream_id)
        if index >= 0:
            self._remove_stream_at(index)
        var send_index = self._find_send_stream(stream_id)
        if send_index >= 0:
            var last = self._send_streams.pop()
            if send_index < len(self._send_streams):
                self._send_streams[send_index] = last^

    def _remove_stream_at(mut self, index: Int):
        var last = self._streams.pop()
        if index < len(self._streams):
            self._streams[index] = last^


def _append_session_output[
    origin: Origin
](mut output: List[Byte], bytes: Span[Byte, origin]):
    output.extend(bytes)


def _append_window_update(
    mut output: List[Byte], stream_id: UInt32, increment: Int
):
    var payload: List[Byte] = [
        Byte((increment >> 24) & 0x7F),
        Byte((increment >> 16) & 0xFF),
        Byte((increment >> 8) & 0xFF),
        Byte(increment & 0xFF),
    ]
    var frame = encode_frame(Byte(8), Byte(0), stream_id, Span(payload))
    _append_session_output(output, Span(frame.wire))
