from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.sys.info import is_64bit


def print_fd_limits() raises:
    comptime assert is_64bit(), "benchmark FD metadata requires 64-bit ABI"
    comptime assert (
        CompilationTarget.is_macos() or CompilationTarget.is_linux()
    ), "benchmark FD metadata supports Linux and macOS"
    comptime resource = 8 if CompilationTarget.is_macos() else 7
    var limits = Array[UInt64, 2](fill=0)
    if (
        external_call["getrlimit", c_int](c_int(resource), Pointer(to=limits))
        != 0
    ):
        raise Error("benchmark getrlimit failed")
    var pid = external_call["getpid", c_int]()
    print(
        '{"event":"fd_limits","source":"getrlimit","pid":',
        pid,
        ',"soft":',
        limits[0],
        ',"hard":',
        limits[1],
        "}",
    )
