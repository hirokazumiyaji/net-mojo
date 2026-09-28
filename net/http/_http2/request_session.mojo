"""Assembles completed HTTP/2 requests for one connection."""

from net.http.request import HttpVersion, Request

from .connection_input import (
    Http2ServerConnectionInput,
)
from .control_frames import encode_rst_stream_frame
from .data_frame import parse_data_frame
from .frame import FrameParseResult
from .frame_encoder import encode_frame
from .flow_window import Http2FlowWindow
from .header_decoder import Http2HeaderDecodeResult, Http2HeaderDecoder
from .request_stream import Http2RequestStream, Http2RequestStreamResult


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
    var _last_stream_id: UInt32
    var _failed: Bool

    def __init__(
        out self,
        var library_path: String,
        max_active_streams: Int,
        max_body_size: Int,
    ):
        self._input = Http2ServerConnectionInput()
        self._decoder = None
        self._library_path = library_path^
        self._header_output = List[Byte](length=65536, fill=0)
        self._streams = List[_Http2RequestEntry]()
        self._send_streams = List[_Http2SendWindowEntry]()
        self._receive_window = Http2FlowWindow(65535, 65535)
        self._send_window = Http2FlowWindow(65535, 65535)
        self._max_active_streams = max_active_streams
        self._max_body_size = max_body_size
        self._last_stream_id = UInt32(0)
        self._failed = max_active_streams < 0 or max_body_size < 0

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
                        var request_result = self._receive_headers(decoded)
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
                    elif not decoded.is_pending():
                        self._failed = True
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                elif input.frame_type == Byte(0):
                    var request_result = self._receive_data(
                        frame, Span(input.payload), output
                    )
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
                        return Http2RequestSessionResult.error(consumed, output^)
                else:
                    var send_index = self._find_send_stream(input.stream_id)
                    if (
                        send_index >= 0
                        and not self._send_streams[send_index].window
                            .apply_window_update(Int(input.value))
                    ):
                        self._failed = True
                        return Http2RequestSessionResult.error(consumed, output^)

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
        if not self._decoder:
            self._decoder = Optional(
                Http2HeaderDecoder(String(self._library_path), 4096, 65536)
            )
        return self._decoder.value().consume(
            frame, payload, 65536, 256, Span(self._header_output)
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
            )
            self._streams.append(entry^)
            var initial_send_window = Http2FlowWindow(
                Int(self._input.peer_settings().initial_window_size), 65535
            )
            var send_entry = _Http2SendWindowEntry(
                stream_id=decoded.stream_id,
                window=initial_send_window^
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
            if (
                (frame.stream_id & UInt32(1)) == UInt32(1)
                and frame.stream_id <= self._last_stream_id
            ):
                return Http2RequestStreamResult.pending()
            return Http2RequestStreamResult.error()
        if (
            not self._receive_window.receive_data(frame.payload_length)
            or not self._streams[index].receive_window.receive_data(
                frame.payload_length
            )
        ):
            return Http2RequestStreamResult.error()
        var received = self._streams[index].stream.receive_data(data, payload)
        if received.is_too_large():
            if not self._receive_window.release_received(frame.payload_length):
                return Http2RequestStreamResult.error()
            _append_window_update(output, UInt32(0), frame.payload_length)
            return received^
        if not received.is_pending() and not received.is_complete():
            return received^
        if frame.payload_length > 0:
            if (
                not self._receive_window.release_received(frame.payload_length)
                or not self._streams[index].receive_window.release_received(
                    frame.payload_length
                )
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
        var retained = List[_Http2RequestEntry]()
        var request = Request(
            String(), String(), String(), String(), HttpVersion.http2()
        )
        while len(self._streams) > 0:
            var entry = self._streams.pop()
            if entry.stream_id == stream_id:
                request = entry^.take_request()
            else:
                retained.append(entry^)
        while len(retained) > 0:
            self._streams.append(retained.pop())
        return request^

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
    for i in range(len(bytes)):
        output.append(bytes[i])


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
