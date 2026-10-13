"""Buffered collection or bounded decoded input for one HTTP/2 request stream."""

from net.http._body_pipe import _BodyPipe

from .data_frame import DataFrameResult


@fieldwise_init
struct RequestBodyResult(Copyable, Equatable):
    var kind: UInt8

    @staticmethod
    def accepted() -> Self:
        return Self(kind=1)

    @staticmethod
    def too_large() -> Self:
        return Self(kind=2)

    @staticmethod
    def invalid_state() -> Self:
        return Self(kind=3)

    def is_accepted(self) -> Bool:
        return self.kind == 1

    def is_too_large(self) -> Bool:
        return self.kind == 2

    def is_invalid_state(self) -> Bool:
        return self.kind == 3


struct Http2RequestBody(Movable):
    var _limit: Int
    var _bytes: List[Byte]
    var _complete: Bool
    var _failed: Bool
    var _pipe: Optional[_BodyPipe]

    def __init__(out self, limit: Int, pipe: Optional[_BodyPipe] = None):
        self._limit = limit
        self._bytes = List[Byte]()
        self._complete = False
        self._failed = limit < 0
        self._pipe = pipe.copy()

    def append_data[
        origin: Origin
    ](
        mut self,
        frame: DataFrameResult,
        payload: Span[Byte, origin],
    ) -> RequestBodyResult:
        if self._failed or self._complete or not frame.is_valid():
            return RequestBodyResult.invalid_state()
        if (
            frame.data_offset < 0
            or frame.data_length < 0
            or frame.data_offset > len(payload)
            or frame.data_length > len(payload) - frame.data_offset
        ):
            self._failed = True
            return RequestBodyResult.invalid_state()
        if self._pipe:
            if not self._pipe.value().push(
                payload[
                    frame.data_offset : frame.data_offset + frame.data_length
                ]
            ):
                self._failed = True
                return RequestBodyResult.invalid_state()
        else:
            if frame.data_length > self._limit - len(self._bytes):
                self._failed = True
                return RequestBodyResult.too_large()
            self._bytes.extend(
                payload[
                    frame.data_offset : frame.data_offset + frame.data_length
                ]
            )
        self._complete = frame.end_stream
        return RequestBodyResult.accepted()

    def is_complete(self) -> Bool:
        return self._complete

    def size(self) -> Int:
        return self._pipe.value().total_decoded() if self._pipe else len(
            self._bytes
        )

    def is_streaming(self) -> Bool:
        return Bool(self._pipe)

    def pipe(self) -> _BodyPipe:
        return self._pipe.value().copy()

    def bytes(self) -> List[Byte]:
        return self._bytes.copy()
