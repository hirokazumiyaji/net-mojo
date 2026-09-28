"""Assembles completed HTTP/2 requests for one connection."""

from net.http.request import HttpVersion, Request

from .connection_input import (
    Http2ServerConnectionInput,
)
from .data_frame import parse_data_frame
from .frame import FrameParseResult
from .header_decoder import Http2HeaderDecodeResult, Http2HeaderDecoder
from .request_stream import Http2RequestStream, Http2RequestStreamResult


@fieldwise_init
struct Http2RequestSessionResult(Movable):
    var kind: UInt8
    var consumed: Int
    var stream_id: UInt32
    var output: List[Byte]
    var request: Request

    @staticmethod
    def pending(consumed: Int, var output: List[Byte]) -> Self:
        return Self(
            kind=1,
            consumed=consumed,
            stream_id=UInt32(0),
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
            output=output^,
            request=request^,
        )

    @staticmethod
    def error(consumed: Int, var output: List[Byte]) -> Self:
        return Self(
            kind=3,
            consumed=consumed,
            stream_id=UInt32(0),
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


@fieldwise_init
struct _Http2RequestEntry(Movable):
    var stream_id: UInt32
    var stream: Http2RequestStream

    def take_request(deinit self) -> Request:
        return self.stream^.take_request()


struct Http2RequestSession(Movable):
    var _input: Http2ServerConnectionInput
    var _decoder: Optional[Http2HeaderDecoder]
    var _library_path: String
    var _header_output: Array[Byte, 65536]
    var _streams: List[_Http2RequestEntry]
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
        self._header_output = Array[Byte, 65536](fill=0)
        self._streams = List[_Http2RequestEntry]()
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
                        frame, Span(input.payload)
                    )
                    if (
                        request_result.is_error()
                        or request_result.is_too_large()
                    ):
                        self._failed = True
                        return Http2RequestSessionResult.error(
                            consumed, output^
                        )
                    if request_result.is_complete():
                        var request = self._take_request(input.stream_id)
                        return Http2RequestSessionResult.complete(
                            consumed, input.stream_id, output^, request^
                        )
            elif input.is_reset():
                self._remove_stream(input.stream_id)

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
                or len(self._streams) >= self._max_active_streams
            ):
                return Http2RequestStreamResult.error()
            self._last_stream_id = decoded.stream_id
            var stream = Http2RequestStream(self._max_body_size)
            var entry = _Http2RequestEntry(
                stream_id=decoded.stream_id, stream=stream^
            )
            self._streams.append(entry^)
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
    ) -> Http2RequestStreamResult:
        var index = self._find_stream(frame.stream_id)
        if index < 0:
            return Http2RequestStreamResult.error()
        var data = parse_data_frame(frame, payload)
        if not data.is_valid():
            return Http2RequestStreamResult.error()
        return self._streams[index].stream.receive_data(data, payload)

    def _find_stream(self, stream_id: UInt32) -> Int:
        for i in range(len(self._streams)):
            if self._streams[i].stream_id == stream_id:
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

    def _remove_stream_at(mut self, index: Int):
        var last = self._streams.pop()
        if index < len(self._streams):
            self._streams[index] = last^


def _append_session_output[
    origin: Origin
](mut output: List[Byte], bytes: Span[Byte, origin]):
    for i in range(len(bytes)):
        output.append(bytes[i])
