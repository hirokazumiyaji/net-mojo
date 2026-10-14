"""Worker-owned WebSocket protocol over an injected duplex byte stream."""

from std.time import perf_counter_ns
from net import Timeout
from net.error import NetError, NetErrorKind, _timeout_error
from net.timeout import _Deadline
from .switch import HijackedConn
from ._websocket_types import (
    WebSocketConfig,
    WebSocketMessage,
    WebSocketCloseInfo,
)
from ._websocket_frame import (
    _FrameDecoder,
    _WebSocketFrame,
    _WebSocketProtocolError,
    _UTF8Validator,
    _encode_frame,
    _validate_close,
)


trait DuplexStream(Deinitable, Movable):
    def read[
        o: MutOrigin
    ](
        mut self, buffer: Span[mut=True, Byte, o], timeout: Timeout
    ) raises NetError -> Int:
        ...

    def write[
        o: ImmOrigin
    ](mut self, buffer: Span[Byte, o], timeout: Timeout) raises NetError -> Int:
        ...

    def close(deinit self) raises NetError:
        ...


struct _HijackedWebSocketStream(DuplexStream):
    var _raw: HijackedConn

    def __init__(out self, var raw: HijackedConn):
        self._raw = raw^

    def read[
        o: MutOrigin
    ](
        mut self, buffer: Span[mut=True, Byte, o], timeout: Timeout
    ) raises NetError -> Int:
        return self._raw.read(buffer, timeout.copy())

    def write[
        o: ImmOrigin
    ](mut self, buffer: Span[Byte, o], timeout: Timeout) raises NetError -> Int:
        return self._raw.write(buffer, timeout.copy())

    def close(deinit self) raises NetError:
        self._raw^.close()


def _remaining(deadline: _Deadline) raises NetError -> Timeout:
    var remaining = deadline._expires_at.value() - perf_counter_ns()
    if remaining <= 0:
        raise _timeout_error("WebSocket I/O")
    return Timeout.nanoseconds(UInt64(remaining))


