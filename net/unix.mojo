from net._sys.common import (
    AF_UNIX,
    SOCK_STREAM,
    _OwnedFD,
    _connect_candidate,
    _create_bound_socket,
    _listen,
    _unix_address_to_raw,
    _validate_unix_path,
)

from ._stream import (
    _SocketWriteStep,
    _accept_stream,
    _read_with_deadline,
    _write_all_loop,
    _write_with_deadline,
)
from .error import NetError, _invalid_backlog_error
from .timeout import Timeout, _Deadline


@fieldwise_init
struct UnixAddress(Copyable, Equatable, Hashable, Movable, Writable):
    var path: String

    @staticmethod
    def parse(value: StringSlice) raises NetError -> Self:
        _validate_unix_path(value)
        return Self(path=String(value))

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.path)


struct UnixConn(Movable):
    var _fd: _OwnedFD

    def __init__(out self, var fd: _OwnedFD):
        self._fd = fd^

    def read[
        origin: MutOrigin
    ](
        self,
        buffer: Span[mut=True, Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        var deadline = _Deadline.from_optional(timeout)
        return _read_with_deadline(self._fd.raw(), buffer, deadline)

    def write[
        origin: ImmOrigin
    ](
        self,
        buffer: Span[Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        var deadline = _Deadline.from_optional(timeout)
        return _write_with_deadline(self._fd.raw(), buffer, deadline)

    def write_all[
        origin: ImmOrigin
    ](
        self,
        buffer: Span[Byte, origin],
        timeout: Optional[Timeout] = None,
    ) raises NetError:
        var deadline = _Deadline.from_optional(timeout)
        var write_step = _SocketWriteStep(self._fd.raw(), buffer)
        _write_all_loop(len(buffer), deadline, write_step)

    def close(mut self) raises NetError:
        self._fd.close()


struct UnixListener(Movable):
    var _fd: _OwnedFD

    def __init__(out self, var fd: _OwnedFD):
        self._fd = fd^

    def accept(
        self, timeout: Optional[Timeout] = None
    ) raises NetError -> UnixConn:
        var deadline = _Deadline.from_optional(timeout)
        return UnixConn(_accept_stream(self._fd.raw(), deadline))

    def close(mut self) raises NetError:
        self._fd.close()


def dial_unix(
    path: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> UnixConn:
    var address = UnixAddress.parse(path)
    var deadline = _Deadline.from_optional(timeout)
    var has_attempted = False
    var raw = _unix_address_to_raw(address.path)
    return UnixConn(
        _connect_candidate(AF_UNIX, SOCK_STREAM, raw, has_attempted, deadline)
    )


def listen_unix(
    path: StringSlice, backlog: Int = 128
) raises NetError -> UnixListener:
    if backlog < 1 or backlog > Int(Int32.MAX):
        raise _invalid_backlog_error("listen unix")
    var address = UnixAddress.parse(path)
    var raw = _unix_address_to_raw(address.path)
    var fd = _create_bound_socket(AF_UNIX, SOCK_STREAM, raw, False, False)
    _listen(fd.raw(), Int32(backlog))
    return UnixListener(fd^)
