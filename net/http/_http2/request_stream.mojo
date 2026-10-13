"""One HTTP/2 request stream's headers, body, and trailers."""

from net.http.headers import Headers, _parse_decimal
from net.http._body_pipe import _BodyPipe
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
    def refused() -> Self:
        return Self(kind=5)

    @staticmethod
    def error() -> Self:
        return Self(kind=4)

    @staticmethod
    def malformed() -> Self:
        return Self(kind=6)

    @staticmethod
    def closed() -> Self:
        return Self(kind=7)

    @staticmethod
    def peer_reset() -> Self:
        return Self(kind=8)

    def is_pending(self) -> Bool:
        return self.kind == 1

    def is_complete(self) -> Bool:
        return self.kind == 2

    def is_too_large(self) -> Bool:
        return self.kind == 3

    def is_refused(self) -> Bool:
        return self.kind == 5

    def is_error(self) -> Bool:
        return self.kind == 4

    def is_malformed(self) -> Bool:
        return self.kind == 6

    def is_closed(self) -> Bool:
        return self.kind == 7

    def is_peer_reset(self) -> Bool:
        return self.kind == 8


struct Http2RequestStream(Movable):
    var _state: Http2StreamState
    var _body: Http2RequestBody
    var _request: Request
    var _headers_received: Bool
    var _ready: Bool
    var _failed: Bool
    var _head_dispatched: Bool
    var _expected_length: Int

    def __init__(out self, body_limit: Int, pipe: Optional[_BodyPipe] = None):
        self._state = Http2StreamState()
        self._body = Http2RequestBody(body_limit, pipe)
        self._request = Request(
            String(), String(), String(), String(), HttpVersion.http2()
        )
        self._headers_received = False
        self._ready = False
        self._failed = body_limit < 0
        self._head_dispatched = False
        self._expected_length = -1

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
                self._fail()
                return Http2RequestStreamResult.error()
            var parsed = decode_http2_request_headers(encoded, expected_fields)
            if not parsed.is_valid():
                self._fail()
                return Http2RequestStreamResult.malformed()
            self._request = parsed^.into_request()
            self._headers_received = True
            var lengths = self._request.headers.get_all("content-length")
            for length in lengths:
                var parsed = _parse_decimal(length, Int.MAX)
                if parsed < 0 or (
                    self._expected_length >= 0
                    and self._expected_length != parsed
                ):
                    self._fail()
                    return Http2RequestStreamResult.malformed()
                self._expected_length = parsed
            if end_stream:
                if not self._length_matches(0):
                    self._fail()
                    return Http2RequestStreamResult.malformed()
                if not self._finish_body():
                    self._fail()
                    return Http2RequestStreamResult.error()
                self._ready = True
                return Http2RequestStreamResult.complete()
            return Http2RequestStreamResult.pending()

        if not end_stream or not self._state.receive_headers(True):
            self._fail()
            return Http2RequestStreamResult.error()
        var trailers = decode_http2_trailers(encoded, expected_fields)
        if not trailers.is_valid():
            self._fail()
            return Http2RequestStreamResult.malformed()
        self._request.trailers = trailers^.take_trailers()
        self._request.body = self._body.bytes()
        if not self._length_matches(self._body.size()):
            self._fail()
            return Http2RequestStreamResult.malformed()
        if not self._finish_body():
            self._fail()
            return Http2RequestStreamResult.error()
        self._ready = True
        return Http2RequestStreamResult.complete()

    def receive_data[
        origin: Origin
    ](
        mut self,
        frame: DataFrameResult,
        payload: Span[Byte, origin],
    ) raises -> Http2RequestStreamResult:
        if (
            self._failed
            or self._ready
            or not self._headers_received
            or not self._state.receive_data(frame.end_stream)
        ):
            self._fail()
            return Http2RequestStreamResult.error()

        if (
            self._body.is_streaming()
            and self._expected_length >= 0
            and frame.data_length > self._expected_length - self._body.size()
        ):
            self._fail()
            return Http2RequestStreamResult.malformed()

        var result = self._body.append_data(frame, payload)
        if result.is_too_large():
            self._fail()
            return Http2RequestStreamResult.too_large()
        if not result.is_accepted():
            self._fail()
            return Http2RequestStreamResult.error()
        if frame.end_stream:
            if not self._length_matches(self._body.size()):
                self._fail()
                return Http2RequestStreamResult.malformed()
            self._request.body = self._body.bytes()
            if not self._finish_body():
                self._fail()
                return Http2RequestStreamResult.error()
            self._ready = True
            return Http2RequestStreamResult.complete()
        return Http2RequestStreamResult.pending()

    def _fail(mut self):
        self._failed = True
        self.cancel_input()

    def cancel_input(self):
        if self._body.is_streaming() and not self._body.pipe().is_eof():
            self._body.pipe().cancel()

    def __deinit__(deinit self):
        if not self._ready:
            self.cancel_input()

    def is_complete(self) -> Bool:
        return self._ready

    def is_streaming(self) -> Bool:
        return self._body.is_streaming()

    def body_pipe(self) -> _BodyPipe:
        return self._body.pipe()

    def _finish_body(mut self) raises -> Bool:
        if self._body.is_streaming():
            try:
                return self._body.pipe()._try_push_eof(self._request.trailers)
            except error:
                self._fail()
                raise error^
        return True

    def _length_matches(self, size: Int) -> Bool:
        return self._expected_length < 0 or self._expected_length == size

    def head_ready(self) -> Bool:
        return (
            self._body.is_streaming()
            and not self._failed
            and self._headers_received
            and not self._head_dispatched
        )

    def take_head(mut self) -> Request:
        var request = self._request^
        self._request = Request(
            String(), String(), String(), String(), HttpVersion.http2()
        )
        request._body_pipe = self._body.pipe()
        self._head_dispatched = True
        return request^

    def take_request(deinit self) -> Request:
        return self._request^

    def buffered_body_bytes(self) -> Int:
        return 0 if self._body.is_streaming() else self._body.size()

    def buffered_header_bytes(self) -> Int:
        if not self._headers_received:
            return 0
        var total = _headers_retained_bytes(self._request.headers)
        total += _headers_retained_bytes(self._request.trailers)
        total += self._request.method.byte_length()
        total += self._request.target.byte_length()
        total += self._request.scheme.byte_length()
        total += self._request.authority.byte_length()
        return total


def _headers_retained_bytes(headers: Headers) -> Int:
    var total = 0
    for i in range(len(headers)):
        total += headers.name_at(i).byte_length()
        total += headers.value_byte_length(i)
    return total
