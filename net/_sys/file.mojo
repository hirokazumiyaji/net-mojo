"""Descriptor-only file operations for confined static content."""

from std.ffi import (
    c_int,
    c_size_t,
    c_ssize_t,
    external_call,
    get_errno,
    set_errno,
)
from std.sys import CompilationTarget
from std.sys.info import is_64bit

from net._sys.common import EINTR, O_NONBLOCK, _OwnedFD, _system_error
from net.error import NetError, NetErrorKind

comptime _DARWIN = CompilationTarget.is_macos()
comptime _ARM = CompilationTarget.is_arm()
comptime _AT_FDCWD: Int32 = -2 if _DARWIN else -100
comptime _ELOOP: Int32 = 62 if _DARWIN else 40
comptime _O_DIRECTORY: Int32 = Int32(
    0x100000 if _DARWIN else (0o40000 if _ARM else 0o200000)
)
comptime _O_NOFOLLOW: Int32 = Int32(
    0x100 if _DARWIN else (0o100000 if _ARM else 0o400000)
)
comptime _O_CLOEXEC: Int32 = 0x1000000 if _DARWIN else 0o2000000
comptime _READ_FLAGS: Int32 = _O_NOFOLLOW | _O_CLOEXEC | O_NONBLOCK
comptime _S_IFMT: UInt32 = 0o170000
comptime _S_IFREG: UInt32 = 0o100000
comptime _S_IFDIR: UInt32 = 0o40000
comptime _STAT_WORDS: Int = 18 if _DARWIN or not _ARM else 16
comptime _MAX_NAME_BYTES: Int = 255


@fieldwise_init
struct _FileStat(Copyable):
    var mode: UInt32
    var size: Int64
    var mtime_seconds: Int64
    var mtime_nanoseconds: Int64

    def is_directory(self) -> Bool:
        return self.mode & _S_IFMT == _S_IFDIR

    def is_regular(self) -> Bool:
        return self.mode & _S_IFMT == _S_IFREG


def _file_argument(message: String) -> NetError:
    return NetError(NetErrorKind.invalid_argument(), "file", None, message)


def _open_file_at(
    fd: Int32, name: StringSlice, directory: Bool = False
) raises NetError -> _OwnedFD:
    var owned_name = String(name)
    var c_name = owned_name.as_c_string_span()
    var flags = _READ_FLAGS | (_O_DIRECTORY if directory else Int32(0))
    while True:
        var result = external_call["openat", c_int, num_fixed_args=3](
            c_int(fd), c_name.ptr(), c_int(flags)
        )
        if result >= 0:
            return _OwnedFD(result)
        var number = get_errno().value
        if number != EINTR:
            raise _system_error("openat", number)


def _file_stat(fd: Int32) raises NetError -> _FileStat:
    comptime assert (
        is_64bit()
        and (CompilationTarget.is_macos() or CompilationTarget.is_linux())
        and (_ARM or CompilationTarget.is_x86())
    ), "unsupported file stat ABI"
    var storage = Array[UInt64, _STAT_WORDS](fill=0)
    var bytes = Pointer(to=storage).unsafe_bitcast[Byte]()
    while external_call["fstat", c_int](c_int(fd), bytes) != 0:
        var number = get_errno().value
        if number != EINTR:
            raise _system_error("fstat", number)
    var mode: UInt32
    comptime if _DARWIN:
        mode = UInt32(
            bytes.unsafe_offset(4).unsafe_bitcast[UInt16]().unsafe_load()
        )
    else:
        mode = (
            bytes.unsafe_offset(16 if _ARM else 24)
            .unsafe_bitcast[UInt32]()
            .unsafe_load()
        )
    var size = (
        bytes.unsafe_offset(96 if _DARWIN else 48)
        .unsafe_bitcast[Int64]()
        .unsafe_load()
    )
    var seconds = (
        bytes.unsafe_offset(48 if _DARWIN else 88)
        .unsafe_bitcast[Int64]()
        .unsafe_load()
    )
    var nanos = (
        bytes.unsafe_offset(56 if _DARWIN else 96)
        .unsafe_bitcast[Int64]()
        .unsafe_load()
    )
    return _FileStat(
        mode=mode, size=size, mtime_seconds=seconds, mtime_nanoseconds=nanos
    )


