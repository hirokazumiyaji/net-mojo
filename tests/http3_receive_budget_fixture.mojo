from std.os import getenv
from std.time import perf_counter_ns

from net import Timeout
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.quic import QuicProvider, QuicUDPEndpoint
from net.udp import listen_udp


struct _ReceiveBudgetHandler(Handler):
    var requests: Int

    def __init__(out self):
        self.requests = 0

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        writer.write_string("alive")
        self.requests += 1


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var listener = listen_udp("127.0.0.1:0")
    var address = String(listener.local_address())
    var native = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var config = ServerConfig.default()
    var mode = getenv("HTTP3_RECEIVE_POOL")
    if mode == "request_bytes":
        config.quic_receive_request_bytes = 0
    elif mode == "request_slots":
        config.quic_receive_request_slots = 1
    elif mode == "control_bytes":
        config.quic_receive_control_bytes = 0
    elif mode == "control_slots":
        config.quic_receive_control_slots = 1
    elif mode == "crypto_bytes":
        config.quic_receive_crypto_bytes = 0
    elif mode == "crypto_slots":
        config.quic_receive_crypto_slots = 4
    elif mode == "send_request_bytes":
        config.quic_send_request_bytes = 0
    elif mode == "send_request_slots":
        config.quic_send_request_slots = 0
    elif mode == "send_control_bytes":
        config.quic_send_control_bytes = 0
    elif mode == "send_control_slots":
        config.quic_send_control_slots = 0
    elif mode == "send_crypto_bytes":
        config.quic_send_crypto_bytes = 0
    elif mode == "send_crypto_slots":
        config.quic_send_crypto_slots = 0
    var server = Server(config^)
    server.add_quic_endpoint(
        QuicUDPEndpoint(provider.server(native^), listener^)
    )
    var handler = _ReceiveBudgetHandler()
    print("READY " + address)
    var end = Int(perf_counter_ns()) + 1_000_000_000
    while Int(perf_counter_ns()) < end:
        _ = server.tick(handler, Timeout.milliseconds(10))
    print("HANDLED", handler.requests)
