from std.ffi import c_int, c_uint, external_call, get_errno, set_errno
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns
from std.os import mkdir

from net.http._filesystem import FileSystem, _File
from net._sys.file import _AT_FDCWD, _directory_entry_name
from net._sys.common import F_GETFD, _fcntl
from net import listen_unix
from tests.support import _count_open_fds, _join_thread


def _remove(var path: String, directory: Bool = False):
    var name = path.as_c_string_span()
    if directory:
        _ = external_call["rmdir", c_int](name.ptr())
    else:
        _ = external_call["unlink", c_int](name.ptr())


struct _Fixture(Movable):
    var root: String
    var paths: List[String]
    var directories: List[String]

    def __init__(out self) raises:
        var pid = external_call["getpid", c_int]()
        self.root = String(t"/tmp/net-mojo-fs-{pid}-{perf_counter_ns()}")
        self.paths = List[String]()
        self.directories = List[String]()
        self.mkdir("")

    def mkdir(mut self, relative: StringSlice) raises:
        var path = self.root + ("/" + String(relative) if relative else "")
        mkdir(path, 0o700)
        self.directories.append(path^)

    def write(mut self, relative: StringSlice, content: StringSlice) raises:
        var path = self.root + "/" + String(relative)
        with open(path, "w") as file:
            file.write(content)
        self.paths.append(path^)

    def link(mut self, relative: StringSlice, target: StringSlice) raises:
        var path = self.root + "/" + String(relative)
        var owned_target = String(target)
        assert_equal(
            external_call["symlink", c_int](
                owned_target.as_c_string_span().ptr(),
                path.as_c_string_span().ptr(),
            ),
            0,
        )
        self.paths.append(path^)

    def __deinit__(deinit self):
        for path in self.paths:
            _remove(path)
        for i in range(len(self.directories) - 1, -1, -1):
            _remove(self.directories[i], True)


def test_regular_metadata_and_offset_reads() raises:
    var fixture = _Fixture()
    fixture.write("hello.txt", "abcdef")
    var fs = FileSystem.dir(fixture.root)
    var file = fs.open("/hello.txt")
    assert_false(file.is_directory)
    assert_equal(file.size, 6)
    assert_true(file.mtime_ns > 0)
    var bytes = Array[Byte, 3](fill=0)
    assert_equal(file.pread(Span(bytes), 2), 3)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "cde")
    assert_equal(file.pread(Span(bytes), 6), 0)
    _ = fixture.root


def _assert_refused(fs: FileSystem, path: StringSlice) raises:
    var refused = False
    try:
        _ = fs.open(path)
    except:
        refused = True
    assert_true(refused, String(t"path accepted: {path}"))


def test_thirty_malicious_paths() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("secret", "inside")
    var fs = FileSystem.dir(fixture.root)
    var cases: List[String] = [
        ".",
        "..",
        "./secret",
        "../secret",
        "a/../secret",
        "/../secret",
        "/./secret",
        "a/./secret",
        "secret/..",
        "secret/.",
        "a/../../secret",
        "../../secret",
        "/a/../secret",
        "a/..",
        "a/.",
        "//",
        "//secret",
        "a//secret",
        "a//",
        "/a//",
        "secret\x00",
        "\x00secret",
        "a/\x00/secret",
        "a\x00/secret",
        "a/secret\x00x",
        "/a/../../secret",
        "/a/./",
        "../",
        "/../",
        "./",
    ]
    assert_equal(len(cases), 30)
    for path in cases:
        _assert_refused(fs, path)
    _ = fixture.root


def test_percent_encoded_segments_remain_literal() raises:
    var fixture = _Fixture()
    fixture.write("%2e%2e", "literal")
    fixture.write("..%2fsecret", "escaped separator")
    var fs = FileSystem.dir(fixture.root)
    var file = fs.open("/%2e%2e")
    var bytes = Array[Byte, 7](fill=0)
    assert_equal(file.pread(Span(bytes), 0), 7)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "literal")
    assert_equal(fs.open("/..%2fsecret").size, 17)
    _assert_refused(fs, "%2e%2e/secret")
    _ = fixture.root


def test_directory_index_and_root_forms() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("a/index.html", "index")
    var fs = FileSystem.dir(fixture.root)
    assert_true(fs.open("").is_directory)
    assert_true(fs.open("/").is_directory)
    var directory = fs.open("/a/")
    assert_true(directory.is_directory)
    var index = directory.open_index("index.html")
    assert_equal(index.size, 5)
    var bytes = Array[Byte, 5](fill=0)
    assert_equal(index.pread(Span(bytes), 0), 5)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "index")
    var bad_names: List[String] = [
        "",
        "/index.html",
        "index.html/",
        "../index.html",
        "a/index.html",
        ".",
        "..",
    ]
    for name in bad_names:
        var refused = False
        try:
            _ = directory.open_index(name)
        except:
            refused = True
        assert_true(refused)
    _ = fixture.root


