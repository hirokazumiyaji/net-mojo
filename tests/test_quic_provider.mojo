from std.testing import assert_true, assert_false
from std.time import perf_counter_ns

from net._reactor import Reactor
from net.address import SocketAddress
from net.error import NetErrorKind
from net.quic import QuicProvider, QuicUDPEndpoint, _send_at
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig
from net.timeout import Timeout
from net.udp import dial_udp, listen_udp


struct _NoopHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        pass


def _stage_pending_payload(
    mut endpoint: QuicUDPEndpoint, destination: SocketAddress
) raises:
    var payload = Array[Byte, 16](fill=0)
    for i in range(len(payload)):
        payload[i] = Byte(0x40 + i)
    endpoint.stage_outgoing_datagram(Span(payload), destination)


def test_udp_send_backpressure_preserves_pending_datagram() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    var listener = listen_udp("0.0.0.0:0")
    var endpoint = QuicUDPEndpoint(server^, listener^)
    var receiver = listen_udp("127.0.0.1:0")
    var destination = receiver.local_address()

    # Deterministic would-block via fault injection (no kernel queue
    # timing or TEST-NET routing dependency).
    _stage_pending_payload(endpoint, destination)
    assert_true(endpoint.wants_write())
    endpoint.inject_send_would_block_once()
    assert_false(endpoint.try_send())
    assert_true(endpoint.wants_write())
    # Immediate retry may succeed once the kernel drains; tolerate both
    # (still-pending with write interest, or delivered without it).
    if endpoint.try_send():
        assert_false(endpoint.wants_write())
    else:
        assert_true(endpoint.wants_write())
        # Wait for real writability and deliver the preserved datagram.
        var reactor = Reactor()
        var token = reactor.register(
            endpoint.raw_fd(), readable=False, writable=True
        )
        var delivered = False
        for _ in range(200):
            var events = reactor.wait(Timeout.milliseconds(50))
            var writable = False
            for event in events:
                if event.token == token and event.writable:
                    writable = True
                    break
            if not writable:
                continue
            if endpoint.try_send():
                delivered = True
                break
            assert_true(endpoint.wants_write())
        assert_true(delivered)
        assert_false(endpoint.wants_write())

    var received = Array[Byte, 16](fill=0)
    var result = receiver.recv_from(
        Span[mut=True](received), Timeout.seconds(1)
    )
    assert_true(result.count == 16)
    for i in range(16):
        assert_true(received[i] == Byte(0x40 + i))


def test_pending_datagram_waits_for_pacing_due_time() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var listener = listen_udp("127.0.0.1:0")
    var endpoint = QuicUDPEndpoint(provider.server(config^), listener^)
    var receiver = listen_udp("127.0.0.1:0")
    var payload = Array[Byte, 1](fill=Byte(42))
    var due = Int(perf_counter_ns()) + 10_000_000_000
    endpoint.stage_outgoing_datagram(
        Span(payload), receiver.local_address(), due
    )
    assert_false(endpoint._try_send_at(due - 1))
    assert_false(endpoint.wants_write())
    var incoming = Array[Byte, 1](fill=0)
    var received_early = False
    try:
        _ = receiver.try_recv_from(Span[mut=True](incoming))
        received_early = True
    except error:
        assert_true(error.kind == NetErrorKind.timeout())
    assert_false(received_early)
    assert_true(endpoint._try_send_at(due))
    var received = receiver.recv_from(
        Span[mut=True](incoming), Timeout.seconds(1)
    )
    assert_true(received.count == 1)
    assert_true(incoming[0] == Byte(42))


def test_pending_pacing_timer_rounds_up_to_next_microsecond() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var listener = listen_udp("127.0.0.1:0")
    var endpoint = QuicUDPEndpoint(provider.server(config^), listener^)
    var payload = Array[Byte, 1](fill=Byte(42))
    endpoint.stage_outgoing_datagram(
        Span(payload), SocketAddress.parse("127.0.0.1:1234"), 10_000
    )
    assert_true(endpoint._timeout_micros_at(8_999, UInt64.MAX) == 2)
    assert_true(endpoint._timeout_micros_at(9_000, UInt64.MAX) == 1)
    assert_true(endpoint._timeout_micros_at(9_999, UInt64.MAX) == 1)
    assert_true(endpoint._timeout_micros_at(10_000, UInt64.MAX) == 0)
    assert_true(endpoint._timeout_micros_at(0, UInt64(5)) == 5)
    assert_true(endpoint._timeout_micros_at(0, UInt64(20)) == 10)


def test_udp_would_block_retains_pacing_due_and_bytes() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var listener = listen_udp("127.0.0.1:0")
    var endpoint = QuicUDPEndpoint(provider.server(config^), listener^)
    var receiver = listen_udp("127.0.0.1:0")
    var payload = Array[Byte, 2](fill=Byte(42))
    endpoint.stage_outgoing_datagram(
        Span(payload), receiver.local_address(), 10_000
    )
    endpoint.inject_send_would_block_once()
    assert_false(endpoint._try_send_at(10_000))
    assert_true(endpoint._pending_send_at == 10_000)
    assert_true(endpoint._pending_length == 2)
    assert_true(endpoint._pending_waiting_write)
    assert_true(endpoint.wants_write())
    assert_true(endpoint._timeout_micros_at(10_000, UInt64.MAX) == UInt64.MAX)
    assert_true(endpoint._try_send_at(10_001))
    assert_true(endpoint._pending_send_at == 0)
    assert_false(endpoint.wants_write())
    var incoming = Array[Byte, 2](fill=0)
    var received = receiver.recv_from(
        Span[mut=True](incoming), Timeout.seconds(1)
    )
    assert_true(received.count == 2)
    assert_true(incoming[0] == Byte(42))
    assert_true(incoming[1] == Byte(42))


