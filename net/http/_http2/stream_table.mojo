"""Bounded active client-stream table for an HTTP/2 server connection."""

from .stream_state import Http2StreamState


@fieldwise_init
struct StreamAdmissionResult(Movable):
    var kind: UInt8

    @staticmethod
    def accepted() -> Self:
        return Self(kind=1)

    @staticmethod
    def refused() -> Self:
        return Self(kind=2)

    @staticmethod
    def error() -> Self:
        return Self(kind=3)

    def is_accepted(self) -> Bool:
        return self.kind == 1

    def is_refused(self) -> Bool:
        return self.kind == 2

    def is_error(self) -> Bool:
        return self.kind == 3


@fieldwise_init
struct _ActiveStream(Movable):
    var stream_id: UInt32
    var state: Http2StreamState


struct Http2ActiveStreams(Movable):
    var _streams: List[_ActiveStream]
    var _max_active_client_streams: UInt32
    var _last_client_stream_id: UInt32

    def __init__(out self, max_active_client_streams: UInt32):
        self._streams = List[_ActiveStream]()
        self._max_active_client_streams = max_active_client_streams
        self._last_client_stream_id = UInt32(0)

    def active_count(self) -> Int:
        return len(self._streams)

    def receive_headers(
        mut self, stream_id: UInt32, end_stream: Bool
    ) -> StreamAdmissionResult:
        var index = self._find(stream_id)
        if index >= 0:
            if self._streams[index].state.receive_headers(end_stream):
                return StreamAdmissionResult.accepted()
            return StreamAdmissionResult.error()

        if (
            stream_id == UInt32(0)
            or stream_id > UInt32(0x7FFFFFFF)
            or (stream_id & UInt32(1)) == UInt32(0)
            or stream_id <= self._last_client_stream_id
        ):
            return StreamAdmissionResult.error()

        self._last_client_stream_id = stream_id
        if UInt32(len(self._streams)) >= self._max_active_client_streams:
            return StreamAdmissionResult.refused()

        var state = Http2StreamState()
        if not state.receive_headers(end_stream):
            return StreamAdmissionResult.error()
        var active = _ActiveStream(stream_id=stream_id, state=state^)
        self._streams.append(active^)
        return StreamAdmissionResult.accepted()

    def receive_data(mut self, stream_id: UInt32, end_stream: Bool) -> Bool:
        var index = self._find(stream_id)
        if index < 0 or not self._streams[index].state.receive_data(end_stream):
            return False
        if self._streams[index].state.is_closed():
            self._remove(index)
        return True

    def send_headers(mut self, stream_id: UInt32, end_stream: Bool) -> Bool:
        var index = self._find(stream_id)
        if index < 0 or not self._streams[index].state.send_headers(end_stream):
            return False
        if self._streams[index].state.is_closed():
            self._remove(index)
        return True

    def send_data(mut self, stream_id: UInt32, end_stream: Bool) -> Bool:
        var index = self._find(stream_id)
        if index < 0 or not self._streams[index].state.send_data(end_stream):
            return False
        if self._streams[index].state.is_closed():
            self._remove(index)
        return True

    def reset(mut self, stream_id: UInt32) -> Bool:
        var index = self._find(stream_id)
        if index < 0 or not self._streams[index].state.reset():
            return False
        self._remove(index)
        return True

    def _find(self, stream_id: UInt32) -> Int:
        for i in range(len(self._streams)):
            if self._streams[i].stream_id == stream_id:
                return i
        return -1

    def _remove(mut self, index: Int):
        var last = self._streams.pop()
        if index < len(self._streams):
            self._streams[index] = last^