def test_default_policy_rejects_leaf_and_directory_symlinks() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("a/file", "allowed")
    fixture.link("leaf", "a/file")
    fixture.link("directory", "a")
    var fs = FileSystem.dir(fixture.root)
    _assert_refused(fs, "leaf")
    _assert_refused(fs, "directory/file")
    _ = fixture.root


def test_enabled_relative_and_absolute_links_inside_root() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("file", "allowed")
    fixture.link("a/leaf", "../file")
    fixture.link("directory", "a")
    var fs = FileSystem.dir(fixture.root, True)
    fixture.link("absolute", fs._root[].path + "/file")
    var root_target = fs._root[].path.copy()
    fixture.link("root-link", root_target)
    fixture.link("a/index.html", "../file")
    assert_equal(fs.open("a/leaf").size, 7)
    assert_equal(fs.open("directory/leaf").size, 7)
    assert_equal(fs.open("absolute").size, 7)
    assert_equal(fs.open("root-link/file").size, 7)
    var directory = fs.open("a")
    assert_equal(directory.open_index("index.html").size, 7)
    _ = fixture.root


def test_enabled_links_refuse_relative_absolute_and_prefix_escapes() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("file", "allowed")
    fixture.link("relative", "../file")
    fixture.link("a/relative", "../../file")
    fixture.link("absolute", "/etc/passwd")
    fixture.link("prefix", fixture.root + "-outside/file")
    fixture.link("dotdot", fixture.root + "/../file")
    fixture.link("a/rootdotdot", fixture.root + "/../file")
    var fs = FileSystem.dir(fixture.root, True)
    var cases: List[String] = [
        "relative",
        "a/relative",
        "absolute",
        "prefix",
        "dotdot",
        "a/rootdotdot",
    ]
    for path in cases:
        _assert_refused(fs, path)
    _ = fixture.root


def test_symlink_loops_are_bounded() raises:
    var fixture = _Fixture()
    fixture.link("self", "self")
    fixture.link("a", "b")
    fixture.link("b", "a")
    var fs = FileSystem.dir(fixture.root, True)
    _assert_refused(fs, "self")
    _assert_refused(fs, "a")
    _ = fixture.root


def test_negative_offset_is_refused() raises:
    var fixture = _Fixture()
    fixture.write("file", "allowed")
    var fs = FileSystem.dir(fixture.root)
    var file = fs.open("file")
    var bytes = Array[Byte, 1](fill=0)
    var refused = False
    try:
        _ = file.pread(Span(bytes), -1)
    except:
        refused = True
    assert_true(refused)
    _ = fixture.root


def _copy_root(path: StringSlice) raises -> FileSystem:
    var fs = FileSystem.dir(path)
    return fs.copy()


def test_copy_keeps_root_alive_and_file_outlives_filesystem() raises:
    var fixture = _Fixture()
    fixture.write("file", "allowed")
    var fs = _copy_root(fixture.root)
    var root_fd = fs._root[].fd.raw()
    var copies = List[FileSystem]()
    copies.append(fs.copy())
    assert_true(_fcntl(c_int(root_fd), c_int(F_GETFD), c_int(0)) >= 0)
    var file = copies[0].open("file")
    _ = copies^
    var bytes = Array[Byte, 7](fill=0)
    assert_equal(file.pread(Span(bytes), 0), 7)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "allowed")
    _ = fixture.root


def test_pinned_root_survives_path_replacement() raises:
    var fixture = _Fixture()
    fixture.mkdir("root")
    fixture.write("root/file", "original")
    var root_path = fixture.root + "/root"
    var fs = FileSystem.dir(root_path)
    var moved_path = fixture.root + "/moved"
    assert_equal(
        external_call["rename", c_int](
            root_path.as_c_string_span().ptr(),
            moved_path.as_c_string_span().ptr(),
        ),
        0,
    )
    fixture.paths[0] = moved_path + "/file"
    fixture.directories[1] = moved_path.copy()
    fixture.mkdir("root")
    fixture.write("root/file", "replacement")
    var file = fs.open("file")
    var bytes = Array[Byte, 8](fill=0)
    assert_equal(file.pread(Span(bytes), 0), 8)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "original")
    _ = fixture.root


