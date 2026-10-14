"""RFC 6455 server: accept on the HTTP loop, adopt on a single owned worker."""

from net.error import NetError, NetErrorKind
from . import HijackSender, Request, ResponseWriter, Headers
from ._websocket_hash import _websocket_accept_key, _valid_websocket_key
from ._websocket_types import (
    WebSocketConfig,
    WebSocketMessage,
    WebSocketCloseInfo,
    OPCODE_CONTINUATION,
    OPCODE_TEXT,
    OPCODE_BINARY,
    OPCODE_CLOSE,
    OPCODE_PING,
    OPCODE_PONG,
    _valid_protocol,
)
from ._websocket_conn import (
    DuplexStream,
    WebSocketConn,
    _HijackedWebSocketStream,
)


struct WebSocketUpgrade(Movable):
    """Owned handoff retaining the negotiated protocol and configuration."""

    var _sender: Optional[HijackSender]
    var _config: WebSocketConfig
    var _protocol: String

    def __init__(
        out self,
        var sender: HijackSender,
        var config: WebSocketConfig,
        var protocol: String,
    ):
        self._sender = sender^
        self._config = config^
        self._protocol = protocol^


def _handshake_error(detail: StringSlice) -> NetError:
    return NetError(
        NetErrorKind.invalid_argument(),
        "WebSocket handshake",
        None,
        String(detail),
    )


def _has_token(headers: Headers, name: StringSlice, token: StringSlice) -> Bool:
    var values = headers.get_all(name)
    for value in values:
        for part in value.split(","):
            if part.strip().lower() == token:
                return True
    return False


def _handshake(
    req: Request, config: WebSocketConfig
) raises NetError -> Headers:
    config._validate()
    if req.method != "GET" or req.version.value != 1:
        raise _handshake_error("requires GET HTTP/1.1")
    if not _has_token(req.headers, "Connection", "upgrade") or not _has_token(
        req.headers, "Upgrade", "websocket"
    ):
        raise _handshake_error(
            "requires Connection Upgrade and Upgrade websocket"
        )
    var versions = req.headers.get_all("Sec-WebSocket-Version")
    var keys = req.headers.get_all("Sec-WebSocket-Key")
    if len(versions) != 1 or String(versions[0].strip()) != "13":
        raise _handshake_error("requires WebSocket version 13")
    if len(keys) != 1 or not _valid_websocket_key(keys[0].strip()):
        raise _handshake_error("requires a canonical 16-byte Sec-WebSocket-Key")
    var requested = List[String]()
    var offers = req.headers.get_all("Sec-WebSocket-Protocol")
    for offer in offers:
        for token in offer.split(","):
            var name = token.strip()
            if not _valid_protocol(name):
                raise _handshake_error("invalid offered subprotocol")
            for previous in requested:
                if previous == name:
                    raise _handshake_error("duplicate offered subprotocol")
            requested.append(String(name))
    var selected = String()
    for supported in config.subprotocols:
        for offer in requested:
            if selected.byte_length() == 0 and supported == offer:
                selected = supported.copy()
    var headers = Headers()
    headers.add(String("Connection"), String("Upgrade"))
    headers.add(String("Upgrade"), String("websocket"))
    headers.add(
        String("Sec-WebSocket-Accept"), _websocket_accept_key(keys[0].strip())
    )
    if selected.byte_length() > 0:
        headers.add(String("Sec-WebSocket-Protocol"), selected^)
    return headers^


def websocket_accept(
    req: Request,
    mut writer: ResponseWriter,
    config: WebSocketConfig = WebSocketConfig.default(),
) raises NetError -> WebSocketUpgrade:
    var headers = _handshake(req, config)
    var protocol = String()
    var selected = headers.get_first("Sec-WebSocket-Protocol")
    if selected:
        protocol = selected.take()
    var sender = writer.switch_protocols(headers^)
    return WebSocketUpgrade(sender^, config.copy(), protocol^)


def websocket_adopt(
    var upgrade: WebSocketUpgrade,
) raises NetError -> WebSocketConn[_HijackedWebSocketStream]:
    var raw = upgrade._sender.take().take_connection()
    var config = upgrade._config.copy()
    var protocol = upgrade._protocol.copy()
    return WebSocketConn[_HijackedWebSocketStream](
        _HijackedWebSocketStream(raw^), config, protocol^
    )
