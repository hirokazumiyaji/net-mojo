"""Opt-in buffered HTTP gzip middleware with a dynamically loaded provider."""

from net.compress.zlib import GzipEncoder
from net.error import NetError, NetErrorKind

from ._buffer import SharedBufferBudget, _CapacityTicket
from ._compression_config import CompressionConfig, negotiate_encoding
from .handler import Handler
from .headers import Headers, _declared_content_length
from .request import Request
from .response import ResponseWriter, has_body_for_status


def _compression_error(var message: String) -> NetError:
    return NetError(
        NetErrorKind.invalid_argument(),
        "compress response body",
        None,
        message^,
    )


def _ensure_compression_vary(mut headers: Headers) raises NetError:
    var values = headers.get_all("Vary")
    for value in values:
        for part in value.split(","):
            var token = String(part).strip(" \t").lower()
            if token == "accept-encoding" or token == "*":
                return
    headers.add("Vary", "Accept-Encoding")


def _accepts_gzip(headers: Headers) -> Bool:
    var values = headers.get_all("Accept-Encoding")
    var joined = String("")
    for i in range(len(values)):
        if i > 0:
            joined += ","
        joined += values[i]
    var supported: List[String] = ["gzip"]
    return Bool(negotiate_encoding(joined, supported))


def _compressible(
    req: Request, writer: ResponseWriter, cfg: CompressionConfig
) -> Bool:
    if (
        not has_body_for_status(writer.status, req.method == "HEAD")
        or writer.status == 206
    ):
        return False
    if (
        len(writer.body) < cfg.min_size
        or writer.headers.count("Content-Encoding") > 0
    ):
        return False
    var path = req.path.lower()
    for extension in cfg.skip_extensions:
        if path.endswith(extension):
            return False
    var content_type = writer.headers.get_first("Content-Type")
    if content_type:
        var parts = content_type.value().split(";")
        var media_type = String(parts[0]).strip(" \t").lower()
        for excluded in cfg.skip_content_types:
            if media_type == excluded:
                return False
        for prefix in cfg.skip_content_type_prefixes:
            if media_type.startswith(prefix):
                return False
    return _accepts_gzip(req.headers)


def _gzip_headers(
    headers: Headers, var budget: Optional[SharedBufferBudget]
) raises NetError -> Headers:
    var result = Headers()
    if not result._adopt_capacity_budget(budget^):
        raise _compression_error("response header capacity exceeds budget")
    for i in range(len(headers)):
        var name = headers.name_at(i)
        if name.lower() == "content-length":
            continue
        var value = headers.value_bytes_at(i)
        var tag_start = 0
        if name.lower() == "etag":
            while tag_start < len(value) and (
                value[tag_start] == Byte(32) or value[tag_start] == Byte(9)
            ):
                tag_start += 1
        if (
            name.lower() == "etag"
            and tag_start < len(value)
            and value[tag_start] == Byte(34)
        ):
            var weak = List[Byte](capacity=len(value) + 2)
            for j in range(tag_start):
                weak.append(value[j])
            weak.append(Byte(87))
            weak.append(Byte(47))
            for j in range(tag_start, len(value)):
                weak.append(value[j])
            result.add_bytes(name^, Span(weak))
        else:
            result.add_bytes(name^, Span(value))
    result.add("Content-Encoding", "gzip")
    _ensure_compression_vary(result)
    return result^


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
        if not _compressible(req, writer, self.cfg):
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