def test_pinned_directory_index_survives_path_replacement() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("a/index.html", "original")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("a")
    var old_path = fixture.root + "/a"
    var moved_path = fixture.root + "/moved"
    assert_equal(
        external_call["rename", c_int](
            old_path.as_c_string_span().ptr(),
            moved_path.as_c_string_span().ptr(),
        ),
        0,
    )
    fixture.paths[0] = moved_path + "/index.html"
    fixture.directories[1] = moved_path.copy()
    fixture.mkdir("a")
    fixture.write("a/index.html", "replacement")
    assert_equal(directory.open_index("index.html").size, 8)
    _ = fixture.root


def test_fifo_and_socket_are_refused_without_blocking() raises:
    var fixture = _Fixture()
    var fifo = fixture.root + "/fifo"
    assert_equal(
        external_call["mkfifo", c_int](
            fifo.as_c_string_span().ptr(), UInt32(0o600)
        ),
        0,
    )
    fixture.paths.append(fifo.copy())
    var socket = fixture.root + "/socket"
    var listener = listen_unix(socket)
    fixture.paths.append(socket.copy())
    var fs = FileSystem.dir(fixture.root)
    _ = external_call["alarm", c_uint](c_uint(2))
    var started = perf_counter_ns()
    _assert_refused(fs, "fifo")
    _assert_refused(fs, "socket")
    _ = external_call["alarm", c_uint](c_uint(0))
    assert_true(perf_counter_ns() - started < 500_000_000)
    listener.close()
    _ = fixture.root


def test_device_is_refused() raises:
    var fs = FileSystem.dir("/dev")
    _assert_refused(fs, "null")


def test_metadata_preserves_nanosecond_precision() raises:
    var fixture = _Fixture()
    fixture.write("file", "abc")
    var path = fixture.root + "/file"
    var times: Array[Int64, 4] = [
        2_000_000_000,
        123_456_789,
        2_000_000_000,
        987_654_321,
    ]
    assert_equal(
        external_call["utimensat", c_int](
            c_int(_AT_FDCWD),
            path.as_c_string_span().ptr(),
            Pointer(to=times).unsafe_bitcast[Int64](),
            c_int(0),
        ),
        0,
    )
    var fs = FileSystem.dir(fixture.root)
    var file = fs.open("file")
    assert_equal(file.mtime_ns, Int64(2_000_000_000_987_654_321))
    assert_equal(file.size, 3)
    _ = fixture.root


def test_offset_reads_do_not_change_shared_file_position() raises:
    var fixture = _Fixture()
    fixture.write("file", "0123456789")
    var fs = FileSystem.dir(fixture.root)
    var file = fs.open("file")
    var bytes = Array[Byte, 3](fill=0)
    assert_equal(file.pread(Span(bytes), 5), 3)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "567")
    assert_equal(file.pread(Span(bytes), 0), 3)
    assert_equal(String(from_utf8_lossy=Span(bytes)), "012")
    assert_equal(file.pread(Span(bytes), 10), 0)
    _ = fixture.root


def test_path_and_segment_limits() raises:
    var fixture = _Fixture()
    var fs = FileSystem.dir(fixture.root)
    var segment = String()
    for _ in range(256):
        segment += "x"
    _assert_refused(fs, segment)
    var path = String()
    for _ in range(2050):
        path += "a/"
    _assert_refused(fs, path)
    _ = fixture.root


def test_exact_symlink_depth_limit() raises:
    var fixture = _Fixture()
    fixture.write("file", "ok")
    for i in range(41):
        var name = String(t"l{i}")
        var target = "file" if i == 40 else String(t"l{i + 1}")
        fixture.link(name, target)
    var fs = FileSystem.dir(fixture.root, True)
    assert_equal(fs.open("l1").size, 2)
    _assert_refused(fs, "l0")
    _ = fixture.root


def _open_and_drop(fs: FileSystem, count: Int) raises:
    for _ in range(count):
        var file = fs.open("a")
        _ = file.open_index("index.html")
        _assert_refused(fs, "a/missing")
        _assert_refused(fs, "escape")


def test_descriptor_ownership_releases_success_and_error_paths() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("a/index.html", "index")
    fixture.link("escape", "../secret")
    var fs = FileSystem.dir(fixture.root, True)
    _open_and_drop(fs, 1)
    var before = _count_open_fds()
    _open_and_drop(fs, 100)
    assert_equal(_count_open_fds(), before)
    _ = fs._root[].path
    _ = fixture.root


@fieldwise_init
struct _RaceContext(Movable):
    var leaf: String
    var temporary: String
    var safe_target: String
    var outside_target: String