struct WebSocketConn[Stream: DuplexStream = _HijackedWebSocketStream](Movable):
    """Exclusive worker ownership; read_message drives control frames and keepalive.
    """

    var _stream: Optional[Self.Stream]
    var _config: WebSocketConfig
    var _protocol: String
    var _decoder: _FrameDecoder
    var _closed: Bool
    var _sent_close: Bool
    var _close_info: Optional[WebSocketCloseInfo]
    var _ping_deadline: _Deadline
    var _waiting_pong: Bool
    var _ping_sequence: UInt64
    var _ping_payload: List[Byte]
    var _read_pause_started: Int

    def __init__(
        out self,
        var stream: Self.Stream,
        config: WebSocketConfig,
        var selected_subprotocol: String = String(),
    ) raises NetError:
        config._validate()
        self._stream = stream^
        self._config = config.copy()
        self._protocol = selected_subprotocol^
        self._decoder = _FrameDecoder(config.max_frame_bytes)
        self._closed = False
        self._sent_close = False
        self._close_info = None
        self._ping_deadline = _Deadline(None)
        if config.ping_interval._value > 0:
            self._ping_deadline = _Deadline.from_timeout(config.ping_interval)
        self._waiting_pong = False
        self._ping_sequence = 0
        self._ping_payload = List[Byte]()
        self._read_pause_started = perf_counter_ns()

    def selected_subprotocol(self) -> String:
        return self._protocol.copy()

    def is_closed(self) -> Bool:
        return self._closed

    def close_info(self) -> Optional[WebSocketCloseInfo]:
        return self._close_info.copy()

    def _close_transport(mut self) raises NetError:
        if self._stream:
            self._stream.take().close()

    def _abort(mut self):
        self._closed = True
        try:
            self._close_transport()
        except:
            pass

    def _control_deadline(
        self, operation: _Deadline
    ) raises NetError -> _Deadline:
        var remaining = _remaining(operation)
        return _Deadline.from_timeout(
            Timeout.nanoseconds(
                min(remaining._value, self._config.write_deadline._value)
            )
        )

    def _write_frame[
        o: ImmOrigin
    ](
        mut self,
        opcode: UInt8,
        payload: Span[Byte, o],
        deadline: _Deadline,
        fin: Bool = True,
    ) raises NetError:
        var wire = _encode_frame(opcode, fin, payload)
        var offset = 0
        while offset < len(wire):
            var count = self._stream.value().write(
                Span(wire)[offset:], _remaining(deadline)
            )
            if count == 0:
                raise NetError(
                    NetErrorKind.closed(),
                    "WebSocket write",
                    None,
                    "stream closed",
                )
            offset += count

    def _fail(
        mut self, code: UInt16, reason: StringSlice, deadline: _Deadline
    ) raises NetError:
        if not self._sent_close:
            var payload: List[Byte] = [Byte(code >> 8), Byte(code & 255)]
            try:
                self._write_frame(
                    8,
                    Span(payload),
                    self._control_deadline(deadline),
                )
                self._sent_close = True
            except:
                pass
        self._abort()
        raise NetError(
            NetErrorKind.invalid_state(),
            "WebSocket protocol",
            None,
            String(reason),
        )

    def _check_open(self) raises NetError:
        if self._closed or self._sent_close:
            raise NetError(
                NetErrorKind.closed(), "WebSocket", None, "connection is closed"
            )

    def _write_data[
        o: ImmOrigin
    ](mut self, opcode: UInt8, data: Span[Byte, o]) raises NetError:
        self._check_open()
        if len(data) > self._config.max_message_bytes:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket write",
                None,
                "payload exceeds configured limit",
            )
        var frames = max(
            1,
            len(data) // self._config.max_frame_bytes
            + Int(len(data) % self._config.max_frame_bytes != 0),
        )
        if frames > self._config.max_fragment_count:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket write",
                None,
                "message exceeds fragment limit",
            )
        var deadline = _Deadline.from_timeout(self._config.write_deadline)
        var offset = 0
        try:
            for index in range(frames):
                var end = min(len(data), offset + self._config.max_frame_bytes)
                self._write_frame(
                    opcode if index == 0 else UInt8(0),
                    data[offset:end],
                    deadline,
                    fin=index + 1 == frames,
                )
                offset = end
        except err:
            self._abort()
            raise err^

    def write_text(mut self, data: StringSlice) raises NetError:
        var validator = _UTF8Validator()
        if self._config.validate_utf8 and (
            not validator.feed(data.as_bytes()) or not validator.complete()
        ):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket write",
                None,
                "invalid text UTF-8",
            )
        self._write_data(1, data.as_bytes())

    def write_binary[
        o: ImmOrigin
    ](mut self, data: Span[Byte, o]) raises NetError:
        self._write_data(2, data)

    def _write_control[
        o: ImmOrigin
    ](mut self, opcode: UInt8, payload: Span[Byte, o]) raises NetError:
        self._check_open()
        if len(payload) > 125:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket control",
                None,
                "control payload exceeds 125 bytes",
            )
        try:
            self._write_frame(
                opcode,
                payload,
                _Deadline.from_timeout(self._config.write_deadline),
            )
        except err:
            self._abort()
            raise err^

    def write_ping[
        o: ImmOrigin
    ](mut self, payload: Span[Byte, o]) raises NetError:
        self._write_control(9, payload)

    def write_pong[
        o: ImmOrigin
    ](mut self, payload: Span[Byte, o]) raises NetError:
        self._write_control(10, payload)

    def _drive_ping(mut self, deadline: _Deadline) raises NetError:
        if (
            self._sent_close
            or self._config.ping_interval._value == 0
            or not self._ping_deadline.expired()
        ):
            return
        if self._waiting_pong:
            self._fail(1011, "peer did not answer keepalive Ping", deadline)
        self._ping_sequence += 1
        var payload = List[Byte]()
        for i in range(8):
            payload.append(
                Byte((self._ping_sequence >> UInt64((7 - i) * 8)) & 255)
            )
        self._write_frame(9, Span(payload), self._control_deadline(deadline))
        self._ping_payload = payload^
        self._waiting_pong = True
        self._ping_deadline = _Deadline.from_timeout(self._config.ping_interval)

    def _read_frame(
        mut self, deadline: _Deadline
    ) raises NetError -> _WebSocketFrame:
        var scratch = Array[Byte, 4096](fill=0)
        while not self._decoder.complete():
            self._drive_ping(deadline)
            var timeout = _remaining(deadline)
            if not self._sent_close and self._config.ping_interval._value > 0:
                timeout = Timeout.nanoseconds(
                    min(
                        timeout._value,
                        UInt64(
                            max(
                                1,
                                self._ping_deadline._expires_at.value()
                                - perf_counter_ns(),
                            )
                        ),
                    )
                )
            var count: Int
            try:
                count = self._stream.value().read(
                    Span(scratch)[0 : min(4096, self._decoder.needed())],
                    timeout,
                )
            except err:
                if (
                    err.kind == NetErrorKind.timeout()
                    and not deadline.expired()
                    and not self._sent_close
                    and self._config.ping_interval._value > 0
                ):
                    continue
                self._abort()
                raise err^
            if count == 0:
                self._closed = True
                raise NetError(
                    NetErrorKind.closed(),
                    "WebSocket read",
                    None,
                    "stream closed",
                )
            try:
                _ = self._decoder.feed(Span(scratch)[0:count])
            except err:
                self._fail(err.code, err.reason, deadline)
        try:
            return self._decoder.take_frame()
        except err:
            self._fail(err.code, err.reason, deadline)
        raise NetError(
            NetErrorKind.invalid_state(),
            "WebSocket frame",
            None,
            "frame unavailable",
        )

    def _peer_close[
        o: ImmOrigin
    ](mut self, payload: Span[Byte, o], deadline: _Deadline) raises NetError:
        var code: UInt16 = 1005
        var reason = String()
        if len(payload) >= 2:
            code = (UInt16(payload[0]) << 8) | UInt16(payload[1])
            reason = String(from_utf8_lossy=payload[2:])
        self._close_info = WebSocketCloseInfo(code, reason^)
        self._closed = True
        try:
            if not self._sent_close:
                self._write_frame(8, payload, self._control_deadline(deadline))
                self._sent_close = True
        except err:
            self._abort()
            raise err^
        self._close_transport()

    def read_message(mut self) raises NetError -> WebSocketMessage:
        self._check_open()
        if self._config.ping_interval._value > 0:
            var remaining = max(
                0,
                self._ping_deadline._expires_at.value()
                - self._read_pause_started,
            )
            self._ping_deadline = _Deadline.from_timeout(
                Timeout.nanoseconds(UInt64(remaining))
            )
        var deadline = _Deadline.from_timeout(self._config.read_deadline)
        var opcode: UInt8 = 0
        var fragments = 0
        var payload = List[Byte]()
        var validator = _UTF8Validator()
        while True:
            var frame: _WebSocketFrame
            try:
                frame = self._read_frame(deadline)
            except err:
                self._abort()
                raise err^
            if frame.opcode == 8:
                self._peer_close(Span(frame.payload), deadline)
                raise NetError(
                    NetErrorKind.closed(),
                    "WebSocket read",
                    None,
                    "peer sent Close",
                )
            if frame.opcode == 9:
                try:
                    self._write_frame(
                        10,
                        Span(frame.payload),
                        self._control_deadline(deadline),
                    )
                except err:
                    self._abort()
                    raise err^
                continue
            if frame.opcode == 10:
                if self._waiting_pong and frame.payload == self._ping_payload:
                    self._waiting_pong = False
                    self._ping_deadline = _Deadline.from_timeout(
                        self._config.ping_interval
                    )
                continue
            if frame.opcode == 0:
                if opcode == 0:
                    self._fail(1002, "unexpected continuation frame", deadline)
            else:
                if opcode != 0:
                    self._fail(
                        1002,
                        "new data frame during fragmented message",
                        deadline,
                    )
                opcode = frame.opcode
            fragments += 1
            if fragments > self._config.max_fragment_count:
                self._fail(1008, "message exceeds fragment limit", deadline)
            if len(frame.payload) > self._config.max_message_bytes - len(
                payload
            ):
                self._fail(1009, "message exceeds configured limit", deadline)
            if opcode == 1 and self._config.validate_utf8:
                if not validator.feed(Span(frame.payload)) or (
                    frame.fin and not validator.complete()
                ):
                    self._fail(1007, "invalid message UTF-8", deadline)
            payload.extend(Span(frame.payload))
            if frame.fin:
                self._read_pause_started = perf_counter_ns()
                return WebSocketMessage(opcode, payload^)

    def close(
        deinit self, code: UInt16 = 1000, reason: StringSlice = ""
    ) raises NetError:
        var payload: List[Byte] = [Byte(code >> 8), Byte(code & 255)]
        payload.extend(reason.as_bytes())
        if len(payload) > 125:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket close",
                None,
                "close reason exceeds 123 bytes",
            )
        try:
            _validate_close(Span(payload))
        except err:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "WebSocket close",
                None,
                err.reason^,
            )
        if not self._closed:
            try:
                if not self._sent_close:
                    self._write_frame(
                        8,
                        Span(payload),
                        _Deadline.from_timeout(self._config.write_deadline),
                    )
                    self._sent_close = True
                var deadline = _Deadline.from_timeout(
                    self._config.read_deadline
                )
                while not self._closed:
                    var frame = self._read_frame(deadline)
                    if frame.opcode == 8:
                        self._peer_close(Span(frame.payload), deadline)
                    elif frame.opcode == 9:
                        var write_timeout = _remaining(deadline)
                        write_timeout = Timeout.nanoseconds(
                            min(
                                write_timeout._value,
                                self._config.write_deadline._value,
                            )
                        )
                        self._write_frame(
                            10,
                            Span(frame.payload),
                            _Deadline.from_timeout(write_timeout),
                        )
            except err:
                self._close_transport()
                raise err^
        self._close_transport()
