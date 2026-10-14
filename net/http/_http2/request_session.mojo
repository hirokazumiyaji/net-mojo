"""Dispatches HTTP/2 request heads or completed buffered requests."""

from net.http._buffer import SharedBufferBudget
from net.http._body_pipe import _BodyPipe
from net import Timeout
from std.collections import Set
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

comptime _MAX_RESET_HISTORY = 256


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

    @staticmethod
    def head(
        consumed: Int,
        stream_id: UInt32,
        var output: List[Byte],
        var request: Request,
    ) -> Self:
        var result = Self.complete(consumed, stream_id, output^, request^)
        result.kind = 4
        return result^

    def is_head(self) -> Bool:
        return self.kind == 4

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
    var _body_budget: Optional[SharedBufferBudget]
    var _body_wakeup_fd: Int32
    var _initial_receive_window: Int
    var _settings_acknowledged: Bool
    var _max_headers_bytes: Int
    var _max_headers_count: Int
    var _max_trailer_bytes: Int
    var _max_trailer_count: Int
    var _header_deadline: Timeout
    var _body_deadline: Timeout
    var _pending_headers_at: Int
    var _last_stream_id: UInt32
    var _locally_reset_streams: Set[UInt32]
    var _peer_reset_streams: Set[UInt32]
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
        max_new_streams_per_second: Int = 10000,
        var request_body_budget: Optional[SharedBufferBudget] = None,
        body_wakeup_fd: Int32 = -1,
    ):
        self._initial_receive_window = min(
            max_body_size, 65535
        ) if request_body_budget else 65535
        self._settings_acknowledged = False
        self._body_budget = request_body_budget^
        self._body_wakeup_fd = body_wakeup_fd
        self._input = Http2ServerConnectionInput(
            max_concurrent_streams=max_active_streams,
            max_control_frames_per_second=max_control_frames_per_second,
            max_resets_per_second=max_resets_per_second,
            max_new_streams_per_second=max_new_streams_per_second,
            max_header_list_size=max_headers_bytes,
            initial_receive_window=self._initial_receive_window,
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
        self._locally_reset_streams = Set[UInt32]()
        self._peer_reset_streams = Set[UInt32]()
        self._draining = False
        self._failed = (
            max_active_streams < 0
            or max_body_size < 0
            or (self._body_budget and max_body_size == 0)
            or max_headers_bytes < 0
            or max_headers_count < 0
            or max_trailer_bytes < 0
            or max_trailer_count < 0
        )

    def _fail(mut self):
        self._failed = True
        self._pending_headers_at = NO_DEADLINE
        for i in range(len(self._streams)):
            self._streams[i].body_at = NO_DEADLINE
            self._streams[i].stream.cancel_input()

    def begin_shutdown(mut self, error_code: UInt32 = UInt32(0)) -> List[Byte]:
        var output = List[Byte]()
        if not self._draining:
            self._draining = True
            var goaway = encode_goaway_frame(self._last_stream_id, error_code)
            output.extend(Span(goaway.wire))
        var index = 0
        while index < len(self._streams):
            if self._streams[index].stream.is_streaming():
                self._cancel_stream_at(index, output)
            else:
                index += 1
        return output^

    def next_deadline(self) -> Int:
        if self._failed:
            return NO_DEADLINE
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
            self._fail()
            self._pending_headers_at = NO_DEADLINE
            return output^

        var expired = List[UInt32]()
        for i in range(len(self._streams)):
            var body_at = self._streams[i].body_at
            if body_at != NO_DEADLINE and now >= body_at:
                expired.append(self._streams[i].stream_id)
        for i in range(len(expired)):
            var stream_id = expired[i]
            if not self._append_reset(output, stream_id, UInt32(8)):
                return output^
            self._remove_stream(stream_id, output)
        return output^

    def _connection_error(
        mut self,
        consumed: Int,
        var output: List[Byte],
        error_code: UInt32 = UInt32(1),
    ) -> Http2RequestSessionResult:
        self._fail()
        self._draining = True
        var goaway = encode_goaway_frame(self._last_stream_id, error_code)
        output.extend(Span(goaway.wire))
        return Http2RequestSessionResult.error(consumed, output^)

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
            self._apply_settings_ack()
            if input.is_error():
                output.extend(Span(input.output))
                return self._connection_error(consumed, output^, input.value)
            var initial_stream_window = Int(
                self._input.peer_settings().initial_window_size
            )
            for i in range(len(self._send_streams)):
                if not self._send_streams[i].window.update_initial_send_window(
                    initial_stream_window
                ):
                    return self._connection_error(consumed, output^, UInt32(3))
            output.extend(Span(input.output))
            if input.is_flood():
                # Flooded: queue ENHANCE_YOUR_CALM GOAWAY and mark the
                # session failed so the server flushes pending output and
                # then closes the connection. `is_failed` gates
                # close-after-flush; leaving it false keeps the connection
                # open until idle timeout with no further readable progress.
                self._draining = True
                self._fail()
                var goaway = encode_goaway_frame(
                    self._last_stream_id, UInt32(11)
                )
                if not goaway.is_complete():
                    self._fail()
                    return Http2RequestSessionResult.error(consumed, output^)
                output.extend(Span(goaway.wire))
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
                            if not self._append_reset(
                                output, decoded.stream_id, UInt32(7)
                            ):
                                return Http2RequestSessionResult.error(
                                    consumed, output^
                                )
                            # Advance last_stream_id so DATA already in
                            # flight on this stream (before the peer
                            # sees our RST) is accounted for in connection
                            # flow control instead of failing the session.
                            if decoded.stream_id > self._last_stream_id:
                                self._last_stream_id = decoded.stream_id
                            continue
                        var request_result = self._receive_headers(decoded)
                        if request_result.is_malformed():
                            if not self._append_reset(
                                output, decoded.stream_id, UInt32(1)
                            ):
                                return Http2RequestSessionResult.error(
                                    consumed, output^
                                )
                            self._remove_stream(decoded.stream_id, output)
                            return Http2RequestSessionResult.pending(
                                consumed, output^, decoded.stream_id
                            )
                        if request_result.is_error():
                            self._fail()
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        if request_result.is_refused():
                            if not self._append_reset(
                                output, decoded.stream_id, UInt32(7)
                            ):
                                return Http2RequestSessionResult.error(
                                    consumed, output^
                                )
                            continue
                        var head_index = self._find_stream(decoded.stream_id)
                        if (
                            head_index >= 0
                            and self._streams[head_index].stream.head_ready()
                        ):
                            if not self._streams[
                                head_index
                            ].stream.is_complete():
                                self._streams[
                                    head_index
                                ].body_at = deadline_from_now(
                                    self._body_deadline
                                )
                            var request = self._streams[
                                head_index
                            ].stream.take_head()
                            return Http2RequestSessionResult.head(
                                consumed, decoded.stream_id, output^, request^
                            )
                        if request_result.is_complete() and self._body_budget:
                            self._streams[head_index].body_at = NO_DEADLINE
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
                        if not self._append_reset(
                            output, stream_id, UInt32(11)
                        ):
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        self._remove_stream(stream_id, output)
                        return Http2RequestSessionResult.pending(
                            consumed, output^, stream_id
                        )
                    elif decoded.is_flooded():
                        self._pending_headers_at = NO_DEADLINE
                        self._draining = True
                        self._fail()
                        var goaway = encode_goaway_frame(
                            self._last_stream_id, UInt32(11)
                        )
                        if not goaway.is_complete():
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        output.extend(Span(goaway.wire))
                        return Http2RequestSessionResult.pending(
                            consumed, output^
                        )
                    else:
                        self._fail()
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                elif input.frame_type == Byte(0):
                    var was_locally_reset = self._is_locally_reset(
                        input.stream_id
                    )
                    var request_result = self._receive_data(
                        frame, Span(input.payload), output
                    )
                    if request_result.is_peer_reset():
                        return self._connection_error(
                            consumed, output^, UInt32(5)
                        )
                    if request_result.is_closed():
                        if not self._append_reset(
                            output, input.stream_id, UInt32(5)
                        ):
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        self._remove_stream(input.stream_id, output)
                        return Http2RequestSessionResult.pending(
                            consumed, output^, input.stream_id
                        )
                    if request_result.is_malformed():
                        if not self._append_reset(
                            output, input.stream_id, UInt32(1)
                        ):
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        self._remove_stream(input.stream_id, output)
                        return Http2RequestSessionResult.pending(
                            consumed, output^, input.stream_id
                        )
                    if request_result.is_error():
                        self._fail()
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                    if request_result.is_too_large():
                        if not self._append_reset(
                            output, input.stream_id, UInt32(11)
                        ):
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        self._remove_stream(input.stream_id, output)
                        return Http2RequestSessionResult.pending(
                            consumed, output^, input.stream_id
                        )
                    if (
                        request_result.is_pending()
                        and not was_locally_reset
                        and self._find_stream(input.stream_id) < 0
                    ):
                        return Http2RequestSessionResult.pending(
                            consumed, output^, input.stream_id
                        )
                    if request_result.is_complete() and self._body_budget:
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
                    self._fail()
                    return Http2RequestSessionResult.error(consumed, output^)
                self._remove_stream(input.stream_id, output)
                if not self._reset_history_full():
                    self._peer_reset_streams.add(input.stream_id)
                if self._reset_history_full():
                    return self._connection_error(consumed, output^, UInt32(11))
                return Http2RequestSessionResult.pending(
                    consumed, output^, input.stream_id
                )
            elif input.is_goaway():
                # Peer stops accepting new streams above its last_stream_id;
                # finish in-flight, refuse later HEADERS, and acknowledge with
                # our own GOAWAY so the connection drains instead of lingering.
                if not self._draining:
                    self._draining = True
                    var goaway = encode_goaway_frame(
                        self._last_stream_id, UInt32(0)
                    )
                    if goaway.is_complete():
                        output.extend(Span(goaway.wire))
            elif input.is_window_update():
                # RFC 9113 §6.9: stream increment=0 → RST PROTOCOL_ERROR;
                # stream window overflow → RST FLOW_CONTROL_ERROR; stream 0
                # violations remain connection errors. Malformed frames are
                # rejected earlier as connection errors by the dispatcher.
                var increment = Int(input.value)
                if input.stream_id == UInt32(0):
                    if (
                        increment == 0
                        or not self._send_window.apply_window_update(increment)
                    ):
                        var error_code = UInt32(
                            1
                        ) if increment == 0 else UInt32(3)
                        return self._connection_error(
                            consumed, output^, error_code
                        )
                else:
                    var send_index = self._find_send_stream(input.stream_id)
                    if send_index < 0:
                        # Idle (never opened / even id): WINDOW_UPDATE is a
                        # connection PROTOCOL_ERROR (RFC 9113 §5.1).
                        # Closed streams: ignore stream errors, including
                        # increment=0, so a late update cannot tear down
                        # the connection (RFC 9113 §5.1 closed).
                        if input.stream_id > self._last_stream_id or (
                            input.stream_id & UInt32(1)
                        ) == UInt32(0):
                            self._fail()
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                    elif increment == 0:
                        # PROTOCOL_ERROR on the stream only.
                        if not self._append_reset(
                            output, input.stream_id, UInt32(1)
                        ):
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        self._remove_stream(input.stream_id, output)
                        return Http2RequestSessionResult.pending(
                            consumed, output^, input.stream_id
                        )
                    elif not self._send_streams[
                        send_index
                    ].window.apply_window_update(increment):
                        # FLOW_CONTROL_ERROR on the stream only.
                        if not self._append_reset(
                            output, input.stream_id, UInt32(3)
                        ):
                            return Http2RequestSessionResult.error(
                                consumed, output^
                            )
                        self._remove_stream(input.stream_id, output)
                        return Http2RequestSessionResult.pending(
                            consumed, output^, input.stream_id
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
            var active = len(self._send_streams)
            for i in range(len(self._streams)):
                if self._find_send_stream(self._streams[i].stream_id) < 0:
                    active += 1
            if active >= self._max_active_streams:
                return Http2RequestStreamResult.refused()
            var pipe: Optional[_BodyPipe] = None
            if self._body_budget:
                try:
                    pipe = Optional(
                        _BodyPipe(
                            self._initial_receive_window if self._settings_acknowledged else 65535,
                            self._body_budget.value().copy(),
                            self._body_wakeup_fd,
                            reserve_capacity=True,
                        )
                    )
                except:
                    return Http2RequestStreamResult.refused()
            var stream = Http2RequestStream(self._max_body_size, pipe^)
            var receive_window = Http2FlowWindow(
                65535,
                self._initial_receive_window if self._settings_acknowledged
                or not self._body_budget else 65535,
            )
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
    ) raises -> Http2RequestStreamResult:
        var index = self._find_stream(frame.stream_id)
        var data = parse_data_frame(frame, payload)
        if not data.is_valid():
            return Http2RequestStreamResult.error()
        if not self._receive_window.receive_data(frame.payload_length):
            return Http2RequestStreamResult.error()
        if index < 0 or self._streams[index].stream.is_complete():
            if (frame.stream_id & UInt32(1)) == UInt32(
                1
            ) and frame.stream_id <= self._last_stream_id:
                _ = self._receive_window.release_received(frame.payload_length)
                if frame.payload_length > 0:
                    _append_window_update(
                        output, UInt32(0), frame.payload_length
                    )
                if self._is_locally_reset(frame.stream_id):
                    return Http2RequestStreamResult.pending()
                if frame.stream_id in self._peer_reset_streams:
                    return Http2RequestStreamResult.peer_reset()
                return Http2RequestStreamResult.closed()
            return Http2RequestStreamResult.error()
        if not self._streams[index].receive_window.receive_data(
            frame.payload_length
        ):
            _ = self._receive_window.release_received(frame.payload_length)
            if frame.payload_length > 0:
                _append_window_update(output, UInt32(0), frame.payload_length)
            _ = self._append_reset(output, frame.stream_id, UInt32(3))
            self._remove_stream(frame.stream_id, output)
            return Http2RequestStreamResult.pending()
        var received = self._streams[index].stream.receive_data(data, payload)
        if not received.is_pending() and not received.is_complete():
            return received^
        var credit = frame.payload_length
        if self._streams[index].stream.is_streaming():
            credit -= data.data_length
            if received.is_complete():
                self._streams[index].body_at = NO_DEADLINE
            elif data.data_length > 0:
                self._streams[index].body_at = deadline_from_now(
                    self._body_deadline
                )
        if credit > 0:
            _ = self._receive_window.release_received(credit)
            _ = self._streams[index].receive_window.release_received(credit)
            _append_window_update(output, UInt32(0), credit)
            _append_window_update(output, frame.stream_id, credit)
        return received^

    def _apply_settings_ack(mut self):
        if (
            self._settings_acknowledged
            or not self._input.settings_acknowledged()
        ):
            return
        self._settings_acknowledged = True
        if not self._body_budget:
            return
        var delta = self._initial_receive_window - 65535
        for i in range(len(self._streams)):
            self._streams[i].receive_window.adjust_initial_receive_window(delta)
            self._streams[i].stream.body_pipe().set_limit(
                self._initial_receive_window
            )

    def flush_body_credit(mut self) -> List[Byte]:
        var output = List[Byte]()
        var i = 0
        while i < len(self._streams):
            if not self._streams[i].stream.is_streaming():
                i += 1
                continue
            var pipe = self._streams[i].stream.body_pipe()
            var credit = pipe.take_consumed()
            if credit > 0:
                _ = self._receive_window.release_received(credit)
                _ = self._streams[i].receive_window.release_received(credit)
                _append_window_update(output, UInt32(0), credit)
                if not self._streams[i].stream.is_complete():
                    _append_window_update(
                        output, self._streams[i].stream_id, credit
                    )
            if self._streams[i].stream.is_complete() and pipe.is_eof():
                var remaining = self._streams[
                    i
                ].receive_window.pending_receive_credit()
                if remaining > 0:
                    _ = self._receive_window.release_received(remaining)
                    _append_window_update(output, UInt32(0), remaining)
                pipe._stop_loop_wakeup()
                self._remove_stream_at(i)
            else:
                i += 1
        return output^

    def _cancel_stream_at(mut self, index: Int, mut output: List[Byte]):
        var credit = self._streams[
            index
        ].receive_window.pending_receive_credit()
        self._streams[index].stream.cancel_input()
        if credit > 0:
            _ = self._receive_window.release_received(credit)
            _append_window_update(output, UInt32(0), credit)
        self._remove_stream_at(index)

    def __deinit__(deinit self):
        for i in range(len(self._streams)):
            self._streams[i].stream.cancel_input()

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

    def has_active_streams(self) -> Bool:
        return len(self._streams) > 0 or len(self._send_streams) > 0

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

    def reset_response_credit_size(self, stream_id: UInt32) -> Int:
        var index = self._find_stream(stream_id)
        if (
            index >= 0
            and self._streams[index].receive_window.pending_receive_credit() > 0
        ):
            return 13
        return 0

    def reset_response(mut self, stream_id: UInt32, mut output: List[Byte]):
        _ = self._remember_local_reset(stream_id)
        self._remove_stream(stream_id, output)

    def refuse_stream(
        mut self, stream_id: UInt32, error_code: UInt32
    ) -> List[Byte]:
        var output = List[Byte]()
        self._remove_stream(stream_id, output)
        _ = self._append_reset(output, stream_id, error_code)
        return output^

    def _find_send_stream(self, stream_id: UInt32) -> Int:
        for i in range(len(self._send_streams)):
            if self._send_streams[i].stream_id == stream_id:
                return i
        return -1

    def _take_request(mut self, stream_id: UInt32) -> Request:
        var entry = self._streams.pop(self._find_stream(stream_id))
        return entry^.take_request()

    def _remove_stream(mut self, stream_id: UInt32, mut output: List[Byte]):
        var index = self._find_stream(stream_id)
        if index >= 0:
            self._cancel_stream_at(index, output)
        var send_index = self._find_send_stream(stream_id)
        if send_index >= 0:
            var last = self._send_streams.pop()
            if send_index < len(self._send_streams):
                self._send_streams[send_index] = last^

    def _append_reset(
        mut self, mut output: List[Byte], stream_id: UInt32, code: UInt32
    ) -> Bool:
        var reset = encode_rst_stream_frame(stream_id, code)
        if not reset.is_complete():
            self._fail()
            return False
        output.extend(Span(reset.wire))
        if not self._remember_local_reset(stream_id):
            var goaway = self.begin_shutdown(UInt32(11))
            output.extend(Span(goaway))
            return False
        return True

    def _remember_local_reset(mut self, stream_id: UInt32) -> Bool:
        if stream_id not in self._locally_reset_streams:
            if not self._reset_history_full():
                self._locally_reset_streams.add(stream_id)
            if self._reset_history_full():
                self._fail()
        return not self._failed

    def _reset_history_full(self) -> Bool:
        return (
            len(self._locally_reset_streams) + len(self._peer_reset_streams)
            >= _MAX_RESET_HISTORY
        )

    def _is_locally_reset(self, stream_id: UInt32) -> Bool:
        return stream_id in self._locally_reset_streams

    def _remove_stream_at(mut self, index: Int):
        var last = self._streams.pop()
        if index < len(self._streams):
            self._streams[index] = last^


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
    output.extend(Span(frame.wire))
