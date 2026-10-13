"""Incremental HTTP/1 body framing with consumer-controlled retention."""

from net.error import NetError, NetErrorKind
from ._body_pipe import _BodyPipe
from ._parser import (
    _find_crlf,
    _has_lone_lf_before,
    _split_chunk_size,
    _chunk_ext_valid,
    _parse_hex_size,
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
    var _metadata: Int
    var _trailer_bytes: Int
    var _trailers: Headers

    def __init__(out self, var pipe: _BodyPipe, chunked: Bool, length: Int):
        self._pipe = pipe^
        self._phase = 0 if chunked else 1
        self._remaining = max(0, length)
        self._chunked = chunked
        self._metadata = 0
        self._trailer_bytes = 0
        self._trailers = Headers()

    def _result(self, consumed: Int, blocked: Bool = False) -> _BodyFeed:
        return _BodyFeed(consumed, self._phase == 4, blocked, None)

    def _failure(mut self, consumed: Int, var error: HttpError) -> _BodyFeed:
        self._pipe.cancel()
        return _BodyFeed(consumed, False, False, Optional(error^))

    def feed[
        origin: ImmOrigin
    ](
        mut self, wire: Span[Byte, origin], config: ServerConfig
    ) raises NetError -> _BodyFeed:
        var pos = 0
        while self._phase != 4:
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
            var end = _find_crlf(wire, pos)
            var available_end = end if end >= 0 else len(wire)
            if _has_lone_lf_before(wire, pos, available_end):
                return self._failure(
                    pos, HttpError.bad_request("bad body framing")
                )
            var line_bytes = available_end - pos + (2 if end >= 0 else 0)
            if self._phase == 0:
                if line_bytes > config.max_chunk_metadata - self._metadata:
                    return self._failure(
                        pos,
                        HttpError.payload_too_large("chunk metadata too large"),
                    )
                if end < 0:
                    return self._result(pos)
                var line = String(from_utf8_lossy=wire[pos:end])
                var size, extension, has_extension = _split_chunk_size(line)
                var count = _parse_hex_size(size)
                if count < 0 or (
                    has_extension and not _chunk_ext_valid(extension)
                ):
                    return self._failure(
                        pos, HttpError.bad_request("bad chunk size")
                    )
                self._metadata += line_bytes
                self._remaining = count
                self._phase = 3 if count == 0 else 1
                pos = end + 2
                continue
            if end == pos:
                try:
                    if not self._pipe._try_push_eof(self._trailers):
                        return self._result(pos, True)
                except error:
                    if error.kind == NetErrorKind.invalid_argument():
                        return self._failure(
                            pos,
                            HttpError.unavailable(
                                "trailers exceed buffer budget"
                            ),
                        )
                    raise error^
                self._phase = 4
                pos += 2
                break
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
