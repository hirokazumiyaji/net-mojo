"""One HTTP/2 request stream's headers, body, and trailers."""

from net.http.request import HttpVersion, Request

from .data_frame import DataFrameResult
from .request_body import Http2RequestBody
from .request_headers import (
    decode_http2_request_headers,
    decode_http2_trailers,
)
from .stream_state import Http2StreamState


@fieldwise_init
struct Http2RequestStreamResult(Movable):
    var kind: UInt8

    @staticmethod
    def pending() -> Self:
        return Self(kind=1)

    @staticmethod
    def complete() -> Self:
        return Self(kind=2)

    @staticmethod
    def too_large() -> Self:
        return Self(kind=3)

    @staticmethod
    def error() -> Self:
        return Self(kind=4)

    def is_pending(self) -> Bool:
        return self.kind == 1

    def is_complete(self) -> Bool:
        return self.kind == 2

    def is_too_large(self) -> Bool:
        return self.kind == 3

    def is_error(self) -> Bool:
        return self.kind == 4


struct Http2RequestStream(Movable):
    var _state: Http2StreamState
    var _body: Http2RequestBody
    var _request: Request
    var _headers_received: Bool
    var _ready: Bool
    var _failed: Bool

    def __init__(out self, body_limit: Int):
        self._state = Http2StreamState()
        self._body = Http2RequestBody(body_limit)
        self._request = Request(
            String(), String(), String(), String(), HttpVersion.http2()
        )
        self._headers_received = False
        self._ready = False
        self._failed = body_limit < 0

    def receive_headers[
        origin: Origin
    ](
        mut self,
        encoded: Span[Byte, origin],
        expected_fields: Int,
        end_stream: Bool,
    ) raises -> Http2RequestStreamResult:
        if self._failed or self._ready:
            return Http2RequestStreamResult.error()

        if not self._headers_received:
            if not self._state.receive_headers(end_stream):
                self._failed = True
                return Http2RequestStreamResult.error()
            var parsed = decode_http2_request_headers(encoded, expected_fields)
            if not parsed.is_valid():
                self._failed = True
                return Http2RequestStreamResult.error()
            self._request = parsed^.into_request()
            self._headers_received = True
            if end_stream:
                self._ready = True
                return Http2RequestStreamResult.complete()
            return Http2RequestStreamResult.pending()

        if not end_stream or not self._state.receive_headers(True):
            self._failed = True
            return Http2RequestStreamResult.error()
        var trailers = decode_http2_trailers(encoded, expected_fields)
        if not trailers.is_valid():
            self._failed = True
            return Http2RequestStreamResult.error()
        self._request.trailers = trailers^.take_trailers()
        self._request.body = self._body.bytes()
        self._ready = True
        return Http2RequestStreamResult.complete()

    def receive_data[
        origin: Origin
    ](
        mut self,
        frame: DataFrameResult,
        payload: Span[Byte, origin],
    ) -> Http2RequestStreamResult:
        if (
            self._failed
            or self._ready
            or not self._headers_received
            or not self._state.receive_data(frame.end_stream)
        ):
            self._failed = True
            return Http2RequestStreamResult.error()

        var result = self._body.append_data(frame, payload)
        if result.is_too_large():
            self._failed = True
            return Http2RequestStreamResult.too_large()
        if not result.is_accepted():
            self._failed = True
            return Http2RequestStreamResult.error()
        if frame.end_stream:
            self._request.body = self._body.bytes()
            self._ready = True
            return Http2RequestStreamResult.complete()
        return Http2RequestStreamResult.pending()

    def take_request(deinit self) -> Request:
        return self._request^

    def buffered_body_bytes(self) -> Int:
        return self._body.size()
