from net._sys.common import (
    AF_UNIX,
    SOCK_STREAM,
    _OwnedFD,
    _CONNECT_FAILED,
    _CONNECT_PENDING,
    _CONNECT_RETRY,
    _accept_status,
    _bind,
    _connect_attempt_allowed,
    _connect_disposition,
    _connect_status,
    _is_interrupted,
    _is_would_block,
    _listen,
    _socket,
    _socket_error,
    _system_error,
    _unix_address_to_raw,
    _validate_unix_path,
    _wait_readable,
    _wait_writable,
)

from .error import NetError, NetErrorKind
from .tcp import (
    _SocketWriteStep,
    _read_with_deadline,
    _timeout_error,
    _write_all_loop,
    _write_with_deadline,
)
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
        var fd = self._fd.raw()
        while True:
            var status = _accept_status(fd)
            if status.invalid_state:
                raise NetError(
                    NetErrorKind.invalid_state(),
                    "accept",
                    None,
                    "accepted descriptor configuration failed",
                )
            if status.error_number == 0:
                return UnixConn(status.take_fd())
            if _is_interrupted(status.error_number):
                if deadline.expired():
                    raise _timeout_error("accept")
                continue
            if not _is_would_block(status.error_number):
                raise _system_error("accept", status.error_number)
            if not _wait_readable(fd, deadline):
                raise _timeout_error("accept")

    def close(mut self) raises NetError:
        self._fd.close()


def _invalid_unix_backlog() -> NetError:
    return NetError(
        NetErrorKind.invalid_argument(),
        "listen unix",
        None,
        "backlog is out of range",
    )


def dial_unix(
    path: StringSlice, timeout: Optional[Timeout] = None
) raises NetError -> UnixConn:
    var address = UnixAddress.parse(path)
    var deadline = _Deadline.from_optional(timeout)
    var has_attempted = False
    while True:
        if not _connect_attempt_allowed(has_attempted, deadline):
            raise _timeout_error("connect")
        has_attempted = True
        var fd = _socket(AF_UNIX, SOCK_STREAM, 0)
        var raw = _unix_address_to_raw(address.path)
        var status = _connect_status(fd.raw(), raw)
        var disposition = _connect_disposition(status.error_number)
        if disposition == _CONNECT_RETRY:
            continue
        if disposition == _CONNECT_FAILED:
            raise _system_error("connect", status.error_number)
        if disposition == _CONNECT_PENDING:
            if not _wait_writable(fd.raw(), deadline):
                raise _timeout_error("connect")
            var error_number = _socket_error(fd.raw())
            if error_number != 0:
                raise _system_error("connect", error_number)
        return UnixConn(fd^)


def listen_unix(
    path: StringSlice, backlog: Int = 128
) raises NetError -> UnixListener:
    if backlog < 1 or backlog > Int(Int32.MAX):
        raise _invalid_unix_backlog()
    var address = UnixAddress.parse(path)
    var fd = _socket(AF_UNIX, SOCK_STREAM, 0)
    var raw = _unix_address_to_raw(address.path)
    _bind(fd.raw(), raw)
    _listen(fd.raw(), Int32(backlog))
    return UnixListener(fd^)
