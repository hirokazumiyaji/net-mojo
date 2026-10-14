"""Confined static files with bounded buffered and worker-streamed responses."""

from std.ffi import c_int, c_ulong, external_call
from std.memory import OwnedPointer
from std.time import sleep

from net._sys.common import _OwnedFD
from net._sys.file import _ELOOP, _file_argument, _file_pread
from net.error import NetError, NetErrorKind
from ._detach import ResponseSender
from ._encoder import http_date
from ._file_http import (
    _conditional_status,
    _mtime_seconds,
    _parse_http_date,
    _parse_range,
)
from ._filesystem import FileSystem, _File, _segments
from ._mimetype import _mime_type
from ._offload import HandlerJob, WorkerPool, WorkerPoolConfig
from .handler import Handler
from .headers import Headers
from .request import Request
from .response import ResponseWriter
from .router import ServeMux


@fieldwise_init
struct FileETagMode(Copyable, Equatable):
    var value: UInt8

    @staticmethod
    def mtime_size() -> Self:
        return Self(0)

    @staticmethod
    def disabled() -> Self:
        return Self(1)


struct FileServerConfig(Copyable):
    var index_files: List[String]
    var allow_directory_listing: Bool
    var cache_control: String
    var etag_mode: FileETagMode
    var max_in_memory_body: Int
    var max_file_size: Int
    var workers: Int
    var queue_limit: Int

    def __init__(
        out self,
        var index_files: List[String] = ["index.html"],
        allow_directory_listing: Bool = False,
        cache_control: StringSlice = "",
        etag_mode: FileETagMode = FileETagMode.mtime_size(),
        max_in_memory_body: Int = 65536,
        max_file_size: Int = 1073741824,
        workers: Int = 2,
        queue_limit: Int = 64,
    ) raises NetError:
        if (
            max_in_memory_body < 0
            or max_file_size < 0
            or workers < 1
            or queue_limit < 0
        ):
            raise _file_argument("invalid file server limit")
        for name in index_files:
            var parts = _segments(name)
            if len(parts) != 1 or name.find("/") >= 0:
                raise _file_argument("index must be one relative segment")
        var validation = Headers()
        validation.add("Cache-Control", String(cache_control))
        self.index_files = index_files^
        self.allow_directory_listing = allow_directory_listing
        self.cache_control = String(cache_control)
        self.etag_mode = etag_mode.copy()
        self.max_in_memory_body = max_in_memory_body
        self.max_file_size = max_file_size
        self.workers = workers
        self.queue_limit = queue_limit


def _safe_http_path(path: StringSlice) -> Bool:
    for byte in path.as_bytes():
        if byte == 0 or byte == 92:
            return False
    for part in path.split("/"):
        if part == "." or part == "..":
            return False
    return True


def _canonical_path(path: StringSlice) -> String:
    var result = List[Byte]()
    var slash = False
    for byte in path.as_bytes():
        if byte != 47 or not slash:
            result.append(byte)
        slash = byte == 47
    return String(from_utf8_lossy=Span(result))


def _merged_headers(
    existing: Headers, cfg: FileServerConfig
) raises NetError -> Headers:
    var result = Headers()
    for i in range(len(existing)):
        var name = existing.name_at(i)
        var lower = name.lower()
        if (
            lower == "content-length"
            or lower == "content-range"
            or lower == "content-type"
            or lower == "etag"
            or lower == "last-modified"
            or lower == "accept-ranges"
            or (
                lower == "cache-control" and cfg.cache_control.byte_length() > 0
            )
        ):
            continue
        result.add_bytes(name^, existing._value_bytes_span(i))
    if cfg.cache_control.byte_length() > 0:
        result.add("Cache-Control", cfg.cache_control.copy())
    return result^


def _empty_response(mut writer: ResponseWriter, status: Int):
    writer._drop_body()
    writer.headers = Headers()
    writer.status = status


def _open_status(error: NetError) -> Int:
    if (
        error.kind == NetErrorKind.invalid_argument()
        or error.has_errno(2)
        or error.has_errno(13)
        or error.has_errno(20)
        or error.has_errno(_ELOOP)
    ):
        return 404
    return 500


def _redirect(
    req: Request, mut writer: ResponseWriter, path: StringSlice
) raises NetError:
    _empty_response(writer, 301)
    var location = String(path)
    if req.target.find("?") >= 0:
        location += "?" + req.query
    writer.headers.add("Location", location^)


