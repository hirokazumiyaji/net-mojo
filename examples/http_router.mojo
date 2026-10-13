from std.time import perf_counter_ns

from net import TCPConn, Timeout, dial_tcp, listen_tcp
from net.error import NetErrorKind
from net.http import Request, ResponseWriter, ServeMux, Server, ServerConfig


def greeting(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string(String("hello, ") + ServeMux.param(req, "name").value())


def _read_to_eof(
    mut server: Server, mut mux: ServeMux, client: TCPConn
) raises -> List[Byte]:
    var wire = List[Byte]()
    var scratch = Array[Byte, 4096](fill=0)
    var expires = perf_counter_ns() + 2_000_000_000
    while perf_counter_ns() < expires:
        _ = server.tick(mux, Timeout.nanoseconds(0))
        try:
            var count = client.try_read(Span(scratch))
            if count == 0:
                return wire^
            wire.extend(Span(scratch)[0:count])
        except error:
            if error.kind != NetErrorKind.timeout():
                raise error^
    raise Error("router response timed out")


def main() raises:
    var mux = ServeMux()
    mux.handle("GET /hello/{name}", greeting)
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var client = dial_tcp(
        String("127.0.0.1:") + String(server.local_address().port),
        Timeout.seconds(2),
    )
    client.write_all(
        "GET /hello/a%2Fb HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        .as_bytes(),
        Timeout.seconds(2),
    )
    var response = _read_to_eof(server, mux, client)
    var wire = String(from_utf8_lossy=Span(response))
    if not wire.startswith("HTTP/1.1 200 OK\r\n") or not wire.endswith(
        "\r\n\r\nhello, a%2Fb"
    ):
        raise Error("router response mismatch: " + wire)
    client.close()
    print("HTTP router succeeded")
