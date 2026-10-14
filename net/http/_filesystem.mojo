"""Pinned filesystem roots and confined descriptor resolution."""

from std.memory import ArcPointer

from net._sys.common import _OwnedFD
from net._sys.file import (
    _AT_FDCWD,
    _ELOOP,
    _MAX_NAME_BYTES,
    _file_argument,
    _file_directory_entries,
    _file_pread,
    _file_readlink_at,
    _file_realpath,
    _file_stat,
    _open_file_at,
)
from net.error import NetError


@fieldwise_init
struct _Root(Movable):
    var fd: _OwnedFD
    var path: String
    var follow_symlinks: Bool


def _segments(
    path: StringSlice, link: Bool = False
) raises NetError -> List[String]:
    var bytes = path.as_bytes()
    if len(bytes) > 4096:
        raise _file_argument("path exceeds limit")
    for byte in bytes:
        if byte == 0:
            raise _file_argument("NUL in path")
    if not link:
        for i in range(1, len(bytes)):
            if bytes[i - 1] == 47 and bytes[i] == 47:
                raise _file_argument("empty path segment")
    var segments = List[String]()
    var start = 1 if len(bytes) > 0 and bytes[0] == 47 else 0
    var end = len(bytes)
    if end > start and bytes[end - 1] == 47:
        end -= 1
    var cursor = start
    while cursor <= end and start < end:
        if cursor == end or bytes[cursor] == 47:
            var length = cursor - start
            var segment = String(from_utf8_lossy=bytes[start:cursor])
            if length > _MAX_NAME_BYTES:
                raise _file_argument("path segment exceeds limit")
            if not link and (length == 0 or segment == "." or segment == ".."):
                raise _file_argument("invalid path segment")
            if length > 0:
                segments.append(segment^)
            start = cursor + 1
        cursor += 1
    return segments^


def _clone_directories(
    directories: List[_OwnedFD],
) raises NetError -> List[_OwnedFD]:
    var copies = List[_OwnedFD]()
    for i in range(len(directories)):
        copies.append(_open_file_at(directories[i].raw(), ".", True))
    return copies^


struct FileSystem(Copyable):
    """Shared pinned root; optional symlink traversal remains within that root.
    """

    var _root: ArcPointer[_Root]

    def __init__(out self, var root: ArcPointer[_Root]):
        self._root = root^

    @staticmethod
    def dir(
        path: StringSlice, follow_symlinks: Bool = False
    ) raises NetError -> Self:
        var canonical = _file_realpath(path)
        var fd = _open_file_at(_AT_FDCWD, canonical, True)
        return Self(
            ArcPointer(
                _Root(fd=fd^, path=canonical^, follow_symlinks=follow_symlinks)
            )
        )

    def open(self, path: StringSlice) raises NetError -> _File:
        var segments = _segments(path)
        var bytes = path.as_bytes()
        if len(bytes) > 0 and bytes[len(bytes) - 1] == 47:
            segments.append(".")
        var directories = List[_OwnedFD]()
        directories.append(_open_file_at(self._root[].fd.raw(), ".", True))
        return _resolve(self._root.copy(), directories^, segments^)


@fieldwise_init
struct _File(Movable):
    var _fd: _OwnedFD
    var _root: ArcPointer[_Root]
    var _parents: List[_OwnedFD]
    var size: Int64
    var mtime_ns: Int64
    var is_directory: Bool

    def pread[
        origin: MutOrigin
    ](self, buffer: Span[Byte, origin], offset: Int64) raises NetError -> Int:
        if self.is_directory:
            raise _file_argument("cannot read a directory")
        return _file_pread(self._fd.raw(), buffer, offset)

    def list_entries(
        self, max_entries: Int = 256
    ) raises NetError -> List[String]:
        if not self.is_directory:
            raise _file_argument("listing requires a directory")
        return _file_directory_entries(self._fd.raw(), max_entries)

    def open_index(self, name: StringSlice) raises NetError -> Self:
        if not self.is_directory:
            raise _file_argument("index requires a directory")
        var segments = _segments(name)
        if (
            len(segments) != 1
            or name.as_bytes()[0] == 47
            or name.as_bytes()[len(name.as_bytes()) - 1] == 47
        ):
            raise _file_argument("index must be one relative segment")
        var directories = _clone_directories(self._parents)
        directories.append(_open_file_at(self._fd.raw(), ".", True))
        return _resolve(self._root.copy(), directories^, segments^)


def _resolved_file(
    var root: ArcPointer[_Root], var parents: List[_OwnedFD], var fd: _OwnedFD
) raises NetError -> _File:
    var metadata = _file_stat(fd.raw())
    if not metadata.is_regular() and not metadata.is_directory():
        raise _file_argument("not a regular file or directory")
    if metadata.size < 0:
        raise _file_argument("negative file size")
    var mtime = (
        metadata.mtime_seconds * 1_000_000_000 + metadata.mtime_nanoseconds
    )
    if metadata.is_regular():
        parents = List[_OwnedFD]()
    return _File(
        _fd=fd^,
        _root=root^,
        _parents=parents^,
        size=metadata.size,
        mtime_ns=mtime,
        is_directory=metadata.is_directory(),
    )


def _resolve(
    var root: ArcPointer[_Root],
    var directories: List[_OwnedFD],
    var pending: List[String],
) raises NetError -> _File:
    var cursor = 0
    var links = 0
    var expanded_bytes = 0
    for segment in pending:
        expanded_bytes += segment.byte_length() + 1
    while cursor < len(pending):
        var segment = pending[cursor].copy()
        cursor += 1
        if segment == ".":
            continue
        if segment == "..":
            if len(directories) == 1:
                raise _file_argument("symlink escapes root")
            _ = directories.pop()
            continue
        var parent_fd = directories[len(directories) - 1].raw()
        var opened: _OwnedFD
        try:
            opened = _open_file_at(parent_fd, segment)
        except error:
            if not root[].follow_symlinks or not error.has_errno(_ELOOP):
                raise error^
            var target = _file_readlink_at(parent_fd, segment)
            var trailing_directory = (
                target.as_bytes()[target.byte_length() - 1] == 47
            )
            links += 1
            expanded_bytes += target.byte_length()
            if links > 40 or expanded_bytes > 4096:
                raise _file_argument("symlink expansion exceeds limit")
            if target.as_bytes()[0] == 47:
                var root_path = root[].path.copy()
                if root_path == "/":
                    var relative = String(target[byte=1:])
                    target = relative^
                elif target == root_path:
                    target = ""
                elif target.startswith(root_path + "/"):
                    var relative = String(
                        target[byte = root_path.byte_length() + 1 :]
                    )
                    target = relative^
                else:
                    raise _file_argument("absolute symlink escapes root")
                directories = List[_OwnedFD]()
                directories.append(_open_file_at(root[].fd.raw(), ".", True))
            var replacement = _segments(target, True)
            if trailing_directory and cursor == len(pending):
                replacement.append(".")
            for i in range(cursor, len(pending)):
                replacement.append(pending[i].copy())
            pending = replacement^
            cursor = 0
            continue
        var metadata = _file_stat(opened.raw())
        if cursor < len(pending):
            if not metadata.is_directory():
                raise _file_argument("intermediate path is not a directory")
            directories.append(opened^)
        else:
            return _resolved_file(root^, directories^, opened^)
    var leaf = directories.pop()
    return _resolved_file(root^, directories^, leaf^)