def _escape_name(value: StringSlice) -> String:
    var escaped = String("")
    for cp in value.codepoint_slices():
        var byte = Int(cp.as_bytes()[0])
        if byte == 10:
            escaped += "\\n"
        elif byte == 13:
            escaped += "\\r"
        elif byte == 9:
            escaped += "\\t"
        elif byte == 92:
            escaped += "\\\\"
        elif byte < 32 or byte == 127:
            escaped += (
                "\\x"
                + String("0123456789abcdef"[byte=byte // 16])
                + String("0123456789abcdef"[byte=byte % 16])
            )
        else:
            escaped += String(cp)
    return escaped^


def _listing(
    req: Request, mut writer: ResponseWriter, file: _File, cfg: FileServerConfig
) raises NetError:
    writer._drop_body()
    var names = file.list_entries()
    var body = String("")
    for name in names:
        body += _escape_name(name) + "\n"
    var headers = _merged_headers(writer.headers, cfg)
    headers.add("Content-Type", "text/plain; charset=utf-8")
    headers.add("Content-Length", String(body.byte_length()))
    if req.method != "HEAD":
        writer.write_string(body)
    writer.headers = headers^
    writer.status = 200


def _read_chunk[
    origin: MutOrigin
](
    fd: Int32, prefix: List[Byte], buffer: Span[Byte, origin], offset: Int
) raises NetError -> Int:
    if offset < len(prefix):
        var count = min(len(buffer), len(prefix) - offset)
        for i in range(count):
            buffer[i] = prefix[offset + i]
        return count
    var count = _file_pread(fd, buffer, Int64(offset))
    if count == 0:
        raise NetError(
            NetErrorKind.system_error(),
            "serve file",
            None,
            "file truncated while reading",
        )
    return count


@fieldwise_init
struct _FileJob(HandlerJob):
    var fd: _OwnedFD
    var headers: Headers
    var prefix: List[Byte]
    var status: Int
    var offset: Int
    var remaining: Int
    var chunk_size: Int

    def run(mut self, mut sender: ResponseSender) raises:
        if sender.is_cancelled():
            return
        var headers = self.headers^
        self.headers = Headers()
        sender.start(self.status, headers^)
        var buffer = List[Byte](capacity=self.chunk_size)
        buffer.resize(self.chunk_size, 0)
        while self.remaining > 0:
            if sender.is_cancelled():
                return
            var count = _read_chunk(
                self.fd.raw(),
                self.prefix,
                Span(buffer)[: min(self.chunk_size, self.remaining)],
                self.offset,
            )
            while not sender.try_send(Span(buffer)[:count]):
                if sender.is_cancelled():
                    return
                sleep(0.001)
            self.offset += count
            self.remaining -= count
        sender.finish()


def _prepare_file(
    req: Request,
    mut writer: ResponseWriter,
    var file: _File,
    path: StringSlice,
    cfg: FileServerConfig,
) raises NetError -> Optional[_FileJob]:
    writer._drop_body()
    if file.size > Int64(cfg.max_file_size):
        _empty_response(writer, 404)
        return None
    var total = Int(file.size)
    var etag = String("")
    if cfg.etag_mode == FileETagMode.mtime_size():
        etag = 'W/"' + String(file.mtime_ns) + "-" + String(total) + '"'
    var headers = _merged_headers(writer.headers, cfg)
    if etag.byte_length() > 0:
        headers.add("ETag", etag.copy())
    headers.add("Last-Modified", http_date(_mtime_seconds(file.mtime_ns)))
    headers.add("Accept-Ranges", "bytes")
    var status = _conditional_status(req.headers, etag, file.mtime_ns)
    if status != 200:
        writer._drop_body()
        writer.status = status
        writer.headers = headers^
        return None
    var selected = _parse_range("", total)
    var ranges = req.headers.get_all("Range")
    if req.method == "GET" and len(ranges) == 1:
        var allow = True
        var if_range = req.headers.get_all("If-Range")
        if len(if_range) > 0:
            allow = False
            if len(if_range) == 1:
                var date = _parse_http_date(if_range[0])
                allow = date and date.value() == _mtime_seconds(file.mtime_ns)
        if allow:
            selected = _parse_range(ranges[0], total)
    if selected.status == 416:
        writer._drop_body()
        writer.status = 416
        headers.add("Content-Range", "bytes */" + String(total))
        writer.headers = headers^
        return None
    var prefix = List[Byte](capacity=min(512, total))
    prefix.resize(min(512, total), 0)
    if total > 0:
        var count = file.pread(Span(prefix), 0)
        prefix.resize(count, 0)
    headers.add("Content-Type", _mime_type(path, Span(prefix)))
    headers.add("Content-Length", String(selected.length))
    if selected.status == 206:
        headers.add(
            "Content-Range",
            "bytes "
            + String(selected.start)
            + "-"
            + String(selected.start + selected.length - 1)
            + "/"
            + String(total),
        )
    if req.method == "HEAD":
        writer._drop_body()
        writer.headers = headers^
        writer.status = selected.status
        return None
    if selected.length <= min(cfg.max_in_memory_body, writer.body_limit()):
        var body = List[Byte](capacity=selected.length)
        body.resize(selected.length, 0)
        var offset = 0
        while offset < selected.length:
            offset += _read_chunk(
                file._fd.raw(),
                prefix,
                Span(body)[offset:],
                selected.start + offset,
            )
        writer.write(Span(body))
        writer.headers = headers^
        writer.status = selected.status
        return None
    if writer._queue_limit < 1:
        raise _file_argument("stream queue must be positive")
    return Optional(
        _FileJob(
            _OwnedFD(file._fd._take()),
            headers^,
            prefix^,
            selected.status,
            selected.start,
            selected.length,
            min(65536, writer._queue_limit),
        )
    )


struct FileServer(Handler):
    """Static file handler owning a confined root and a bounded worker pool."""

    var _fs: FileSystem
    var _config: FileServerConfig
    var _pool: WorkerPool

    def __init__(out self, var fs: FileSystem) raises NetError:
        self = Self(fs^, FileServerConfig())

    def __init__(
        out self,
        var fs: FileSystem,
        var config: FileServerConfig,
    ) raises NetError:
        self._pool = WorkerPool(
            WorkerPoolConfig(
                workers=config.workers, queue_limit=config.queue_limit
            )
        )
        self._fs = fs^
        self._config = config^

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.method != "GET" and req.method != "HEAD":
            _empty_response(writer, 405)
            writer.headers.add("Allow", "GET, HEAD")
            return
        var path_param = ServeMux.param(req, "path")
        var selected = path_param.value() if path_param else req.path.copy()
        if not _safe_http_path(req.path) or not _safe_http_path(selected):
            _empty_response(writer, 404)
            return
        var canonical = _canonical_path(req.path)
        if canonical != req.path:
            _redirect(req, writer, canonical)
            return
        var lookup = String(selected.removesuffix("/"))
        var file: _File
        try:
            file = self._fs.open(lookup)
        except error:
            _empty_response(writer, _open_status(error))
            return
        try:
            if file.is_directory:
                if not req.path.endswith("/"):
                    _redirect(req, writer, req.path + "/")
                    return
                for index in self._config.index_files:
                    var candidate: _File
                    try:
                        candidate = file.open_index(index)
                    except error:
                        if _open_status(error) == 500:
                            _empty_response(writer, 500)
                            return
                        continue
                    if candidate.is_directory:
                        continue
                    var job = _prepare_file(
                        req, writer, candidate^, index, self._config
                    )
                    if job:
                        _ = writer.offload(self._pool, job.take())
                    return
                if self._config.allow_directory_listing:
                    _listing(req, writer, file, self._config)
                else:
                    _empty_response(writer, 404)
                return
            if req.path.endswith("/"):
                _redirect(req, writer, String(req.path.removesuffix("/")))
                return
            var job = _prepare_file(req, writer, file^, lookup, self._config)
            if job:
                _ = writer.offload(self._pool, job.take())
        except error:
            if writer.is_detached():
                writer._cancel_detach()
            else:
                _empty_response(writer, 500)


@fieldwise_init
struct _FileThreadContext(Movable):
    var job: _FileJob
    var sender: ResponseSender


def _file_thread_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var owner = OwnedPointer[_FileThreadContext](
        unsafe_from_raw_pointer=arg.unsafe_bitcast[_FileThreadContext]()
    )
    try:
        owner[].job.run(owner[].sender)
    except:
        owner[].sender.abort()
    return arg


def _start_file_thread(
    thread: Pointer[UInt64, MutUntrackedOrigin],
    context: Pointer[Byte, MutUntrackedOrigin],
) -> Int:
    return Int(
        external_call["pthread_create", c_int](
            thread,
            Optional[Pointer[Byte, MutUntrackedOrigin]](None),
            _file_thread_entry,
            context,
        )
    )


def _launch_file_job[
    start_thread: def(
        Pointer[UInt64, MutUntrackedOrigin], Pointer[Byte, MutUntrackedOrigin]
    ) thin -> Int = _start_file_thread
](mut writer: ResponseWriter, var job: _FileJob) raises NetError:
    var sender = writer.detach()
    var owner = OwnedPointer(_FileThreadContext(job^, sender^))
    var thread: UInt64 = 0
    var result = start_thread(
        Pointer(to=thread).unsafe_origin_cast[MutUntrackedOrigin](),
        owner.ptr()
        .unsafe_bitcast[Byte]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if result != 0:
        owner[].sender.respond(status=500)
        return
    _ = owner^.unsafe_take_allocation().unsafe_leak()
    _ = external_call["pthread_detach", c_int](c_ulong(thread))


def serve_file(
    req: Request, mut writer: ResponseWriter, fs: FileSystem, path: StringSlice
) raises:
    """Serves one confined path; large bodies use an independently owned thread.
    """
    if req.method != "GET" and req.method != "HEAD":
        _empty_response(writer, 405)
        writer.headers.add("Allow", "GET, HEAD")
        return
    var cfg = FileServerConfig()
    var file: _File
    try:
        file = fs.open(path)
    except error:
        _empty_response(writer, _open_status(error))
        return
    if file.is_directory:
        _empty_response(writer, 404)
        return
    try:
        var job = _prepare_file(req, writer, file^, path, cfg)
        if not job:
            return
        _launch_file_job(writer, job.take())
    except:
        if writer.is_detached():
            writer._cancel_detach()
        else:
            _empty_response(writer, 500)


def file_server(root: StringSlice) raises NetError -> FileServer:
    """Creates the default confined static file handler for a directory."""
    return FileServer(FileSystem.dir(root))
