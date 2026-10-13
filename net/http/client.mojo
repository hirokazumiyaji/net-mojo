"""Synchronous HTTP/1.1 client with per-origin connection leases."""

from net import TCPConn
from net.error import _timeout_error
from net.address import _resolve_parsed
from net._sys.common import SOCK_STREAM
from net.tcp import _dial_tcp_candidates
from net.tls import TLSContext
from net.timeout import _Deadline
from .client_error import ClientError
from .client_config import ClientConfig
from .client_request import ClientRequest, ClientRequestBody
from .client_response import Response, ResponseBody
from .config import ServerConfig
from ._client_pool import (
    _ClientPool,
    _ClientLease,
    _ClientConnection,
    _client_transport,
    _phase_deadline,
)
from ._encoder import encode_request_head, _has_close_token
from ._parser import parse_response_head
from ._url import parse_url, resolve_redirect
from .headers import Headers


struct Client(Movable):
    var _config: ClientConfig
    var _pool: _ClientPool
    var _parser_config: ServerConfig
    var _tls_context: Optional[TLSContext]

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
        self._tls_context = None

    def do(mut self, var request: ClientRequest) raises ClientError -> Response:
        var timeout = self._config.request_timeout.copy()
        if request.deadline:
            timeout = request.deadline.value().copy()
        var deadline = _Deadline.from_timeout(timeout)
        var hops = 0
        while True:
            var response = self._request(request, deadline)
            if not self._config.redirect.follow or (
                response.status != 301
                and response.status != 302
                and response.status != 303
                and response.status != 307
                and response.status != 308
            ):
                return response^
            var location = response.headers.get_first("location")
            if not location:
                return response^
            if hops >= self._config.redirect.max_hops:
                raise ClientError(
                    ClientError.REDIRECT, "HTTP redirect limit exceeded"
                )
            var previous = parse_url(request.url)
            var next_url: String
            try:
                next_url = resolve_redirect(previous, location.value())
            except error:
                raise ClientError(ClientError.REDIRECT, error.message.copy())
            var next_origin = parse_url(next_url)
            var rewrite = (
                response.status <= 303
                and request.method != "GET"
                and request.method != "HEAD"
            )
            var headers = Headers()
            try:
                for i in range(len(request.headers)):
                    var name = request.headers.name_at(i)
                    var lower = name.lower()
                    if not previous.same_origin(next_origin) and (
                        lower == "authorization"
                        or lower == "cookie"
                        or lower == "host"
                    ):
                        continue
                    if rewrite and (
                        lower == "content-length"
                        or lower == "transfer-encoding"
                        or lower == "content-type"
                    ):
                        continue
                    headers.add_bytes(
                        name^, request.headers._value_bytes_span(i)
                    )
            except error:
                raise _client_transport(ClientError.PARSE, error^)
            try:
                response.close()
            except:
                pass
            request.headers = headers^
            request.url = next_url^
            if rewrite:
                request.method = "GET"
                request.body = ClientRequestBody.empty()
            hops += 1

    def _request(
        mut self,
        request: ClientRequest,
        deadline: _Deadline,
        allow_retry: Bool = True,
    ) raises ClientError -> Response:
        var url = parse_url(request.url)
        if deadline.expired():
            raise ClientError(
                ClientError.TIMEOUT, "HTTP request deadline expired"
            )
        if url.scheme == "https" and not self._config.tls:
            raise ClientError(ClientError.TLS, "HTTPS requires ClientTLSConfig")
        var head = encode_request_head(
            request.method,
            url.target,
            url.authority,
            request.headers,
            len(request.body.bytes),
            False,
            self._config.user_agent,
        )
        var lease = self._pool.acquire(url, fresh=not allow_retry)
        if not lease.connection:
            var connect_deadline = _phase_deadline(
                deadline, self._config.connect_timeout
            )
            var socket: TCPConn
            try:
                var addresses = _resolve_parsed(
                    url.host.copy(), url.port, SOCK_STREAM
                )
                if connect_deadline.expired():
                    raise _timeout_error("HTTP connect")
                socket = _dial_tcp_candidates(addresses^, connect_deadline)
            except error:
                raise _client_transport(ClientError.DIAL, error^)
            if url.scheme == "https":
                try:
                    if not self._tls_context:
                        self._tls_context = TLSContext.client(
                            self._config.tls.value().library_path.copy(),
                            self._config.tls.value().ca_bundle_path.copy(),
                            self._config.tls.value().alpn.copy(),
                            self._config.tls.value().insecure_skip_verify,
                        )
                    lease.connection = _ClientConnection(
                        self._tls_context.value().connect(
                            socket^,
                            url.host.copy(),
                            self._config.tls.value().sni_override.copy(),
                        )
                    )
                except error:
                    raise _client_transport(ClientError.TLS, error^)
                lease.connection.value().handshake(connect_deadline)
            else:
                lease.connection = _ClientConnection(socket^)
        var reused = lease.reused
        var response_started = False
        try:
            return self._exchange(
                request, head, lease^, deadline, response_started
            )
        except error:
            var eligible = (
                request.method == "GET"
                or request.method == "HEAD"
                or request.headers.count("idempotency-key") > 0
            )
            if (
                allow_retry
                and reused
                and eligible
                and not response_started
                and (
                    error.kind == ClientError.READ
                    or error.kind == ClientError.WRITE
                )
            ):
                return self._request(request, deadline, False)
            raise error^

    def _exchange(
        mut self,
        request: ClientRequest,
        head: List[Byte],
        var lease: _ClientLease,
        deadline: _Deadline,
        mut response_started: Bool,
    ) raises ClientError -> Response:
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
            response_started = True
            wire.extend(Span(scratch)[:count])

    def close(mut self):
        self._pool.close()
        self._tls_context = None

    def __deinit__(deinit self):
        self._pool.close()
