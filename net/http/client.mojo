"""Synchronous HTTP/1.1 client with per-origin connection leases."""

from net.address import _resolve_parsed
from net._sys.common import SOCK_STREAM
from net.tcp import _dial_tcp_candidates
from net.timeout import _Deadline
from .client_error import ClientError
from .client_config import ClientConfig
from .client_request import ClientRequest
from .client_response import Response, ResponseBody
from .config import ServerConfig
from ._client_pool import (
    _ClientPool,
    _ClientConnection,
    _client_transport,
    _phase_deadline,
)
from ._encoder import encode_request_head, _has_close_token
from ._parser import parse_response_head
from ._url import parse_url


struct Client(Movable):
    var _config: ClientConfig
    var _pool: _ClientPool
    var _parser_config: ServerConfig

    def __init__(out self, var config: ClientConfig) raises ClientError:
        config._validate()
        var parser_config: ServerConfig
        try:
            parser_config = ServerConfig.default()
        except error:
            raise ClientError.parse(String(error))
        parser_config.max_response_headers_bytes = (
            config.max_response_headers_bytes
        )
        parser_config.max_response_headers_count = (
            config.max_response_headers_count
        )
        self._parser_config = parser_config^
        self._pool = _ClientPool(config)
        self._config = config^

    def do(mut self, var request: ClientRequest) raises ClientError -> Response:
        var timeout = self._config.request_timeout.copy()
        if request.deadline:
            timeout = request.deadline.value().copy()
        var deadline = _Deadline.from_timeout(timeout)
        return self._request(request, deadline)

    def _request(
        mut self, request: ClientRequest, deadline: _Deadline
    ) raises ClientError -> Response:
        var url = parse_url(request.url)
        if deadline.expired():
            raise ClientError(
                ClientError.TIMEOUT, "HTTP request deadline expired"
            )
        if url.scheme == "https":
            raise ClientError(
                ClientError.TLS, "HTTPS client transport is not enabled"
            )
        var head = encode_request_head(
            request.method,
            url.target,
            url.authority,
            request.headers,
            len(request.body.bytes),
            False,
            self._config.user_agent,
        )
        var lease = self._pool.acquire(url)
        if not lease.connection:
            var connect_deadline = _phase_deadline(
                deadline, self._config.connect_timeout
            )
            try:
                var addresses = _resolve_parsed(
                    url.host.copy(), url.port, SOCK_STREAM
                )
                if connect_deadline.expired():
                    lease.finish(False)
                else:
                    lease.connection = _ClientConnection(
                        _dial_tcp_candidates(addresses^, connect_deadline)
                    )
            except error:
                raise _client_transport(ClientError.DIAL, error^)
            if not lease.active:
                raise ClientError(
                    ClientError.TIMEOUT, "HTTP connect deadline expired"
                )
        lease.connection.value().write_all(Span(head), deadline)
        lease.connection.value().write_all(Span(request.body.bytes), deadline)
        var header_deadline = _phase_deadline(
            deadline, self._config.response_header_timeout
        )
        var wire = List[Byte]()
        var scratch = Array[Byte, 8192](fill=0)
        while True:
            if header_deadline.expired():
                raise ClientError(
                    ClientError.TIMEOUT, "HTTP response header deadline expired"
                )
            var outcome = parse_response_head(
                Span(wire), self._parser_config, request.method
            )
            if outcome.is_error():
                raise outcome.error.copy()
            if outcome.is_complete():
                if outcome.status < 200:
                    wire = List[Byte](Span(wire)[outcome.consumed :])
                    continue
                var reusable = not outcome.should_close
                for i in range(len(request.headers)):
                    if request.headers.name_at(i).lower() == "connection":
                        if _has_close_token(
                            request.headers._value_bytes_span(i)
                        ):
                            reusable = False
                var pending = List[Byte](Span(wire)[outcome.consumed :])
                var body = ResponseBody(
                    lease^,
                    pending^,
                    outcome.framing,
                    outcome.content_length,
                    reusable,
                    deadline,
                    self._config,
                )
                return Response(
                    outcome.status,
                    outcome.reason.copy(),
                    outcome.version.copy(),
                    outcome.take_headers(),
                    body^,
                )
            var maximum = min(
                8192, self._config.max_response_headers_bytes - len(wire) + 1
            )
            var count = lease.connection.value().read(
                Span(scratch)[:maximum], header_deadline
            )
            if count == 0:
                raise ClientError(
                    ClientError.READ,
                    "connection closed before response headers",
                )
            wire.extend(Span(scratch)[:count])

    def close(mut self):
        self._pool.close()

    def __deinit__(deinit self):
        self._pool.close()
