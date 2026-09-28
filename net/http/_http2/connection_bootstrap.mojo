"""Incremental client preface and initial SETTINGS exchange."""

from .bootstrap import Http2ServerBootstrap
from .frame import parse_frame
from .preface import parse_client_preface
from .settings_state import Http2PeerSettingsSnapshot


@fieldwise_init
struct Http2BootstrapConsumeResult(Movable):
    var kind: UInt8
    var consumed: Int
    var output: List[Byte]

    @staticmethod
    def need_more(consumed: Int, var output: List[Byte]) -> Self:
        return Self(kind=1, consumed=consumed, output=output^)

    @staticmethod
    def ready(consumed: Int, var output: List[Byte]) -> Self:
        return Self(kind=2, consumed=consumed, output=output^)

    @staticmethod
    def error(consumed: Int) -> Self:
        return Self(kind=3, consumed=consumed, output=List[Byte]())

    def is_need_more(self) -> Bool:
        return self.kind == 1

    def is_ready(self) -> Bool:
        return self.kind == 2

    def is_error(self) -> Bool:
        return self.kind == 3


struct Http2ConnectionBootstrap(Movable):
    var _max_frame_size: Int
    var _protocol: Http2ServerBootstrap
    var _preface: List[Byte]
    var _frame: List[Byte]
    var _preface_complete: Bool
    var _ready: Bool
    var _failed: Bool

    def __init__(out self, max_frame_size: Int = 16384):
        self._max_frame_size = max_frame_size
        self._protocol = Http2ServerBootstrap()
        self._preface = List[Byte]()
        self._frame = List[Byte]()
        self._preface_complete = False
        self._ready = False
        self._failed = (
            max_frame_size < 16384 or max_frame_size > 0xFFFFFF
        )

    def consume[
        origin: Origin
    ](mut self, data: Span[Byte, origin]) -> Http2BootstrapConsumeResult:
        if self._failed or self._ready:
            return Http2BootstrapConsumeResult.error(0)

        var output = List[Byte]()
        var consumed = 0
        while consumed < len(data) and not self._preface_complete:
            self._preface.append(data[consumed])
            consumed += 1
            var result = parse_client_preface(Span(self._preface))
            if result.is_error():
                self._failed = True
                return Http2BootstrapConsumeResult.error(consumed)
            if result.is_complete():
                self._preface_complete = True
                _ = self._protocol.consume_client_preface(Span(self._preface))
                self._preface.clear()
                var settings = self._protocol.server_settings()
                if not settings.is_complete():
                    self._failed = True
                    return Http2BootstrapConsumeResult.error(consumed)
                _append_wire(output, Span(settings.wire))

        while consumed < len(data):
            self._frame.append(data[consumed])
            consumed += 1
            var frame = parse_frame(Span(self._frame), self._max_frame_size)
            if frame.is_error():
                self._failed = True
                return Http2BootstrapConsumeResult.error(consumed)
            if not frame.is_complete():
                continue

            var ack = self._protocol.accept_client_settings(
                frame, Span(self._frame)[9:]
            )
            self._frame.clear()
            if not ack.is_complete():
                self._failed = True
                return Http2BootstrapConsumeResult.error(consumed)
            _append_wire(output, Span(ack.wire))
            self._ready = True
            return Http2BootstrapConsumeResult.ready(consumed, output^)

        return Http2BootstrapConsumeResult.need_more(consumed, output^)

    def is_ready(self) -> Bool:
        return self._ready

    def is_failed(self) -> Bool:
        return self._failed

    def peer_settings(self) -> Http2PeerSettingsSnapshot:
        return self._protocol.peer_settings.snapshot()


def _append_wire[
    origin: Origin
](mut output: List[Byte], wire: Span[Byte, origin]):
    for i in range(len(wire)):
        output.append(wire[i])
