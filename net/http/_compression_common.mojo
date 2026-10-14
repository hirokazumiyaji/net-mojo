"""Shared gzip negotiation, selection, and representation headers."""
from net.error import NetError, NetErrorKind
from ._buffer import SharedBufferBudget
from ._compression_config import CompressionConfig, negotiate_encoding
from .headers import Headers


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
    path: String,
    is_head: Bool,
    accepts_gzip: Bool,
    status: Int,
    headers: Headers,
    source_length: Int,
    cfg: CompressionConfig,
) -> Bool:
    if (
        is_head
        or status < 200
        or status == 204
        or status == 205
        or status == 304
        or status == 206
    ):
        return False
    if (source_length >= 0 and source_length < cfg.min_size) or headers.count(
        "Content-Encoding"
    ) > 0:
        return False
    var lower_path = path.lower()
    for extension in cfg.skip_extensions:
        if lower_path.endswith(extension):
            return False
    var content_type = headers.get_first("Content-Type")
    if content_type:
        var parts = content_type.value().split(";")
        var media_type = String(parts[0]).strip(" \t").lower()
        for excluded in cfg.skip_content_types:
            if media_type == excluded:
                return False
        for prefix in cfg.skip_content_type_prefixes:
            if media_type.startswith(prefix):
                return False
    return accepts_gzip


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
