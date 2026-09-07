"""Bounded buffered response writer for `net.http`.

The handler mutates the writer; the server sends after the handler
returns. The writer never touches the socket and never waits.
The connection owns the encoded bytes until the send completes, so
handler-local values must be copied in (which `write` does) instead
of borrowed into a send queue.
"""

from net.error import NetError, NetErrorKind

from .headers import Headers


struct ResponseWriter(Movable, Sized):
    """Owned response under construction."""

    var status: Int
    var headers: Headers
    var body: List[Byte]
    var should_close: Bool
    var _limit: Int

    def __init__(out self, body_limit: Int):
        self.status = 200
        self.headers = Headers()
        self.body = List[Byte]()
        self.should_close = False
        self._limit = body_limit

    def __len__(self) -> Int:
        return len(self.body)

    def set_status(mut self, status: Int):
        self.status = status

    def set_should_close(mut self, should_close: Bool):
        self.should_close = should_close

    def body_limit(self) -> Int:
        return self._limit

    def write[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError:
        if len(self.body) + len(data) > self._limit:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "write response body",
                None,
                "response body exceeds limit",
            )
        for i in range(len(data)):
            self.body.append(data[i])

    def write_string(mut self, data: StringSlice) raises NetError:
        var bytes = data.as_bytes()
        if len(self.body) + len(bytes) > self._limit:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "write response body",
                None,
                "response body exceeds limit",
            )
        for i in range(len(bytes)):
            self.body.append(bytes[i])


def has_body_for_status(status: Int, is_head: Bool) -> Bool:
    """Reports whether the encoder must frame a response body.

    HEAD never frames a body, and 1xx / 204 / 304 never do either,
    regardless of any buffered bytes.
    """
    if is_head:
        return False
    if status >= 100 and status <= 199:
        return False
    if status == 204 or status == 304:
        return False
    return True
