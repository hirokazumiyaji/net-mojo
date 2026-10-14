"""Opt-in buffered HTTP gzip middleware with a dynamically loaded provider."""

from net.compress.zlib import GzipEncoder

from ._buffer import _CapacityTicket
from ._compression_config import CompressionConfig, negotiate_encoding
from ._compression_common import (
    _compression_error,
    _ensure_compression_vary,
    _accepts_gzip,
    _compressible,
    _gzip_headers,
)
from .handler import Handler
from .headers import _declared_content_length
from .request import Request
from .response import ResponseWriter
from ._compression_sender import CompressingSender


@fieldwise_init
struct CompressionHandler[Inner: Handler & Deinitable](Handler):
    """Compress eligible buffered responses; an absent provider is pass-through.
    """

    var inner: Self.Inner
    var cfg: CompressionConfig
    var provider_library_path: Optional[String]

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        self.cfg.validate()
        self.inner.handle(req, writer)
        if not self.provider_library_path or writer.is_detached():
            return
        if not _compressible(
            req.path,
            req.method == "HEAD",
            _accepts_gzip(req.headers),
            writer.status,
            writer.headers,
            len(writer.body),
            self.cfg,
        ):
            _ensure_compression_vary(writer.headers)
            return
        if len(writer.body) > writer.body_limit():
            raise _compression_error("source body exceeds response limit")
        var declared = _declared_content_length(writer.headers)
        if declared < -1 or (declared >= 0 and declared != len(writer.body)):
            raise _compression_error(
                "Content-Length does not match source body"
            )
        if declared >= 0 and len(writer.trailers) > 0:
            raise _compression_error(
                "Content-Length is not permitted with trailers"
            )
        var budget = writer._body_budget.copy()
        if not budget:
            budget = writer._mailbox_budget.copy()
        var source_ticket = _CapacityTicket(budget.copy())
        if writer._body_budget:
            if not writer._reconcile_body_budget():
                raise _compression_error("source body capacity exceeds budget")
        elif not source_ticket._try_reserve(writer.body.capacity()):
            raise _compression_error("source body capacity exceeds budget")
        var encoder = GzipEncoder(
            self.provider_library_path.value(), self.cfg.level
        )
        var bound = encoder.bound(len(writer.body))
        var output_ticket = _CapacityTicket(budget.copy())
        if not output_ticket._try_reserve(bound):
            raise _compression_error("compressed body capacity exceeds budget")
        var output = List[Byte](length=bound, fill=0)
        var read = 0
        var written = 0
        var finished = False
        while not finished:
            var count = min(self.cfg.buffer_size, len(writer.body) - read)
            var room = min(self.cfg.buffer_size, bound - written)
            var progress = encoder.process(
                Span(writer.body)[read : read + count],
                Span(output)[written : written + room],
                finish=read + count == len(writer.body),
            )
            if (
                progress.consumed == 0
                and progress.produced == 0
                and not progress.finished
            ):
                raise _compression_error("gzip encoder made no progress")
            read += progress.consumed
            written += progress.produced
            finished = progress.finished
        if written > writer.body_limit():
            raise _compression_error("compressed body exceeds response limit")
        output.resize(written, fill=0)
        var headers = _gzip_headers(writer.headers, budget^)
        writer._swap_body(output^, output_ticket^)
        writer.headers = headers^
        source_ticket.release()
