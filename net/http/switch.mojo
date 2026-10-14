"""Owned raw transport after an HTTP/1 protocol switch."""

from net import SocketAddress, TCPConn
from net._sys.common import _wait_readable, _wait_writable
from net.error import NetError, NetErrorKind, _timeout_error
from net.timeout import Timeout, _Deadline
from net.tls import TLSConnection, TLSIOResult, TLSProgress


def _wait_tls(
    fd: Int32, progress: TLSProgress, deadline: _Deadline, operation: String
) raises NetError:
    var ready: Bool
    if progress.is_wants_read():
        ready = _wait_readable(fd, deadline)
    else:
        ready = _wait_writable(fd, deadline)
    if not ready:
        raise _timeout_error(operation)


struct HijackedConn(Movable):
    """Exclusive TCP/TLS ownership; the receiver is responsible for closing it.

    Nonblocking TLS retries must preserve write content and length. A timeout
    can require readability or writability; raw-fd pollers should watch both.
    """

    var _plain: Optional[TCPConn]
    var _tls: Optional[TLSConnection]
    var _buffered: List[Byte]
    var _buffered_offset: Int
    var _read_buffer: List[Byte]
    var _read_retry_length: Int
    var _write_retry_length: Int

    def __init__(out self, var connection: TCPConn, var buffered: List[Byte]):
        self._plain = connection^
        self._tls = None
        self._buffered = buffered^
        self._buffered_offset = 0
        self._read_buffer = List[Byte]()
        self._read_retry_length = 0
        self._write_retry_length = 0

    def __init__(
        out self,
        var connection: TLSConnection,
        var buffered: List[Byte],
        var read_buffer: List[Byte],
        read_retry_length: Int = 0,
    ):
        self._plain = None
        self._tls = connection^
        self._buffered = buffered^
        self._buffered_offset = 0
        self._read_buffer = read_buffer^
        self._read_retry_length = read_retry_length
        self._write_retry_length = 0

    def is_tls(self) -> Bool:
        return Bool(self._tls)

    def raw_fd(self) raises NetError -> Int32:
        if self._tls:
            return self._tls.value().raw_fd()
        return self._plain.value().raw_fd()

    def local_address(self) raises NetError -> SocketAddress:
        if self._tls:
            return self._tls.value()._socket.local_address()
        return self._plain.value().local_address()

    def remote_address(self) raises NetError -> SocketAddress:
        if self._tls:
            return self._tls.value()._socket.remote_address()
        return self._plain.value().remote_address()

    def buffered(ref self) -> Span[Byte, origin_of(self._buffered)]:
        """Unread switched-protocol bytes; never reinterpret them as HTTP."""
        return Span(self._buffered)[self._buffered_offset :]

    def take_buffered(mut self) -> List[Byte]:
        var unread = List[Byte]()
        if self._buffered_offset == 0:
            unread = self._buffered^
        else:
            unread.extend(self.buffered())
        self._buffered = List[Byte]()
        self._buffered_offset = 0
        return unread^

    def _consume_buffered[
        o: MutOrigin
    ](mut self, buffer: Span[mut=True, Byte, o]) -> Int:
        var count = min(
            len(buffer), len(self._buffered) - self._buffered_offset
        )
        for i in range(count):
            buffer[i] = self._buffered[self._buffered_offset + i]
        self._buffered_offset += count
        if self._buffered_offset == len(self._buffered):
            self._buffered = List[Byte]()
            self._buffered_offset = 0
        return count

    def _tls_read(mut self) raises NetError -> TLSIOResult:
        var length = len(self._read_buffer)
        if self._read_retry_length > 0:
            length = self._read_retry_length
        var result = self._tls.value().try_read(
            Span(self._read_buffer)[0:length]
        )
        if result.progress.is_complete():
            self._read_retry_length = 0
            self._buffered.extend(Span(self._read_buffer)[0 : result.count])
        elif result.progress.is_closed():
            self._read_retry_length = 0
        else:
            self._read_retry_length = length
        return result^

    def try_read[
        o: MutOrigin
    ](mut self, buffer: Span[mut=True, Byte, o]) raises NetError -> Int:
        if len(buffer) == 0 or len(self.buffered()) > 0:
            return self._consume_buffered(buffer)
        if not self._tls:
            return self._plain.value().try_read(buffer)
        var result = self._tls_read()
        if result.progress.is_complete() or result.progress.is_closed():
            return self._consume_buffered(buffer)
        raise _timeout_error("hijacked TLS read")

    def read[
        o: MutOrigin
    ](
        mut self,
        buffer: Span[mut=True, Byte, o],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        if len(buffer) == 0 or len(self.buffered()) > 0:
            return self._consume_buffered(buffer)
        if not self._tls:
            return self._plain.value().read(buffer, timeout)
        var deadline = _Deadline.from_optional(timeout)
        while True:
            var result = self._tls_read()
            if result.progress.is_complete() or result.progress.is_closed():
                return self._consume_buffered(buffer)
            _wait_tls(
                self.raw_fd(), result.progress, deadline, "hijacked TLS read"
            )

    def _tls_write[
        o: ImmOrigin
    ](mut self, buffer: Span[Byte, o]) raises NetError -> TLSIOResult:
        if (
            self._write_retry_length > 0
            and len(buffer) != self._write_retry_length
        ):
            raise NetError(
                NetErrorKind.invalid_state(),
                "hijacked TLS write",
                None,
                "retry must preserve write content and length",
            )
        var result = self._tls.value().try_write(buffer)
        if result.progress.is_complete():
            self._write_retry_length = 0
        elif result.progress.is_closed():
            self._write_retry_length = 0
            raise NetError(
                NetErrorKind.closed(), "hijacked TLS write", None, "peer closed"
            )
        else:
            self._write_retry_length = len(buffer)
        return result^

    def try_write[
        o: ImmOrigin
    ](mut self, buffer: Span[Byte, o]) raises NetError -> Int:
        if not self._tls:
            return self._plain.value().try_write(buffer)
        var result = self._tls_write(buffer)
        if result.progress.is_complete():
            return result.count
        raise _timeout_error("hijacked TLS write")

    def write[
        o: ImmOrigin
    ](
        mut self,
        buffer: Span[Byte, o],
        timeout: Optional[Timeout] = None,
    ) raises NetError -> Int:
        if not self._tls:
            return self._plain.value().write(buffer, timeout)
        var deadline = _Deadline.from_optional(timeout)
        while True:
            var result = self._tls_write(buffer)
            if result.progress.is_complete():
                return result.count
            _wait_tls(
                self.raw_fd(), result.progress, deadline, "hijacked TLS write"
            )

    def set_no_delay(self, enabled: Bool) raises NetError:
        if self._tls:
            self._tls.value()._socket.set_no_delay(enabled)
        else:
            self._plain.value().set_no_delay(enabled)

    def shutdown_write(mut self) raises NetError:
        if self._write_retry_length > 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "hijacked shutdown",
                None,
                "TLS write retry remains pending",
            )
        if self._tls:
            while True:
                var progress = self._tls.value().shutdown()
                if progress.is_complete() or progress.is_sent_close_notify():
                    break
                _wait_tls(
                    self.raw_fd(),
                    progress,
                    _Deadline(None),
                    "hijacked TLS shutdown",
                )
            self._tls.value()._socket.shutdown(False, True)
        else:
            self._plain.value().shutdown(False, True)

    def close(deinit self) raises NetError:
        if self._tls:
            self._tls.value()._socket.close()
        else:
            self._plain.value().close()
