from std.time import sleep

from net import listen_tcp
from net.http import (
    Handler,
    HandlerFactory,
    Request,
    ResponseWriter,
    ServerConfig,
    ServerControl,
    ServerPool,
)
from net.tls import TLSContext


@fieldwise_init
struct _PoolHandler(Handler):
    var worker_id: Int
    var control: ServerControl

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        if request.path == "/shutdown":
            self.control.request_shutdown()
            writer.write_string("bye")
            return
        sleep(0.001)
        writer.write_string(String("worker:") + String(self.worker_id))


@fieldwise_init
struct _Factory(HandlerFactory):
    comptime HandlerType = _PoolHandler
    var control: ServerControl

    def build(mut self, worker_id: Int) raises -> _PoolHandler:
        return _PoolHandler(worker_id, self.control.copy())


def main() raises:
    var config = ServerConfig.default()
    config.max_accept_per_tick = 1
    var pool = ServerPool(config^, workers=2)
    var listener = listen_tcp("127.0.0.1:0")
    var port = listener.local_address().port
    pool.add_tls_listener(
        listener^,
        TLSContext.server(
            "build/tls/libnet_tls",
            "build/tls/test-cert.pem",
            "build/tls/test-key.pem",
            "h2,http/1.1",
        ),
    )
    print(String("READY ") + String(port))
    var factory = _Factory(pool.control())
    pool.serve(factory)
    print("EXIT")
