from net.quic import QuicProvider


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    assert provider.version() == "0.29.3"
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    assert server.timeout_micros() == UInt64.MAX
    var packet = Array[Byte, 256](fill=0)
    _ = server.try_send_datagram(Span[mut=True](packet))
    server.on_timeout()
    print("QUIC provider Mojo FFI: ok")