def test_pacing_delay_conversion_saturates_monotonic_deadline() raises:
    assert_true(_send_at(UInt64.MAX, 100) == Int.MAX)
    assert_true(_send_at(UInt64(42), 100) == 142)
    assert_true(_send_at(UInt64(0), 100) == 100)


def test_receive_limits_reject_negative_capacities() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    for invalid in range(6):
        var capacities: Array[Int, 6] = [64, 6, 4096, 32, 16384, 64]
        capacities[invalid] = -1
        var rejected = False
        try:
            server.set_receive_limits(
                capacities[0],
                capacities[1],
                capacities[2],
                capacities[3],
                capacities[4],
                capacities[5],
            )
        except:
            rejected = True
        assert_true(rejected)
    server.set_receive_limits(64, 6, 4096, 32, 16384, 64)


def test_send_limits_reject_negative_capacities() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    for invalid in range(6):
        var capacities: Array[Int, 6] = [64, 6, 4096, 32, 16384, 64]
        capacities[invalid] = -1
        var rejected = False
        try:
            server.set_send_limits(
                capacities[0],
                capacities[1],
                capacities[2],
                capacities[3],
                capacities[4],
                capacities[5],
            )
        except:
            rejected = True
        assert_true(rejected)
    server.set_send_limits(0, 0, 0, 0, 0, 0)

    var endpoint = QuicUDPEndpoint(server^, listen_udp("127.0.0.1:0"))
    for invalid in range(6):
        var capacities: Array[Int, 6] = [64, 6, 4096, 32, 16384, 64]
        capacities[invalid] = -1
        var rejected = False
        try:
            endpoint.set_send_limits(
                capacities[0],
                capacities[1],
                capacities[2],
                capacities[3],
                capacities[4],
                capacities[5],
            )
        except:
            rejected = True
        assert_true(rejected)
    endpoint.set_send_limits(0, 0, 0, 0, 0, 0)


def main() raises:
    var provider = QuicProvider("build/quic/libnet_quic_provider")
    assert_true(provider.version() == "0.29.3")
    var config = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var server = provider.server(config^)
    assert_true(server.timeout_micros() == UInt64.MAX)
    var packet = Array[Byte, 256](fill=0)
    _ = server.try_send_datagram(Span[mut=True](packet))
    server.on_timeout()

    var listener = listen_udp("127.0.0.1:0")
    var client_address = String(listener.local_address())
    var endpoint = QuicUDPEndpoint(server^, listener^)
    var reactor = Reactor()
    var token = reactor.register(endpoint.raw_fd())
    var client = dial_udp(client_address)
    var invalid_datagram = Array[Byte, 1](fill=Byte(0))
    _ = client.write(Span(invalid_datagram), Timeout.seconds(1))
    var events = reactor.wait(Timeout.seconds(1))
    assert_true(len(events) == 1)
    assert_true(events[0].token == token)
    assert_false(endpoint.try_receive())
    assert_false(endpoint.try_send())
    assert_false(endpoint.wants_write())

    var http_config = ServerConfig.default()
    http_config.shutdown_grace = Timeout.milliseconds(20)
    var http_server = Server(http_config^)
    var server_listener = listen_udp("127.0.0.1:0")
    var server_address = String(server_listener.local_address())
    var config2 = provider.server_config(
        "build/tls/test-cert.pem", "build/tls/test-key.pem"
    )
    var protocol_server = provider.server(config2^)
    http_server.add_quic_endpoint(
        QuicUDPEndpoint(protocol_server^, server_listener^)
    )
    var udp_client = dial_udp(server_address)
    _ = udp_client.write(Span(invalid_datagram), Timeout.seconds(1))
    var handler = _NoopHandler()
    assert_true(http_server.tick(handler, Timeout.seconds(1)))
    http_server.request_shutdown()
    var running = True
    var shutdown_wait_deadline = Int(perf_counter_ns()) + 1_000_000_000
    while running and Int(perf_counter_ns()) < shutdown_wait_deadline:
        running = http_server.tick(handler, Timeout.milliseconds(5))
    assert_false(running)

    test_receive_limits_reject_negative_capacities()
    test_send_limits_reject_negative_capacities()
    test_pacing_delay_conversion_saturates_monotonic_deadline()
    test_pending_datagram_waits_for_pacing_due_time()
    test_pending_pacing_timer_rounds_up_to_next_microsecond()
    test_udp_would_block_retains_pacing_due_and_bytes()
    test_udp_send_backpressure_preserves_pending_datagram()
    print("QUIC provider Mojo FFI: ok")
