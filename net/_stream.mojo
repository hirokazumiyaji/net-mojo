from net._sys.common import (
    _OwnedFD,
    _accept_status,
    _is_interrupted,
    _is_would_block,
    _recv_status,
    _send_status,
    _system_error,
    _wait_readable,
    _wait_writable,
)
from .error import NetError, NetErrorKind, _timeout_error
from .timeout import _Deadline


def _read_with_deadline[
    origin: MutOrigin
](
    fd: Int32,
    buffer: Span[mut=True, Byte, origin],
    deadline: _Deadline,
) raises NetError -> Int:
    if len(buffer) == 0:
        return 0
    while True:
        var status = _recv_status(fd, buffer)
        if status.error_number == 0:
            return status.value
        if _is_interrupted(status.error_number):
            if deadline.expired():
                raise _timeout_error("read")
            continue
        if not _is_would_block(status.error_number):
            raise _system_error("recv", status.error_number)
        if not _wait_readable(fd, deadline):
            raise _timeout_error("read")


def _write_with_deadline[
    origin: ImmOrigin
](
    fd: Int32, buffer: Span[Byte, origin], deadline: _Deadline
) raises NetError -> Int:
    if len(buffer) == 0:
        return 0
    while True:
        var status = _send_status(fd, buffer)
        if status.error_number == 0:
            if status.value == 0:
                raise NetError(
                    NetErrorKind.invalid_state(),
                    "write",
                    None,
                    "non-empty write made no progress",
                )
            return status.value
        if _is_interrupted(status.error_number):
            if deadline.expired():
                raise _timeout_error("write")
            continue
        if not _is_would_block(status.error_number):
            raise _system_error("send", status.error_number)
        if not _wait_writable(fd, deadline):
            raise _timeout_error("write")


def _try_recv[
    origin: MutOrigin
](fd: Int32, buffer: Span[mut=True, Byte, origin]) raises NetError -> Int:
    """One `recv` attempt without waiting: `EINTR` is retried, `EAGAIN`
    is reported as a timeout so event loops can move on to the next fd."""
    if len(buffer) == 0:
        return 0
    while True:
        var status = _recv_status(fd, buffer)
        if status.error_number == 0:
            return status.value
        if _is_interrupted(status.error_number):
            continue
        if _is_would_block(status.error_number):
            raise _timeout_error("read")
        raise _system_error("recv", status.error_number)


def _try_send[
    origin: ImmOrigin
](fd: Int32, buffer: Span[Byte, origin]) raises NetError -> Int:
    """One `send` attempt without waiting, with the same mapping as
    `_try_recv`."""
    if len(buffer) == 0:
        return 0
    while True:
        var status = _send_status(fd, buffer)
        if status.error_number == 0:
            if status.value == 0:
                raise NetError(
                    NetErrorKind.invalid_state(),
                    "write",
                    None,
                    "non-empty write made no progress",
                )
            return status.value
        if _is_interrupted(status.error_number):
            continue
        if _is_would_block(status.error_number):
            raise _timeout_error("write")
        raise _system_error("send", status.error_number)


def _try_accept(fd: Int32) raises NetError -> _OwnedFD:
    """One `accept` attempt without waiting, with the same mapping as
    `_try_recv`."""
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
            return status.take_fd()
        if _is_interrupted(status.error_number):
            continue
        if _is_would_block(status.error_number):
            raise _timeout_error("accept")
        raise _system_error("accept", status.error_number)


trait _WriteAllStep:
    def write(
        mut self, offset: Int, remaining: Int, deadline: _Deadline
    ) raises NetError -> Int:
        ...


struct _SocketWriteStep[origin: ImmOrigin](Movable, _WriteAllStep):
    var fd: Int32
    var buffer: Span[Byte, Self.origin]

    def __init__(out self, fd: Int32, buffer: Span[Byte, Self.origin]):
        self.fd = fd
        self.buffer = buffer

    def write(
        mut self, offset: Int, remaining: Int, deadline: _Deadline
    ) raises NetError -> Int:
        return _write_with_deadline(
            self.fd,
            self.buffer[offset : offset + remaining],
            deadline,
        )


def _write_all_loop[
    WriteStep: _WriteAllStep
](length: Int, deadline: _Deadline, mut write_step: WriteStep) raises NetError:
    var offset = 0
    while offset < length:
        var remaining = length - offset
        var written = write_step.write(offset, remaining, deadline)
        if written <= 0 or written > remaining:
            raise NetError(
                NetErrorKind.invalid_state(),
                "write",
                None,
                "write reported invalid progress",
            )
        offset += written


def _accept_stream(fd: Int32, deadline: _Deadline) raises NetError -> _OwnedFD:
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
            return status.take_fd()
        if _is_interrupted(status.error_number):
            if deadline.expired():
                raise _timeout_error("accept")
            continue
        if not _is_would_block(status.error_number):
            raise _system_error("accept", status.error_number)
        if not _wait_readable(fd, deadline):
            raise _timeout_error("accept")
