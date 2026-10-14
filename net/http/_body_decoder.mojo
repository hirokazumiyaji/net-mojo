"""Incremental HTTP/1 body framing with consumer-controlled retention."""

from net.error import NetError, NetErrorKind
from ._body_pipe import _BodyPipe
from ._parser import (
    _find_crlf,
    _has_lone_lf_before,
    _ChunkLine,
    _is_token,
)
from .config import ServerConfig
from .error import HttpError
from .headers import Headers, _trailer_forbidden


@fieldwise_init
struct _BodyFeed(Movable):
    var consumed: Int
    var complete: Bool
    var blocked: Bool
    var error: Optional[HttpError]


struct _BodyDecoder(Movable):
    var _pipe: _BodyPipe
    var _phase: UInt8
    var _remaining: Int
    var _chunked: Bool
    var _chunk_line: _ChunkLine
    var _chunk_cr: Bool
    var _metadata: Int
    var _trailer_bytes: Int
    var _trailers: Headers

    def __init__(out self, var pipe: _BodyPipe, chunked: Bool, length: Int):
        self._pipe = pipe^
        self._phase = 0 if chunked else 1
        self._remaining = max(0, length)
        self._chunked = chunked
        self._chunk_line = _ChunkLine()
        self._chunk_cr = False
        self._metadata = 0
        self._trailer_bytes = 0
        self._trailers = Headers()

    def _result(self, consumed: Int, blocked: Bool = False) -> _BodyFeed:
        return _BodyFeed(consumed, self._phase == 4, blocked, None)

    def wants_input(self) -> Bool:
        return self._phase != 5 and (
            self._phase != 1
            or self._remaining == 0
            or self._pipe.writable_bytes() > 0
        )

    def read_allowance(self, limit: Int) -> Int:
        if self._phase == 5:
            return 0
        if self._phase == 1 and self._remaining > 0:
            return self._pipe._prepare_input(min(limit, self._remaining))
        if self._chunked and (self._phase == 0 or self._phase == 2):
            return self._pipe._prepare_input(limit)
        return limit

    def _failure(mut self, consumed: Int, var error: HttpError) -> _BodyFeed:
        self._pipe.cancel()
        return _BodyFeed(consumed, False, False, Optional(error^))

    def _publish_trailers(mut self, consumed: Int) raises NetError -> _BodyFeed:
        try:
            if not self._pipe._try_push_eof(self._trailers):
                return self._result(consumed, True)
        except error:
            if error.kind == NetErrorKind.invalid_argument():
                return self._failure(
                    consumed,
                    HttpError.unavailable("trailers exceed buffer budget"),
                )
            raise error^
        self._phase = 4
        return self._result(consumed)

    def feed[
        origin: ImmOrigin
    ](
        mut self, wire: Span[Byte, origin], config: ServerConfig
    ) raises NetError -> _BodyFeed:
        var pos = 0
        while self._phase != 4:
            if self._phase == 5:
                return self._publish_trailers(pos)
            if self._phase == 1:
                if self._remaining == 0:
                    if self._chunked:
                        self._phase = 2
                        continue
                    self._pipe.push_eof()
                    self._phase = 4
                    break
                var count = min(self._remaining, len(wire) - pos)
                count = min(count, self._pipe.writable_bytes())
                if count == 0:
                    return self._result(pos, pos < len(wire))
                if not self._pipe.push(wire[pos : pos + count]):
                    return self._result(pos, True)
                self._remaining -= count
                pos += count
                continue
            if self._phase == 2:
                if pos < len(wire) and wire[pos] != 13:
                    return self._failure(
                        pos, HttpError.bad_request("bad chunk data")
                    )
                if len(wire) - pos < 2:
                    return self._result(pos)
                if wire[pos + 1] != 10:
                    return self._failure(
                        pos, HttpError.bad_request("bad chunk data")
                    )
                pos += 2
                self._phase = 0
                continue
            if self._phase == 0:
                while pos < len(wire) and self._phase == 0:
                    if self._metadata >= config.max_chunk_metadata:
                        return self._failure(
                            pos,
                            HttpError.payload_too_large(
                                "chunk metadata too large"
                            ),
                        )
                    var byte = wire[pos]
                    if self._chunk_cr:
                        if byte != 10:
                            return self._failure(
                                pos, HttpError.bad_request("bad chunk size")
                            )
                        self._remaining = self._chunk_line.size
                        self._phase = 3 if self._remaining == 0 else 1
                        self._chunk_line = _ChunkLine()
                        self._chunk_cr = False
                    elif byte == 13:
                        if not self._chunk_line.is_complete():
                            return self._failure(
                                pos, HttpError.bad_request("bad chunk size")
                            )
                        self._chunk_cr = True
                    elif not self._chunk_line.push(byte):
                        return self._failure(
                            pos, HttpError.bad_request("bad chunk size")
                        )
                    self._metadata += 1
                    pos += 1
                if self._phase == 0:
                    return self._result(pos)
                continue
            var end = _find_crlf(wire, pos)
            var available_end = end if end >= 0 else len(wire)
            if _has_lone_lf_before(wire, pos, available_end):
                return self._failure(
                    pos, HttpError.bad_request("bad body framing")
                )
            var line_bytes = available_end - pos + (2 if end >= 0 else 0)
            if end == pos:
                self._phase = 5
                return self._publish_trailers(pos + 2)
            if len(wire) - pos == 1 and wire[pos] == 13:
                return self._result(pos)
            if line_bytes > config.max_trailer_bytes - self._trailer_bytes:
                return self._failure(
                    pos, HttpError.header_too_large("trailers too large")
                )
            if end < 0:
                return self._result(pos)
            if len(self._trailers) >= config.max_trailer_count:
                return self._failure(
                    pos, HttpError.header_too_large("trailers too large")
                )
            var colon = -1
            for i in range(pos, end):
                if wire[i] == 58:
                    colon = i
                    break
            if colon <= pos:
                return self._failure(pos, HttpError.bad_request("bad trailer"))
            var name = String(from_utf8_lossy=wire[pos:colon])
            if not _is_token(name) or _trailer_forbidden(name):
                return self._failure(pos, HttpError.bad_request("bad trailer"))
            var start = colon + 1
            var value_end = end
            while start < value_end and (wire[start] == 32 or wire[start] == 9):
                start += 1
            while value_end > start and (
                wire[value_end - 1] == 32 or wire[value_end - 1] == 9
            ):
                value_end -= 1
            try:
                self._trailers.add_bytes(name^, wire[start:value_end])
            except error:
                return self._failure(pos, HttpError.bad_request("bad trailer"))
            self._trailer_bytes += line_bytes
            pos = end + 2
        return self._result(pos)