def _swap_symlinks(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_RaceContext]()
    for i in range(2000):
        var target = (
            context[].safe_target.copy() if i % 2
            == 0 else context[].outside_target.copy()
        )
        _ = external_call["unlink", c_int](
            context[].temporary.as_c_string_span().ptr()
        )
        _ = external_call["symlink", c_int](
            target.as_c_string_span().ptr(),
            context[].temporary.as_c_string_span().ptr(),
        )
        _ = external_call["rename", c_int](
            context[].temporary.as_c_string_span().ptr(),
            context[].leaf.as_c_string_span().ptr(),
        )
    return arg


def test_symlink_replacement_race_never_serves_outside_root() raises:
    var fixture = _Fixture()
    var outside = _Fixture()
    fixture.write("file", "inside")
    outside.write("file", "outside")
    fixture.link("switch", "file")
    var context = _RaceContext(
        leaf=fixture.root + "/switch",
        temporary=fixture.root + "/next",
        safe_target="file",
        outside_target=outside.root + "/file",
    )
    fixture.paths.append(context.temporary.copy())
    var fs = FileSystem.dir(fixture.root, True)
    var handle: UInt64 = 0
    assert_equal(
        external_call["pthread_create", c_int](
            Pointer(to=handle),
            OptionalPointer[Byte, MutUntrackedOrigin](None),
            _swap_symlinks,
            Pointer(to=context).unsafe_bitcast[Byte](),
        ),
        0,
    )
    var outside_reads = 0
    for _ in range(2000):
        try:
            var file = fs.open("switch")
            var bytes = Array[Byte, 7](fill=0)
            var count = file.pread(Span(bytes), 0)
            if String(from_utf8_lossy=Span(bytes)[:count]) != "inside":
                outside_reads += 1
        except:
            pass
    _join_thread(handle)
    assert_equal(outside_reads, 0)
    var leaf = context.leaf.copy()
    _remove(leaf)
    fixture.link("switch", "file")
    assert_equal(fs.open("switch").size, 6)
    _ = context.leaf
    _ = outside.root
    _ = fixture.root


def test_symlink_target_trailing_slash_requires_directory() raises:
    var fixture = _Fixture()
    fixture.write("file", "allowed")
    fixture.mkdir("a")
    fixture.write("a/index.html", "index")
    fixture.link("bad", "file/")
    fixture.link("bad-dot", "file/.")
    fixture.link("directory", "a/")
    var fs = FileSystem.dir(fixture.root, True)
    _assert_refused(fs, "bad")
    _assert_refused(fs, "bad-dot")
    assert_true(fs.open("directory").is_directory)
    assert_equal(fs.open("directory").open_index("index.html").size, 5)
    _ = fixture.root


def test_invalid_root_paths_are_refused() raises:
    var cases: List[String] = ["", "/tmp\x00/ignored"]
    for path in cases:
        var refused = False
        try:
            _ = FileSystem.dir(path)
        except:
            refused = True
        assert_true(refused)


def test_regular_request_path_with_trailing_slash_is_refused() raises:
    var fixture = _Fixture()
    fixture.write("file", "allowed")
    var fs = FileSystem.dir(fixture.root)
    _assert_refused(fs, "file/")
    _assert_refused(fs, "/file/")
    assert_true(fs.open("/").is_directory)
    _ = fixture.root


def _assert_listing_refused(file: _File, limit: Int) raises:
    var refused = False
    try:
        _ = file.list_entries(limit)
    except:
        refused = True
    assert_true(refused)


def test_list_entries_empty_excludes_dot_entries() raises:
    var fixture = _Fixture()
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    assert_equal(len(directory.list_entries()), 0)
    assert_equal(len(directory.list_entries(0)), 0)
    _ = fixture.root


def test_list_entries_names_include_unicode_and_control_bytes() raises:
    var fixture = _Fixture()
    fixture.write("file", "content")
    fixture.write("日本語.txt", "unicode")
    fixture.write("line\nbreak", "control")
    fixture.mkdir("directory")
    fixture.link("symlink", "file")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    var entries = directory.list_entries()
    assert_equal(len(entries), 5)
    assert_true("file" in entries)
    assert_true("日本語.txt" in entries)
    assert_true("line\nbreak" in entries)
    assert_true("directory" in entries)
    assert_true("symlink" in entries)
    assert_false("." in entries)
    assert_false(".." in entries)
    _ = fixture.root


def test_list_entries_exact_bound_and_overflow() raises:
    var fixture = _Fixture()
    fixture.write("a", "a")
    fixture.write("b", "b")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    assert_equal(len(directory.list_entries(2)), 2)
    _assert_listing_refused(directory, 1)
    _assert_listing_refused(directory, 0)
    _assert_listing_refused(directory, -1)
    _ = fixture.root


