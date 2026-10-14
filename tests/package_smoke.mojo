from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    DefaultHandlerFactory,
    Handler,
    Headers,
    HttpVersion,
    MiddlewareFn,
    LoggingHandler,
    RecoverHandler,
    Request,
    ServerPool,
    HijackedConn,
    HijackSender,
    ResponseSender,
    ResponseWriter,
    RouteHandler,
    ServerConfig,
    ServeMux,
    StdoutLogSink,
    TimeoutHandler,
    apply_middleware,
    has_body_for_status,
)
from net.http.websocket import (
    OPCODE_TEXT,
    WebSocketConfig,
    WebSocketMessage,
    WebSocketCloseInfo,
    WebSocketUpgrade,
    WebSocketConn,
    websocket_accept,
    websocket_adopt,
)
from net.http._parser import parse_one


def _to_bytes(data: StringSlice) -> List[Byte]:
    var out = List[Byte]()
    var bytes = data.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _check_http_codec() raises:
    # Proves the precompiled artifact ships `net.http` and its codec:
    # parse a minimal request, check header case-insensitivity, and
    # confirm body rules without touching the network.
    var config = ServerConfig.default()
    var buf = _to_bytes("GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n")
    var result = parse_one(Span(buf), config)
    if not result.is_complete():
        raise Error("packaged net.http parser failed")
    if result.request.method != "GET" or result.request.path != "/hello":
        raise Error("packaged net.http request mismatch")
    var body = result.request.body_reader()
    if body.is_streaming() or not body.is_eof() or len(body.buffered()) != 0:
        raise Error("packaged RequestBody view mismatch")
    var headers = Headers()
    headers.add(String("Content-Type"), String("text/plain"))
    var found = headers.get_first("content-type")
    if not Bool(found) or found.value() != "text/plain":
        raise Error("packaged net.http headers mismatch")
    if not has_body_for_status(200, False):
        raise Error("packaged net.http body rule mismatch")
    if has_body_for_status(204, False):
        raise Error("packaged net.http 204 rule mismatch")
    var writer = ResponseWriter(1024)
    var sender = writer.detach()
    if not writer.is_detached():
        raise Error("packaged ResponseWriter is_detached mismatch")
    if not sender.is_active():
        raise Error("packaged ResponseSender is_active mismatch")


struct _PoolSmokeHandler(Copyable, Handler):
    def __init__(out self):
        pass

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        writer.write_string("ok")


def _check_http_pool() raises:
    var pool = ServerPool(ServerConfig.default(), workers=1)
    pool.add_listener(listen_tcp("127.0.0.1:0"))
    var control = pool.control()
    control.request_shutdown()
    var factory = DefaultHandlerFactory[_PoolSmokeHandler](_PoolSmokeHandler())
    pool.serve(factory)
    if not control.is_shutdown_requested():
        raise Error("packaged ServerPool shutdown failed")


def _packaged_route(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string(ServeMux.param(req, "name").value())


def _packaged_layer(
    req: Request, mut writer: ResponseWriter, mut next: RouteHandler
) raises:
    next.handle(req, writer)
    writer.headers.add("X-Middleware", "packaged")


def _check_http_router() raises:
    var mux = ServeMux()
    var layers = List[MiddlewareFn]()
    layers.append(MiddlewareFn(_packaged_layer))
    mux.register(
        "GET /hello/{name}",
        apply_middleware(RouteHandler(_packaged_route), layers^),
    )
    comptime RecoveredMux = RecoverHandler[ServeMux]
    comptime LoggedMux = LoggingHandler[RecoveredMux]
    var logged = LoggedMux(RecoveredMux(mux^), StdoutLogSink())
    var handler = TimeoutHandler[LoggedMux](logged^, Timeout.seconds(1))
    var req = Request(
        "GET", "/hello/package", "/hello/package", "", HttpVersion.http11()
    )
    var writer = ResponseWriter(1024)
    handler.handle(req, writer)
    if (
        writer.status != 200
        or String(from_utf8_lossy=Span(writer.body)) != "package"
    ):
        raise Error("packaged net.http router mismatch")
    if writer.headers.get_first("x-middleware").value() != "packaged":
        raise Error("packaged net.http middleware mismatch")


def _check_websocket_values() raises:
    var config = WebSocketConfig.default()
    var message = WebSocketMessage(OPCODE_TEXT, _to_bytes("packaged"))
    var close = WebSocketCloseInfo(1000, String("done"))
    if config.max_message_bytes != 1_048_576 or config.max_fragment_count != 64:
        raise Error("packaged WebSocket config mismatch")
    if message.opcode != OPCODE_TEXT or len(message.payload) != 8:
        raise Error("packaged WebSocket message mismatch")
    if close.code != 1000 or close.reason != "done":
        raise Error("packaged WebSocket Close metadata mismatch")


def main() raises:
    var listener = listen_tcp("127.0.0.1:0")
    var client = dial_tcp(String(listener.local_address()), Timeout.seconds(1))
    var server = listener.accept(Timeout.seconds(1))
    var ping: Array[Byte, 4] = [1, 2, 3, 4]
    client.write_all(Span(ping), Timeout.seconds(1))
    var received = Array[Byte, 4](fill=0)
    var count = server.read(Span(received), Timeout.seconds(1))
    if count != 4 or received[0] != 1 or received[3] != 4:
        raise Error("packaged artifact roundtrip mismatch")
    var switched = HijackedConn(server^, _to_bytes("pref"))
    if switched.is_tls() or switched.raw_fd() < 0:
        raise Error("packaged switched transport mismatch")
    count = switched.read(Span(received), Timeout.seconds(1))
    if count != 4 or String(from_utf8_lossy=Span(received)) != "pref":
        raise Error("packaged switched buffered bytes mismatch")
    _ = switched.write(Span(ping), Timeout.seconds(1))
    count = client.read(Span(received), Timeout.seconds(1))
    if count != 4 or received[0] != 1 or received[3] != 4:
        raise Error("packaged switched roundtrip mismatch")
    client.close()
    switched^.close()
    listener.close()
    print("packaged artifact roundtrip succeeded")
    _check_http_codec()
    print("packaged net.http codec succeeded")
    _check_http_pool()
    print("packaged net.http pool succeeded")

    _check_http_router()
    print("packaged net.http router succeeded")

    _check_websocket_values()
    print("packaged WebSocket values succeeded")
