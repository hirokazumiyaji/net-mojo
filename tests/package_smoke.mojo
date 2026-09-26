from net import Timeout, dial_tcp, listen_tcp
from net.http import (
    Headers,
    ResponseSender,
    ResponseWriter,
    ServerConfig,
    has_body_for_status,
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
    client.close()
    server.close()
    listener.close()
    print("packaged artifact roundtrip succeeded")
    _check_http_codec()
    print("packaged net.http codec succeeded")