def test_list_entries_regular_file_is_refused() raises:
    var fixture = _Fixture()
    fixture.write("file", "content")
    var fs = FileSystem.dir(fixture.root)
    var file = fs.open("file")
    _assert_listing_refused(file, 256)
    _ = fixture.root


def test_list_entries_repeated_calls_have_independent_positions() raises:
    var fixture = _Fixture()
    fixture.write("a", "a")
    fixture.write("b", "b")
    fixture.write("c", "c")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    for _ in range(5):
        var entries = directory.list_entries()
        assert_equal(len(entries), 3)
        assert_true("a" in entries)
        assert_true("b" in entries)
        assert_true("c" in entries)
    assert_equal(directory.open_index("a").size, 1)
    _ = fixture.root


def test_list_entries_stale_errno_does_not_turn_eof_into_failure() raises:
    var fixture = _Fixture()
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    var code = get_errno()
    code.value = 5
    set_errno(code)
    assert_equal(len(directory.list_entries()), 0)
    _ = fixture.root


def test_list_entries_names_are_not_truncated() raises:
    var fixture = _Fixture()
    var name = String()
    for _ in range(255):
        name += "a"
    fixture.write(name, "content")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    var entries = directory.list_entries()
    assert_equal(len(entries), 1)
    assert_equal(entries[0], name)
    _ = fixture.root


def _list_repeatedly(directory: _File) raises:
    for _ in range(100):
        assert_equal(len(directory.list_entries(2)), 2)
        _assert_listing_refused(directory, 1)


def test_list_entries_releases_fds_on_success_and_bound_errors() raises:
    var fixture = _Fixture()
    fixture.write("a", "a")
    fixture.write("b", "b")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    _list_repeatedly(directory)
    var before = _count_open_fds()
    _list_repeatedly(directory)
    assert_equal(_count_open_fds(), before)
    _ = directory.is_directory
    _ = fixture.root


def test_list_entries_default_limit_is_256() raises:
    var fixture = _Fixture()
    for i in range(257):
        fixture.write(String(t"f{i}"), "")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("/")
    assert_equal(len(directory.list_entries(257)), 257)
    var refused = False
    try:
        _ = directory.list_entries()
    except:
        refused = True
    assert_true(refused)
    _ = fixture.root


def test_list_entries_uses_pinned_directory_after_rename() raises:
    var fixture = _Fixture()
    fixture.mkdir("a")
    fixture.write("a/original", "original")
    var fs = FileSystem.dir(fixture.root)
    var directory = fs.open("a")
    var old_path = fixture.root + "/a"
    var moved_path = fixture.root + "/moved"
    assert_equal(
        external_call["rename", c_int](
            old_path.as_c_string_span().ptr(),
            moved_path.as_c_string_span().ptr(),
        ),
        0,
    )
    fixture.paths[0] = moved_path + "/original"
    fixture.directories[1] = moved_path.copy()
    fixture.mkdir("a")
    fixture.write("a/replacement", "replacement")
    var entries = directory.list_entries()
    assert_equal(len(entries), 1)
    assert_equal(entries[0], "original")
    _ = fixture.root


def test_linux_dirent_long_names_are_refused_instead_of_truncated() raises:
    var storage = Array[Byte, 512](fill=0)
    storage[16] = 64
    storage[17] = 1
    for i in range(300):
        storage[19 + i] = 97
    var entry = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=storage))
    )
    var refused = False
    try:
        _ = _directory_entry_name[False](entry)
    except:
        refused = True
    assert_true(refused)
    _ = storage[0]


def test_linux_dirent_name_at_255_byte_bound_is_preserved() raises:
    var storage = Array[Byte, 280](fill=0)
    storage[16] = 24
    storage[17] = 1
    for i in range(255):
        storage[19 + i] = 97
    var entry = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=storage))
    )
    var name = _directory_entry_name[False](entry)
    assert_equal(name.byte_length(), 255)
    for byte in name.as_bytes():
        assert_equal(byte, 97)
    _ = storage[0]


def test_darwin_dirent_long_names_exceed_segment_bound() raises:
    var storage = Array[Byte, 1048](fill=0)
    storage[16] = 72
    storage[17] = 1
    storage[18] = 44
    storage[19] = 1
    for i in range(300):
        storage[21 + i] = 97
    var entry = Pointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=storage))
    )
    var refused = False
    try:
        _ = _directory_entry_name[True](entry)
    except:
        refused = True
    assert_true(refused)
    _ = storage[0]


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
