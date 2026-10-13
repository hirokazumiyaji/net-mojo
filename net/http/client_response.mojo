"""Streaming response bodies own a connection lease until EOF or close."""

from net.timeout import Timeout, _Deadline
from .headers import Headers, _trailer_forbidden
from .request import HttpVersion
from .client_error import ClientError
from .client_config import ClientConfig
from ._client_pool import _ClientLease, _phase_deadline
from ._parser import (
    _is_token,
    _split_chunk_size,
    _parse_hex_size,
    _chunk_ext_valid,
)


def _copy_client_headers(headers: Headers) raises ClientError -> Headers:
    var result = Headers()
    for i in range(len(headers)):
        try:
            result.add_bytes(headers.name_at(i), headers._value_bytes_span(i))
        except error:
            raise ClientError(
                ClientError.PARSE, "cannot copy HTTP headers", error^
            )
    return result^


struct ResponseBody(Movable):
    var trailers: Headers
    var _lease: _ClientLease
    var _kind: UInt8
    var _remaining: Int
    var _finished: Bool
    var _reusable: Bool
    var _deadline: _Deadline
    var _buffer: List[Byte]
    var _offset: Int
    var _chunk_state: UInt8
    var _chunk_remaining: Int
    var _chunk_metadata: Int
    var _trailer_bytes: Int
    var _max_chunk_metadata: Int
    var _max_trailer_bytes: Int
    var _max_trailer_count: Int
    var _max_read_all: Int
    var _close_timeout: Timeout

    def __init__(
        out self,
        var lease: _ClientLease,
        var pending: List[Byte],
        kind: UInt8,
        remaining: Int,
        reusable: Bool,
        deadline: _Deadline,
        config: ClientConfig,
    ):
        self.trailers = Headers()
        self._lease = lease^
        self._kind = kind
        self._remaining = remaining
        self._finished = False
        self._reusable = reusable
        self._deadline = deadline.copy()
        self._buffer = pending^
        self._offset = 0
        self._chunk_state = 0
        self._chunk_remaining = 0
        self._chunk_metadata = 0
        self._trailer_bytes = 0
        self._max_chunk_metadata = config.max_chunk_metadata
        self._max_trailer_bytes = config.max_trailer_bytes
        self._max_trailer_count = config.max_trailer_count
        self._max_read_all = config.max_response_body
        self._close_timeout = config.idle_conn_timeout.copy()
        if kind == 3 or (kind == 0 and remaining == 0):
            self._finish()

    def _finish(mut self):
        self._finished = True
        self._lease.finish(self._reusable and self._offset == len(self._buffer))
        self._buffer.clear()
        self._offset = 0

    def _abort(mut self):
        self._finished = True
        self._lease.finish(False)
        self._buffer.clear()
        self._offset = 0

    def _fill(mut self, maximum: Int = 8192) raises ClientError -> Bool:
        if self._offset < len(self._buffer):
            return True
        var scratch = Array[Byte, 8192](fill=0)
        var count = self._lease.connection.value().read(
            Span(scratch)[: min(maximum, 8192)], self._deadline
        )
        self._buffer.clear()
        self._offset = 0
        self._buffer.extend(Span(scratch)[:count])
        return count > 0

    def _byte(mut self) raises ClientError -> Byte:
        if not self._fill():
            raise ClientError(ClientError.READ, "truncated chunked response")
        var byte = self._buffer[self._offset]
        self._offset += 1
        return byte

    def _line(mut self, limit: Int) raises ClientError -> List[Byte]:
        var line = List[Byte]()
        while True:
            if len(line) + 1 > limit:
                raise ClientError(
                    ClientError.BODY_TOO_LARGE,
                    "response chunk metadata or trailers exceed limit",
                )
            var byte = self._byte()
            if byte == Byte(ord("\n")):
                raise ClientError.parse("bare LF in response chunk framing")
            if byte == Byte(ord("\r")):
                if len(line) + 2 > limit:
                    raise ClientError(
                        ClientError.BODY_TOO_LARGE,
                        "response chunk metadata or trailers exceed limit",
                    )
                if self._byte() != Byte(ord("\n")):
                    raise ClientError.parse(
                        "invalid response chunk line ending"
                    )
                return line^
            line.append(byte)

    def _read_trailers(mut self) raises ClientError:
        while True:
            var line = self._line(
                self._max_trailer_bytes - self._trailer_bytes + 2
            )
            if len(line) == 0:
                self._finish()
                return
            self._trailer_bytes += len(line) + 2
            if self._trailer_bytes > self._max_trailer_bytes:
                raise ClientError(
                    ClientError.BODY_TOO_LARGE,
                    "response trailers exceed byte limit",
                )
            if len(self.trailers) >= self._max_trailer_count:
                raise ClientError(
                    ClientError.BODY_TOO_LARGE, "too many response trailers"
                )
            var colon = -1
            for i in range(len(line)):
                if line[i] == Byte(ord(":")):
                    colon = i
                    break
            if colon <= 0:
                raise ClientError.parse("invalid response trailer")
            var name = String(from_utf8_lossy=Span(line)[:colon])
            if not _is_token(name) or _trailer_forbidden(name):
                raise ClientError.parse(
                    "invalid or forbidden response trailer name"
                )
            var start = colon + 1
            var end = len(line)
            while start < end and (
                line[start] == Byte(ord(" ")) or line[start] == Byte(ord("\t"))
            ):
                start += 1
            while end > start and (
                line[end - 1] == Byte(ord(" "))
                or line[end - 1] == Byte(ord("\t"))
            ):
                end -= 1
            try:
                self.trailers.add_bytes(name^, Span(line)[start:end])
            except error:
                raise ClientError(
                    ClientError.PARSE, "invalid response trailer value", error^
                )

    def _copy_pending(mut self, mut buf: List[Byte], maximum: Int) -> Int:
        var count = min(
            len(buf), min(maximum, len(self._buffer) - self._offset)
        )
        for i in range(count):
            buf[i] = self._buffer[self._offset + i]
        self._offset += count
        return count

    def _read(mut self, mut buf: List[Byte]) raises ClientError -> Int:
        if self._finished or len(buf) == 0:
            return 0
        if self._deadline.expired():
            raise ClientError(
                ClientError.TIMEOUT, "response body deadline expired"
            )
        if self._kind == 0:
            if not self._fill(self._remaining):
                raise ClientError(ClientError.READ, "truncated response body")
            var count = self._copy_pending(buf, self._remaining)
            self._remaining -= count
            if self._remaining == 0:
                self._finish()
            return count
        if self._kind == 2:
            if not self._fill():
                self._finish()
                return 0
            return self._copy_pending(buf, len(buf))
        while True:
            if self._chunk_state == 0:
                var line = self._line(
                    self._max_chunk_metadata - self._chunk_metadata
                )
                self._chunk_metadata += len(line) + 2
                var size, extensions, has_extensions = _split_chunk_size(
                    String(from_utf8_lossy=line)
                )
                if has_extensions and not _chunk_ext_valid(extensions):
                    raise ClientError.parse("invalid response chunk extension")
                self._chunk_remaining = _parse_hex_size(size)
                if self._chunk_remaining < 0:
                    raise ClientError.parse("invalid response chunk size")
                if self._chunk_remaining == 0:
                    self._read_trailers()
                    return 0
                self._chunk_state = 1
            elif self._chunk_state == 2:
                if self._byte() != Byte(ord("\r")) or self._byte() != Byte(
                    ord("\n")
                ):
                    raise ClientError.parse(
                        "invalid response chunk data ending"
                    )
                self._chunk_state = 0
                continue
            if not self._fill(self._chunk_remaining):
                raise ClientError(ClientError.READ, "truncated response chunk")
            var count = self._copy_pending(buf, self._chunk_remaining)
            self._chunk_remaining -= count
            if self._chunk_remaining == 0:
                self._chunk_state = 2
            return count

    def read(mut self, mut buf: List[Byte]) raises ClientError -> Int:
        """Fills the existing buffer's prefix and returns its byte count."""
        try:
            return self._read(buf)
        except error:
            self._abort()
            raise error^

    def read_all(
        mut self, max_bytes: Int = -1
    ) raises ClientError -> List[Byte]:
        var limit = max_bytes
        if limit == -1:
            limit = self._max_read_all
        if limit < 0:
            self._abort()
            raise ClientError.parse(
                "response body read limit must be nonnegative"
            )
        if self._kind == 0 and self._remaining > limit:
            self._abort()
            raise ClientError(
                ClientError.BODY_TOO_LARGE,
                "response body exceeds read_all limit",
            )
        var out = List[Byte]()
        var buffer = List[Byte](length=8192, fill=0)
        while True:
            var count = self.read(buffer)
            if count == 0:
                return out^
            if count > limit - len(out):
                self._abort()
                raise ClientError(
                    ClientError.BODY_TOO_LARGE,
                    "response body exceeds read_all limit",
                )
            out.extend(Span(buffer)[:count])

    def discard(mut self) raises ClientError -> Int:
        var count = 0
        var buffer = List[Byte](length=8192, fill=0)
        while True:
            var received = self.read(buffer)
            if received == 0:
                return count
            count += received

    def close(mut self) raises ClientError:
        if self._finished:
            return
        if (
            self._kind == 0
            and self._remaining <= 65536
            and not self._deadline.expired()
        ):
            self._deadline = _phase_deadline(
                self._deadline, self._close_timeout
            )
            _ = self.discard()
        else:
            self._abort()


@fieldwise_init
struct Response(Movable):
    var status: Int
    var reason: String
    var version: HttpVersion
    var headers: Headers
    var body: ResponseBody

    def trailers(self) raises ClientError -> Headers:
        """Returns an owned snapshot; consume the body to receive trailers."""
        return _copy_client_headers(self.body.trailers)

    def read_all(
        mut self, max_bytes: Int = -1
    ) raises ClientError -> List[Byte]:
        return self.body.read_all(max_bytes)

    def read(mut self, mut buf: List[Byte]) raises ClientError -> Int:
        return self.body.read(buf)

    def close(mut self) raises ClientError:
        self.body.close()
