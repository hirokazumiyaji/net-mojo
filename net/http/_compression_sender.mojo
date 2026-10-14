"""Bounded gzip ownership around the detached response actor."""

from net.compress.zlib import GzipEncoder
from net.error import NetError, NetErrorKind
from ._buffer import _CapacityTicket
from ._compression_config import CompressionConfig
from ._compression_common import (
    _compression_error,
    _ensure_compression_vary,
    _compressible,
    _gzip_headers,
)
from ._detach import ResponseSender, _detach_state
from .headers import Headers, _declared_content_length, _trailer_forbidden


def _stream_encoder(
    var path: String, level: Int
) raises NetError -> GzipEncoder:
    try:
        return GzipEncoder(path^, level)
    except error:
        raise NetError(
            NetErrorKind.invalid_argument(),
            "create streaming gzip encoder",
            None,
            String(error),
        )


struct CompressingSender(Movable):
    """Owns at most one source chunk and one pending gzip output chunk."""

    var _inner: ResponseSender
    var _cfg: CompressionConfig
    var _provider: Optional[String]
    var _path: String
    var _is_head: Bool
    var _accepts_gzip: Bool
    var _encoder: Optional[GzipEncoder]
    var _input: List[Byte]
    var _output: List[Byte]
    var _input_ticket: _CapacityTicket
    var _output_ticket: _CapacityTicket
    var _input_count: Int
    var _input_offset: Int
    var _output_count: Int
    var _output_offset: Int
    var _wire_chunk: Int
    var _started: Bool
    var _finished: Bool
    var _finishing: Bool
    var _encoder_finished: Bool
    var _expected_source: Int
    var _source_seen: Int
    var _trailers: Headers

    def __init__(
        out self,
        var inner: ResponseSender,
        var cfg: CompressionConfig,
        var provider: Optional[String],
        var path: String,
        is_head: Bool,
        accepts_gzip: Bool,
    ):
        self._inner = inner^
        self._cfg = cfg^
        self._provider = provider^
        self._path = path^
        self._is_head = is_head
        self._accepts_gzip = accepts_gzip
        self._encoder = None
        self._input = List[Byte]()
        self._output = List[Byte]()
        var state = _detach_state(self._inner._addr)
        self._input_ticket = _CapacityTicket(state[].budget.copy())
        self._output_ticket = _CapacityTicket(state[].budget.copy())
        self._wire_chunk = min(self._cfg.buffer_size, state[].queue_limit)
        self._input_count = 0
        self._input_offset = 0
        self._output_count = 0
        self._output_offset = 0
        self._started = False
        self._finished = False
        self._finishing = False
        self._encoder_finished = False
        self._expected_source = -1
        self._source_seen = 0
        self._trailers = Headers()

    def __deinit__(deinit self):
        _ = self._input^
        _ = self._output^
        self._input_ticket.release()
        self._output_ticket.release()

    def is_active(self) -> Bool:
        return self._inner.is_active()

    def is_cancelled(mut self) -> Bool:
        if self._inner.is_cancelled():
            self.abort()
            return True
        return False

    def _drop_buffers(mut self):
        self._input = List[Byte]()
        self._output = List[Byte]()
        self._input_ticket.release()
        self._output_ticket.release()
        self._encoder = None
        self._input_count = 0
        self._output_count = 0

    def abort(mut self):
        self._inner.abort()
        self._finished = True
        self._drop_buffers()
        self._trailers = Headers()

    def start(
        mut self, status: Int = 200, var headers: Headers = Headers()
    ) raises NetError:
        if self._started or self._finished:
            raise _compression_error("response already started or finished")
        self._cfg.validate()
        self._expected_source = _declared_content_length(headers)
        if self._expected_source < -1:
            raise _compression_error("invalid source Content-Length")
        var gzip = Bool(self._provider) and _compressible(
            self._path,
            self._is_head,
            self._accepts_gzip,
            status,
            headers,
            self._expected_source,
            self._cfg,
        )
        try:
            if gzip:
                if self._wire_chunk <= 0:
                    raise _compression_error(
                        "stream queue has no byte capacity"
                    )
                if not self._input_ticket._try_reserve(self._cfg.buffer_size):
                    raise _compression_error(
                        "gzip source buffer exceeds budget"
                    )
                self._input = List[Byte](length=self._cfg.buffer_size, fill=0)
                if not self._output_ticket._try_reserve(self._cfg.buffer_size):
                    raise _compression_error(
                        "gzip output buffer exceeds budget"
                    )
                self._output = List[Byte](length=self._cfg.buffer_size, fill=0)
                self._encoder = _stream_encoder(
                    self._provider.value(), self._cfg.level
                )
                var state = _detach_state(self._inner._addr)
                headers = _gzip_headers(headers, state[].budget.copy())
            elif self._provider:
                _ensure_compression_vary(headers)
            self._inner.start(status, headers^)
            self._started = True
        except error:
            self.abort()
            raise error^

    def _drain_output(mut self) raises NetError -> Bool:
        while self._output_offset < self._output_count:
            var count = min(
                self._wire_chunk, self._output_count - self._output_offset
            )
            if not self._inner.try_send(
                Span(self._output)[
                    self._output_offset : self._output_offset + count
                ]
            ):
                return False
            self._output_offset += count
        self._output_offset = 0
        self._output_count = 0
        return True

    def _drive(mut self, finish: Bool) raises NetError -> Bool:
        while True:
            if not self._drain_output():
                return False
            if self._input_offset == self._input_count and (
                not finish or self._encoder_finished
            ):
                self._input_count = 0
                self._input_offset = 0
                return True
            var progress = self._encoder.value().process(
                Span(self._input)[self._input_offset : self._input_count],
                Span(self._output),
                finish=finish,
            )
            self._input_offset += progress.consumed
            self._output_count = progress.produced
            self._encoder_finished = progress.finished
            if (
                progress.consumed == 0
                and progress.produced == 0
                and not progress.finished
            ):
                raise _compression_error("gzip encoder made no progress")

    def send[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError -> Bool:
        if self._inner.is_cancelled():
            self.abort()
            return False
        if not self._started or self._finished or self._finishing:
            raise _compression_error("response is not accepting source bytes")
        if not self._encoder:
            return self._inner.try_send(data)
        if len(data) > self._cfg.buffer_size:
            raise _compression_error(
                "source chunk exceeds compression buffer size"
            )
        if (
            self._expected_source >= 0
            and len(data) > self._expected_source - self._source_seen
        ):
            self.abort()
            raise _compression_error("body exceeds source Content-Length")
        try:
            if not self._drive(False):
                return False
            for i in range(len(data)):
                self._input[i] = data[i]
            self._input_count = len(data)
            self._input_offset = 0
            self._source_seen += len(data)
            _ = self._drive(False)
            return True
        except error:
            self.abort()
            raise error^

    def finish(
        mut self, var trailers: Headers = Headers()
    ) raises NetError -> Bool:
        if self._inner.is_cancelled():
            self.abort()
            raise NetError(
                NetErrorKind.closed(),
                "finish compressed response",
                None,
                "response was cancelled",
            )
        if not self._started or self._finished:
            raise _compression_error("response is not awaiting finish")
        if not self._encoder:
            self._inner.finish(trailers^)
            self._finished = True
            return True
        try:
            if not self._finishing:
                if (
                    self._expected_source >= 0
                    and self._source_seen != self._expected_source
                ):
                    raise _compression_error(
                        "body does not match source Content-Length"
                    )
                for i in range(len(trailers)):
                    if _trailer_forbidden(trailers.name_at(i)):
                        raise _compression_error("forbidden trailer field")
                var state = _detach_state(self._inner._addr)
                if not trailers._adopt_capacity_budget(state[].budget.copy()):
                    raise _compression_error("trailer capacity exceeds budget")
                self._trailers = trailers^
                self._finishing = True
            elif len(trailers) > 0:
                raise _compression_error(
                    "trailers must be supplied only on first finish"
                )
            if not self._drive(True):
                if self._inner.is_cancelled():
                    raise NetError(
                        NetErrorKind.closed(),
                        "finish compressed response",
                        None,
                        "response was cancelled",
                    )
                return False
            var final_trailers = self._trailers^
            self._trailers = Headers()
            self._inner.finish(final_trailers^)
            self._finished = True
            self._drop_buffers()
            return True
        except error:
            self.abort()
            raise error^
