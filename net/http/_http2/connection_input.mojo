"""Bootstrap and dispatch arbitrary HTTP/2 connection input."""

from .connection_bootstrap import Http2ConnectionBootstrap
from .frame_dispatcher import Http2FrameDispatcher
from .frame import FrameParseResult
from .frame_reader import Http2FrameReader
from .settings_state import Http2PeerSettingsSnapshot


@fieldwise_init
struct Http2ConnectionInputResult(Movable):
    var kind: UInt8
    var consumed: Int
    var frame_type: UInt8
    var flags: UInt8
    var stream_id: UInt32
    var value: UInt32
    var output: List[Byte]
    var payload: List[Byte]

    @staticmethod
    def need_more(consumed: Int) -> Self:
        return Self(
            kind=1,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=UInt32(0),
            value=UInt32(0),
            output=List[Byte](),
            payload=List[Byte](),
        )

    @staticmethod
    def output_frame(consumed: Int, var output: List[Byte]) -> Self:
        return Self(
            kind=2,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=UInt32(0),
            value=UInt32(0),
            output=output^,
            payload=List[Byte](),
        )

    @staticmethod
    def frame(
        consumed: Int,
        frame_type: UInt8,
        flags: UInt8,
        stream_id: UInt32,
        var payload: List[Byte],
    ) -> Self:
        return Self(
            kind=3,
            consumed=consumed,
            frame_type=frame_type,
            flags=flags,
            stream_id=stream_id,
            value=UInt32(0),
            output=List[Byte](),
            payload=payload^,
        )

    @staticmethod
    def event(
        kind: UInt8,
        consumed: Int,
        stream_id: UInt32,
        value: UInt32,
    ) -> Self:
        return Self(
            kind=kind,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=stream_id,
            value=value,
            output=List[Byte](),
            payload=List[Byte](),
        )

    @staticmethod
    def ignored(consumed: Int) -> Self:
        return Self(
            kind=6,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=UInt32(0),
            value=UInt32(0),
            output=List[Byte](),
            payload=List[Byte](),
        )

    @staticmethod
    def error(consumed: Int) -> Self:
        return Self(
            kind=7,
            consumed=consumed,
            frame_type=Byte(0),
            flags=Byte(0),
            stream_id=UInt32(0),
            value=UInt32(0),
            output=List[Byte](),
            payload=List[Byte](),
        )

    def is_need_more(self) -> Bool:
        return self.kind == 1

    def is_output(self) -> Bool:
        return self.kind == 2

    def is_frame(self) -> Bool:
        return self.kind == 3

    def is_window_update(self) -> Bool:
        return self.kind == 4

    def is_reset(self) -> Bool:
        return self.kind == 5

    def is_ignored(self) -> Bool:
        return self.kind == 6

    def is_goaway(self) -> Bool:
        return self.kind == 8

    def is_error(self) -> Bool:
        return self.kind == 7


struct Http2ServerConnectionInput(Movable):
    var _bootstrap: Http2ConnectionBootstrap
    var _reader: Http2FrameReader
    var _dispatcher: Http2FrameDispatcher
    var _failed: Bool

    def __init__(
        out self,
        max_frame_size: Int = 16384,
        max_concurrent_streams: Int = 100,
    ):
        self._bootstrap = Http2ConnectionBootstrap(
            max_frame_size, max_concurrent_streams
        )
        self._reader = Http2FrameReader(max_frame_size)
        self._dispatcher = Http2FrameDispatcher(self._bootstrap.peer_settings())
        self._failed = False

    def consume[
        origin: Origin
    ](mut self, data: Span[Byte, origin],) -> Http2ConnectionInputResult:
        if self._failed:
            return Http2ConnectionInputResult.error(0)

        if not self._bootstrap.is_ready():
            var bootstrap = self._bootstrap.consume(data)
            if bootstrap.is_error():
                self._failed = True
                return Http2ConnectionInputResult.error(bootstrap.consumed)
            if bootstrap.is_ready():
                self._dispatcher = Http2FrameDispatcher(
                    self._bootstrap.peer_settings()
                )
            var consumed = bootstrap.consumed
            if len(bootstrap.output) > 0:
                var output = bootstrap.output.copy()
                return Http2ConnectionInputResult.output_frame(
                    consumed, output^
                )
            return Http2ConnectionInputResult.need_more(consumed)

        var read = self._reader.consume(data)
        if read.is_error():
            self._failed = True
            return Http2ConnectionInputResult.error(read.consumed)
        if read.is_need_more():
            return Http2ConnectionInputResult.need_more(read.consumed)

        var consumed = read.consumed
        var frame_type = read.frame_type
        var flags = read.flags
        var stream_id = read.stream_id
        var payload = read.payload.copy()
        var dispatched = self._dispatcher.accept(
            FrameParseResult.complete(
                frame_type, flags, stream_id, len(payload)
            ),
            Span(payload),
        )
        if dispatched.is_error():
            self._failed = True
            return Http2ConnectionInputResult.error(read.consumed)
        if dispatched.is_output():
            var output = dispatched.output.copy()
            return Http2ConnectionInputResult.output_frame(consumed, output^)
        if dispatched.is_window_update():
            return Http2ConnectionInputResult.event(
                4, consumed, dispatched.stream_id, dispatched.value
            )
        if dispatched.is_reset():
            return Http2ConnectionInputResult.event(
                5, consumed, dispatched.stream_id, dispatched.value
            )
        if dispatched.is_goaway():
            return Http2ConnectionInputResult.event(
                8, consumed, dispatched.stream_id, dispatched.value
            )
        if dispatched.is_ignored():
            if read.frame_type == Byte(4) or read.frame_type == Byte(6):
                return Http2ConnectionInputResult.ignored(consumed)
            if (
                read.frame_type != Byte(0)
                and read.frame_type != Byte(1)
                and read.frame_type != Byte(9)
            ):
                return Http2ConnectionInputResult.ignored(consumed)

        return Http2ConnectionInputResult.frame(
            consumed,
            frame_type,
            flags,
            stream_id,
            payload^,
        )

    def is_failed(self) -> Bool:
        return self._failed

    def peer_settings(self) -> Http2PeerSettingsSnapshot:
        return self._dispatcher.peer_settings()

    def assembling_headers_stream(self) -> UInt32:
        return self._reader.assembling_headers_stream()
