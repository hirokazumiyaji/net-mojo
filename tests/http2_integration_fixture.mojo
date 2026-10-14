from std.testing import assert_equal
from net import Timeout, listen_tcp
from net.http import (
    Handler,
    Headers,
    Request,
    ResponseSender,
    ResponseWriter,
    Server,
    ServerConfig,
)
from net.tls import TLSContext


@fieldwise_init
struct _DetachedWork(Movable):
    var sender: ResponseSender
    var mode: Int
    var step: Int


struct _IntegrationHandler(Handler):
    var shutdown: Bool
    var detached: List[_DetachedWork]
    var cancelled: Int
    var backpressured: Int
    var fallback_cancelled: Int
    var release_trailers: Bool
    var stop_continuous: Bool

    def __init__(out self):
        self.shutdown = False
        self.detached = List[_DetachedWork]()
        self.cancelled = 0
        self.backpressured = 0
        self.fallback_cancelled = 0
        self.release_trailers = False
        self.stop_continuous = False

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/fallback-cancel-count":
            writer.write_string(String(self.fallback_cancelled))
            return
        if req.path == "/cancel-count":
            writer.write_string(String(self.cancelled))
            return
        if req.path == "/queue-count":
            writer.write_string(String(self.backpressured))
            return
        if req.path == "/finish-continuous":
            self.stop_continuous = True
            writer.write_string("finished")
            return
        if req.path == "/release-trailers":
            self.release_trailers = True
            writer.write_string("released")
            return
        if req.path == "/detached-changing-trailers":
            var sender = writer.detach()
            sender.start()
            self.detached.append(_DetachedWork(sender^, 6, 0))
            return
        if req.path == "/detached-continuous":
            writer._queue_limit = 1024 * 1024
            var sender = writer.detach()
            sender.start()
            self.detached.append(_DetachedWork(sender^, 7, 0))
            return
        if req.path == "/detached-oversized":
            var sender = writer.detach()
            var value = String(
                from_utf8_lossy=Span(List[Byte](length=70000, fill=Byte(120)))
            )
            var headers = Headers()
            headers.add("X-Pad", value^)
            sender.start(headers=headers^)
            self.detached.append(_DetachedWork(sender^, 5, 0))
            return
        if req.path == "/deferred":
            self.detached.append(_DetachedWork(writer.detach(), 0, 0))
            return
        if (
            req.path == "/detached-stream"
            or req.path == "/detached-trailers"
            or req.path == "/detached-hold"
            or req.path == "/idle-detached"
        ):
            var sender = writer.detach()
            sender.start()
            var mode = 1
            if req.path == "/detached-trailers":
                mode = 2
            elif req.path == "/detached-hold":
                mode = 3
            elif req.path == "/idle-detached":
                mode = 4
            self.detached.append(_DetachedWork(sender^, mode, 0))
            return
        if req.path == "/shutdown":
            self.shutdown = True
            writer.set_status(200)
            writer.set_should_close(True)
            writer.write_string("bye")
            return
        if req.path == "/trigger-shutdown":
            self.shutdown = True
            writer.set_status(200)
            writer.write_string("shutdown requested")
            return
        if req.path == "/echo":
            writer.set_status(200)
            writer.headers.add(String("Content-Type"), String("text/plain"))
            writer.write(Span(req.body))
            return
        if req.path == "/large":
            writer.set_status(200)
            writer.headers.add(
                String("Content-Type"), String("application/octet-stream")
            )
            var size = 128 * 1024
            var buf = List[Byte](capacity=size)
            for i in range(size):
                buf.append(Byte(97 + (i % 26)))
            writer.write(Span(buf))
            return
        if req.path == "/sibling":
            writer.set_status(200)
            writer.write_string("sibling ok")
            return
        writer.set_status(404)
        writer.write_string("missing")

    def advance(mut self) raises:
        var index = 0
        while index < len(self.detached):
            if self.detached[index].sender.is_cancelled():
                self.cancelled += 1
                if self.detached[index].mode == 5:
                    self.fallback_cancelled += 1
                _ = self.detached.pop(index)
                continue
            var mode = self.detached[index].mode
            if mode == 0:
                self.detached[index].step += 1
                if self.detached[index].step < 2:
                    index += 1
                    continue
                var body = List[Byte]("deferred ok".as_bytes())
                self.detached[index].sender.respond(status=201, body=body^)
                _ = self.detached.pop(index)
                continue
            if mode == 7 and self.stop_continuous:
                self.detached[index].sender.finish()
                _ = self.detached.pop(index)
                continue
            if mode == 6:
                if self.release_trailers:
                    var trailers = Headers()
                    var value = String(
                        from_utf8_lossy=Span(
                            List[Byte](length=256, fill=Byte(120))
                        )
                    )
                    trailers.add("X-Meta", value^)
                    self.detached[index].sender.finish(trailers=trailers^)
                    _ = self.detached.pop(index)
                    continue
                index += 1
                continue
            if mode == 4 or mode == 5:
                index += 1
                continue
            var count = 256 if mode == 7 else 8
            for _ in range(count):
                var step = self.detached[index].step
                var chunk = List[Byte](length=4096, fill=Byte(97 + step % 26))
                if not self.detached[index].sender.send(Span(chunk)):
                    self.backpressured += 1
                    break
                self.detached[index].step += 1
                if mode != 3 and mode != 7 and self.detached[index].step == 40:
                    var trailers = Headers()
                    if mode == 2:
                        trailers.add("X-Digest", "done")
                    self.detached[index].sender.finish(trailers=trailers^)
                    _ = self.detached.pop(index)
                    break
            if index < len(self.detached):
                index += 1


def main() raises:
    var config = ServerConfig.default()
    config.max_body_bytes = 2 * 1024 * 1024
    config.http2_max_control_frames_per_second = 100000
    config.write_deadline = Timeout.milliseconds(100)
    config.max_response_headers_bytes = 131072
    config.max_http2_streams_per_connection = 4
    config.stream_queue_limit = 65536
    config.detached_response_timeout = Timeout.milliseconds(500)
    var server = Server(config^)
    server.add_tls_listener(
        listen_tcp("127.0.0.1:0"),
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2",
        ),
    )
    print(String("READY ") + String(server.local_address().port))
    var handler = _IntegrationHandler()
    while not handler.shutdown:
        var wait = Timeout.seconds(2)
        if len(handler.detached) > 0:
            wait = Timeout.milliseconds(10)
        _ = server.tick(handler, wait^)
        handler.advance()
    server.request_shutdown()
    while server.tick(handler, Timeout.seconds(2)):
        pass
    assert_equal(server.active_connections(), 0)
