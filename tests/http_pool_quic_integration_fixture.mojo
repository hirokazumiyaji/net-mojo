from std.os import getenv

from net import Timeout, listen_tcp
from net.http import ServerConfig, ServerPool
from net.quic import QuicProvider, QuicUDPEndpoint
from net.tls import TLSContext
from net.udp import listen_udp
from tests.http_pool_integration_fixture import _Factory


def main() raises:
    var quic_only = getenv("POOL_QUIC_ONLY") == "1"
    var config = ServerConfig.default()
    config.max_accept_per_tick = 1
    config.shutdown_grace = Timeout.milliseconds(250)
    var pool = ServerPool(config^, workers=4 if quic_only else 2)
    var udp = listen_udp("127.0.0.1:0")
    var port = udp.local_address().port
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var quic_config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    pool.add_quic_endpoint(QuicUDPEndpoint(provider.server(quic_config^), udp^))
    if not quic_only:
        var tcp = listen_tcp(String("127.0.0.1:") + String(port))
        pool.add_tls_listener(
            tcp^,
            TLSContext.server(
                "build/tls/libnet_tls",
                "build/tls/test-cert.pem",
                "build/tls/test-key.pem",
                "http/1.1",
            ),
        )
    print(String("READY ") + String(port))
    var factory = _Factory(pool.control())
    pool.serve(factory)
    print("EXIT")
