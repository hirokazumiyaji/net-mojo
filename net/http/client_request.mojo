"""Replayable empty or byte-backed HTTP client requests."""

from net.timeout import Timeout
from .headers import Headers
from .client_error import ClientError
from ._url import parse_url


struct ClientRequestBody(Movable):
    var bytes: List[Byte]

    def __init__(out self, var bytes: List[Byte]):
        self.bytes = bytes^

    @staticmethod
    def empty() -> Self:
        return Self(List[Byte]())


struct ClientRequest(Movable):
    var method: String
    var url: String
    var headers: Headers
    var body: ClientRequestBody
    var deadline: Optional[Timeout]

    def __init__(
        out self,
        var method: String,
        var url: String,
        var headers: Headers,
        var body: ClientRequestBody,
        deadline: Optional[Timeout] = None,
    ):
        self.method = method^
        self.url = url^
        self.headers = headers^
        self.body = body^
        self.deadline = deadline.copy()

    @staticmethod
    def get(var url: String) raises ClientError -> Self:
        var _ = parse_url(url)
        return Self("GET", url^, Headers(), ClientRequestBody.empty())

    @staticmethod
    def post_bytes(
        var url: String, var body: List[Byte]
    ) raises ClientError -> Self:
        var _ = parse_url(url)
        return Self("POST", url^, Headers(), ClientRequestBody(body^))