def _file_pread[
    origin: MutOrigin
](fd: Int32, buffer: Span[Byte, origin], offset: Int64) raises NetError -> Int:
    if offset < 0:
        raise _file_argument("negative read offset")
    while True:
        var result = external_call["pread", c_ssize_t](
            c_int(fd), buffer.unsafe_ptr(), c_size_t(len(buffer)), offset
        )
        if result >= 0:
            return Int(result)
        var number = get_errno().value
        if number != EINTR:
            raise _system_error("pread", number)


def _file_readlink_at(fd: Int32, name: StringSlice) raises NetError -> String:
    var owned_name = String(name)
    var c_name = owned_name.as_c_string_span()
    var storage = Array[Byte, 4096](fill=0)
    var count: c_ssize_t
    while True:
        count = external_call["readlinkat", c_ssize_t](
            c_int(fd),
            c_name.ptr(),
            Pointer(to=storage).unsafe_bitcast[Byte](),
            c_size_t(4096),
        )
        if count >= 0:
            break
        var number = get_errno().value
        if number != EINTR:
            raise _system_error("readlinkat", number)
    if count == 0 or count >= 4096:
        raise _file_argument("symlink target exceeds limit")
    try:
        return String(from_utf8=Span(storage)[: Int(count)])
    except:
        raise _file_argument("symlink target is not UTF-8")


def _file_realpath(path: StringSlice) raises NetError -> String:
    var owned_path = String(path)
    if not path or 0 in path.as_bytes():
        raise _file_argument("invalid root path")
    var name = owned_path.as_c_string_span()
    var storage = Array[Byte, 4096](fill=0)
    var result = external_call[
        "realpath", OptionalPointer[Byte, MutUntrackedOrigin]
    ](name.ptr(), Pointer(to=storage).unsafe_bitcast[Byte]())
    if not result:
        raise _system_error("realpath", get_errno().value)
    var count = 0
    while count < 4096 and storage[count] != 0:
        count += 1
    if count == 4096:
        raise _file_argument("root path exceeds limit")
    try:
        return String(from_utf8=Span(storage)[:count])
    except:
        raise _file_argument("root path is not UTF-8")


struct _DirectoryStream:
    var handle: Pointer[Byte, MutUntrackedOrigin]

    def __init__(out self, fd: Int32) raises NetError:
        var descriptor = _open_file_at(fd, ".", True)
        var handle = external_call[
            "fdopendir", OptionalPointer[Byte, MutUntrackedOrigin]
        ](c_int(descriptor.raw()))
        if not handle:
            raise _system_error("fdopendir", get_errno().value)
        self.handle = handle.value()
        _ = descriptor._take()

    def next(self) -> Tuple[OptionalPointer[Byte, MutUntrackedOrigin], Int32]:
        var code = get_errno()
        code.value = 0
        set_errno(code)
        var entry = external_call[
            "readdir", OptionalPointer[Byte, MutUntrackedOrigin]
        ](self.handle)
        return entry, get_errno().value

    def __deinit__(deinit self):
        _ = external_call["closedir", c_int](self.handle)


def _directory_entry_name[
    darwin: Bool
](entry: Pointer[Byte, MutUntrackedOrigin]) raises NetError -> String:
    var offset = 21 if darwin else 19
    var length: Int
    comptime if darwin:
        length = Int(
            entry.unsafe_offset(18).unsafe_bitcast[UInt16]().unsafe_load()
        )
    else:
        length = 0
        while (
            length <= _MAX_NAME_BYTES
            and entry[unsafe_offset=offset + length] != 0
        ):
            length += 1
    if length > _MAX_NAME_BYTES:
        raise _file_argument("directory entry name exceeds segment limit")
    var bytes = List[Byte]()
    for i in range(length):
        bytes.append(entry[unsafe_offset=offset + i])
    return String(from_utf8_lossy=Span(bytes))


def _file_directory_entries(
    fd: Int32, max_entries: Int
) raises NetError -> List[String]:
    if max_entries < 0:
        raise _file_argument("negative directory entry limit")
    var stream = _DirectoryStream(fd)
    var entries = List[String]()
    while True:
        var result = stream.next()
        if not result[0]:
            if result[1] != 0:
                raise _system_error("readdir", result[1])
            break
        var name = _directory_entry_name[_DARWIN](result[0].value())
        if name == "." or name == "..":
            continue
        if len(entries) == max_entries:
            raise _file_argument("directory entry limit exceeded")
        entries.append(name^)
    return entries^
