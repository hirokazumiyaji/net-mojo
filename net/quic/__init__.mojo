"""Optional quiche-backed QUIC provider loaded from the HTTP/3 build artifact."""

from std.ffi import OwnedDLHandle, Pointer, c_int, c_size_t
from std.time import perf_counter_ns

from net._sys.common import _copy_c_string
from net.address import SocketAddress
from net.error import NetError, NetErrorKind, _require_handle
from net.timeout import Timeout
from net.udp import UDPConn


struct QuicProvider(Movable):
    var _library_path: String
    var _library: OwnedDLHandle

    def __init__(out self, var library_path: String) raises:
        var library = OwnedDLHandle(library_path)
        self._library_path = library_path^
        self._library = library^

    def version(self) -> String:
        var version = self._library.call[
            "net_quic_version", Pointer[Byte, MutUntrackedOrigin]
        ]()
        return _copy_c_string(version)

    def server_config(
        mut self, var certificate_path: String, var private_key_path: String
    ) raises -> QuicServerConfig:
        var certificate = certificate_path.as_c_string_span()
        var private_key = private_key_path.as_c_string_span()
        var config = _require_handle(
            self._library.call[
                "net_quic_config_new",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](certificate.ptr(), private_key.ptr()),
            "create QUIC server config",
            "quiche could not load the certificate and private key",
        )
        var library = OwnedDLHandle(self._library_path)
        return QuicServerConfig(library^, config)

    def server(mut self, var config: QuicServerConfig) raises -> QuicServer:
        var server = _require_handle(
            config._library.call[
                "net_quic_create",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](config._config),
            "create QUIC server",
            "quiche could not create a server",
        )
        var library = OwnedDLHandle(self._library_path)
        return QuicServer(library^, server)


struct QuicServerConfig(Movable):
    var _library: OwnedDLHandle
    var _config: Pointer[Byte, MutUntrackedOrigin]

    def __init__(
        out self,
        var library: OwnedDLHandle,
        config: Pointer[Byte, MutUntrackedOrigin],
    ):
        self._library = library^
        self._config = config

    def __deinit__(deinit self):
        self._library.call["net_quic_config_free"](self._config)


@fieldwise_init
struct QuicSendDatagramResult(Copyable, Movable):
    var count: Int
    var destination: SocketAddress
    var delay_ns: UInt64


struct QuicServer(Movable):
    var _library: OwnedDLHandle
    var _server: Pointer[Byte, MutUntrackedOrigin]

    def __init__(
        out self,
        var library: OwnedDLHandle,
        server: Pointer[Byte, MutUntrackedOrigin],
    ):
        self._library = library^
        self._server = server

    def __deinit__(deinit self):
        self._library.call["net_quic_free"](self._server)

    def begin_shutdown(mut self) raises NetError:
        _require_ok(
            self._library.call["net_quic_begin_shutdown", c_int](self._server),
            "begin HTTP/3 shutdown",
            "QUIC provider could not begin shutdown",
        )

    def finish_shutdown(mut self) raises NetError:
        _require_ok(
            self._library.call["net_quic_finish_shutdown", c_int](self._server),
            "finish HTTP/3 shutdown",
            "QUIC provider could not finish shutdown",
        )

    def close_connections(mut self) raises NetError:
        _require_ok(
            self._library.call["net_quic_close_connections", c_int](
                self._server
            ),
            "close QUIC connections",
            "QUIC provider could not close connections",
        )

    def shutdown_complete(self) -> Bool:
        return (
            self._library.call["net_quic_shutdown_complete", c_int](
                self._server
            )
            == 1
        )

    def set_connection_limit(mut self, limit: Int) raises NetError:
        _require_ok(
            self._library.call["net_quic_set_connection_limit", c_int](
                self._server, c_size_t(limit)
            ),
            "set QUIC connection limit",
            "QUIC provider could not set the connection limit",
        )

    def set_transport_memory_limit(mut self, limit: Int) raises NetError:
        _require_ok(
            self._library.call["net_quic_set_transport_memory_limit", c_int](
                self._server, c_size_t(limit)
            ),
            "set QUIC transport memory limit",
            "QUIC provider could not set the transport memory limit",
        )

    def set_receive_limits(
        mut self,
        request_bytes: Int,
        request_slots: Int,
        control_bytes: Int,
        control_slots: Int,
        crypto_bytes: Int,
        crypto_slots: Int,
    ) raises NetError:
        if (
            request_bytes < 0
            or request_slots < 0
            or control_bytes < 0
            or control_slots < 0
            or crypto_bytes < 0
            or crypto_slots < 0
        ):
            raise NetError(
                NetErrorKind.invalid_state(),
                "set QUIC receive limits",
                None,
                "receive capacities must be nonnegative",
            )
        _require_ok(
            self._library.call["net_quic_set_receive_limits", c_int](
                self._server,
                c_size_t(request_bytes),
                c_size_t(request_slots),
                c_size_t(control_bytes),
                c_size_t(control_slots),
                c_size_t(crypto_bytes),
                c_size_t(crypto_slots),
            ),
            "set QUIC receive limits",
            "receive limits cannot change after accepting a connection",
        )

    def set_send_limits(
        mut self,
        request_bytes: Int,
        request_slots: Int,
        control_bytes: Int,
        control_slots: Int,
        crypto_bytes: Int,
        crypto_slots: Int,
    ) raises NetError:
        if (
            request_bytes < 0
            or request_slots < 0
            or control_bytes < 0
            or control_slots < 0
            or crypto_bytes < 0
            or crypto_slots < 0
        ):
            raise NetError(
                NetErrorKind.invalid_state(),
                "set QUIC send limits",
                None,
                "send capacities must be nonnegative",
            )
        _require_ok(
            self._library.call["net_quic_set_send_limits", c_int](
                self._server,
                c_size_t(request_bytes),
                c_size_t(request_slots),
                c_size_t(control_bytes),
                c_size_t(control_slots),
                c_size_t(crypto_bytes),
                c_size_t(crypto_slots),
            ),
            "set QUIC send limits",
            "send limits cannot change after accepting a connection",
        )

    def transport_memory_bytes(self) -> Int:
        return Int(
            self._library.call["net_quic_transport_memory_bytes", c_size_t](
                self._server
            )
        )

    def set_request_limits(
        mut self,
        max_body_bytes: Int,
        max_headers_bytes: Int,
        max_headers_count: Int,
        max_trailer_bytes: Int = 8192,
        max_trailer_count: Int = 32,
    ) raises NetError:
        _require_ok(
            self._library.call["net_quic_set_request_limits", c_int](
                self._server,
                c_size_t(max_body_bytes),
                c_size_t(max_headers_bytes),
                c_size_t(max_headers_count),
                c_size_t(max_trailer_bytes),
                c_size_t(max_trailer_count),
            ),
            "set QUIC request limits",
            "QUIC provider could not set request limits",
        )

    def set_response_limits(
        mut self,
        max_body_bytes: Int,
        max_headers_bytes: Int,
        max_headers_count: Int,
    ) raises NetError:
        _require_ok(
            self._library.call["net_quic_set_response_limits", c_int](
                self._server,
                c_size_t(max_body_bytes),
                c_size_t(max_headers_bytes),
                c_size_t(max_headers_count),
            ),
            "set QUIC response limits",
            "QUIC provider could not set response limits",
        )

    def set_stream_deadlines(
        mut self,
        header_deadline: Timeout,
        body_deadline: Timeout,
        idle_timeout: Timeout,
        write_deadline: Timeout = Timeout.nanoseconds(30_000_000_000),
    ) raises NetError:
        _require_ok(
            self._library.call["net_quic_set_stream_deadlines", c_int](
                self._server,
                header_deadline._value,
                body_deadline._value,
                idle_timeout._value,
                write_deadline._value,
            ),
            "set QUIC stream deadlines",
            "QUIC provider could not set stream deadlines",
        )

    def recv_datagram[
        origin: MutOrigin
    ](
        mut self,
        packet: Span[mut=True, Byte, origin],
        local_address: SocketAddress,
        remote_address: SocketAddress,
    ) raises NetError -> Bool:
        var local = String(local_address)
        var remote = String(remote_address)
        var local_c = local.as_c_string_span()
        var remote_c = remote.as_c_string_span()
        var result = self._library.call["net_quic_receive", c_int](
            self._server,
            packet.unsafe_ptr(),
            c_size_t(len(packet)),
            local_c.ptr(),
            remote_c.ptr(),
        )
        if result < 0:
            raise NetError(
                NetErrorKind.system_error(),
                "receive QUIC datagram",
                None,
                "quiche rejected the datagram",
            )
        return result == 1

    def try_send_datagram[
        origin: MutOrigin
    ](
        mut self, packet: Span[mut=True, Byte, origin]
    ) raises NetError -> Optional[QuicSendDatagramResult]:
        var destination = Array[Byte, 64](fill=0)
        var destination_ptr = Pointer(to=destination).unsafe_bitcast[Byte]()
        var send_delay_ns = UInt64(0)
        var result = self._library.call["net_quic_send", c_int](
            self._server,
            packet.unsafe_ptr(),
            c_size_t(len(packet)),
            destination_ptr,
            c_size_t(len(destination)),
            Pointer(to=send_delay_ns),
        )
        if result < 0:
            raise NetError(
                NetErrorKind.system_error(),
                "send QUIC datagram",
                None,
                "quiche could not produce a datagram",
            )
        if result == 0:
            return None
        return QuicSendDatagramResult(
            count=Int(result),
            destination=SocketAddress.parse(_copy_c_string(destination_ptr)),
            delay_ns=send_delay_ns,
        )

    def timeout_micros(self) -> UInt64:
        return UInt64(
            self._library.call["net_quic_timeout_micros", c_size_t](
                self._server
            )
        )

    def on_timeout(mut self):
        self._library.call["net_quic_on_timeout"](self._server)

    def next_request[
        origin: MutOrigin
    ](mut self, output: Span[mut=True, Byte, origin]) raises NetError -> Int:
        return Int(
            self._library.call["net_quic_next_request", c_int](
                self._server,
                output.unsafe_ptr(),
                c_size_t(len(output)),
            )
        )

    def respond[
        headers_origin: Origin, body_origin: Origin, trailers_origin: Origin
    ](
        mut self,
        request_id: UInt64,
        status: Int,
        headers: Span[Byte, headers_origin],
        body: Span[Byte, body_origin],
        trailers: Span[Byte, trailers_origin],
    ) raises NetError:
        _require_ok(
            self._library.call["net_quic_respond", c_int](
                self._server,
                request_id,
                UInt32(status),
                headers.unsafe_ptr(),
                c_size_t(len(headers)),
                body.unsafe_ptr(),
                c_size_t(len(body)),
                trailers.unsafe_ptr(),
                c_size_t(len(trailers)),
            ),
            "send HTTP/3 response",
            "QUIC provider could not queue the response",
        )


@fieldwise_init
struct QuicRequestHeader(Movable):
    var name: String
    var value: List[Byte]


@fieldwise_init
struct QuicRequest(Movable):
    var id: UInt64
    var stream_id: UInt64
    var method: String
    var target: String
    var scheme: String
    var authority: String
    var headers: List[QuicRequestHeader]
    var trailers: List[QuicRequestHeader]
    var body: List[Byte]

    def take_body(mut self) -> List[Byte]:
        var body = self.body^
        self.body = List[Byte]()
        return body^


struct QuicUDPEndpoint(Movable):
    var _server: QuicServer
    var _socket: UDPConn
    var _receive_buffer: List[Byte]
    var _send_buffer: List[Byte]
    var _request_buffer: List[Byte]
    var _pending_send_at: Int
    var _pending_waiting_write: Bool
    var _pending_length: Int
    var _pending_destination: Optional[SocketAddress]
    var _send_would_block_once: Bool

    def set_connection_limit(mut self, limit: Int) raises NetError:
        self._server.set_connection_limit(limit)

    def set_transport_memory_limit(mut self, limit: Int) raises NetError:
        self._server.set_transport_memory_limit(limit)

    def set_receive_limits(
        mut self,
        request_bytes: Int,
        request_slots: Int,
        control_bytes: Int,
        control_slots: Int,
        crypto_bytes: Int,
        crypto_slots: Int,
    ) raises NetError:
        self._server.set_receive_limits(
            request_bytes,
            request_slots,
            control_bytes,
            control_slots,
            crypto_bytes,
            crypto_slots,
        )

    def set_send_limits(
        mut self,
        request_bytes: Int,
        request_slots: Int,
        control_bytes: Int,
        control_slots: Int,
        crypto_bytes: Int,
        crypto_slots: Int,
    ) raises NetError:
        self._server.set_send_limits(
            request_bytes,
            request_slots,
            control_bytes,
            control_slots,
            crypto_bytes,
            crypto_slots,
        )

    def transport_memory_bytes(self) -> Int:
        return self._server.transport_memory_bytes()

    def set_request_limits(
        mut self,
        max_body_bytes: Int,
        max_headers_bytes: Int,
        max_headers_count: Int,
        max_trailer_bytes: Int = 8192,
        max_trailer_count: Int = 32,
    ) raises NetError:
        self._server.set_request_limits(
            max_body_bytes,
            max_headers_bytes,
            max_headers_count,
            max_trailer_bytes,
            max_trailer_count,
        )
        self._ensure_request_buffer(
            max_body_bytes, max_headers_bytes, max_headers_count
        )

    def set_response_limits(
        mut self,
        max_body_bytes: Int,
        max_headers_bytes: Int,
        max_headers_count: Int,
    ) raises NetError:
        self._server.set_response_limits(
            max_body_bytes, max_headers_bytes, max_headers_count
        )

    def set_stream_deadlines(
        mut self,
        header_deadline: Timeout,
        body_deadline: Timeout,
        idle_timeout: Timeout,
        write_deadline: Timeout = Timeout.nanoseconds(30_000_000_000),
    ) raises NetError:
        self._server.set_stream_deadlines(
            header_deadline, body_deadline, idle_timeout, write_deadline
        )

    def begin_shutdown(mut self) raises NetError:
        self._server.begin_shutdown()

    def finish_shutdown(mut self) raises NetError:
        self._server.finish_shutdown()

    def close_connections(mut self) raises NetError:
        self._server.close_connections()

    def shutdown_complete(self) -> Bool:
        return self._server.shutdown_complete()

    def __init__(out self, var server: QuicServer, var socket: UDPConn):
        self._server = server^
        self._socket = socket^
        self._receive_buffer = List[Byte](length=65535, fill=0)
        self._send_buffer = List[Byte](length=65535, fill=0)
        self._request_buffer = List[Byte](length=1_200_000, fill=0)
        self._pending_send_at = 0
        self._pending_waiting_write = False
        self._pending_length = 0
        self._pending_destination = None
        self._send_would_block_once = False

    def raw_fd(self) raises NetError -> Int32:
        return self._socket.raw_fd()

    def try_receive(mut self) raises NetError -> Bool:
        try:
            var received = self._socket.try_recv_from(
                Span[mut=True](self._receive_buffer)
            )
            if received.truncated:
                return False
            return self._server.recv_datagram(
                Span[mut=True](self._receive_buffer)[0 : received.count],
                self._socket.local_address(),
                received.source,
            )
        except error:
            if error.kind == NetErrorKind.timeout():
                return False
            raise error^

    def try_send(mut self) raises NetError -> Bool:
        if self._pending_length == 0:
            var packet = self._server.try_send_datagram(
                Span[mut=True](self._send_buffer)
            )
            if not packet:
                return False
            self._pending_length = packet.value().count
            self._pending_destination = Optional(
                packet.value().destination.copy()
            )
            self._pending_send_at = _send_at(
                packet.value().delay_ns, Int(perf_counter_ns())
            )
            self._pending_waiting_write = False
        return self._try_send_at(Int(perf_counter_ns()))

    def _try_send_at(mut self, now: Int) raises NetError -> Bool:
        if now < self._pending_send_at:
            return False
        try:
            if self._send_would_block_once:
                self._send_would_block_once = False
                raise NetError(
                    NetErrorKind.timeout(),
                    "send QUIC datagram",
                    None,
                    "injected send would-block for test",
                )
            var written = self._socket.try_send_to(
                Span(self._send_buffer)[0 : self._pending_length],
                self._pending_destination.value(),
            )
            if written != self._pending_length:
                raise NetError(
                    NetErrorKind.invalid_state(),
                    "send QUIC datagram",
                    None,
                    "UDP socket wrote a partial datagram",
                )
            self._pending_length = 0
            self._pending_destination = None
            self._pending_send_at = 0
            self._pending_waiting_write = False
            return True
        except error:
            if error.kind == NetErrorKind.timeout():
                self._pending_waiting_write = True
                return False
            raise error^

    def _timeout_micros_at(self, now: Int, transport_timeout: UInt64) -> UInt64:
        if self._pending_length > 0 and not self._pending_waiting_write:
            var remaining = self._pending_send_at - now
            var pacing_timeout = UInt64(0)
            if remaining > 0:
                pacing_timeout = UInt64((remaining - 1) // 1000) + 1
            if pacing_timeout < transport_timeout:
                return pacing_timeout
        return transport_timeout

    def wants_write(self) -> Bool:
        return (
            self._pending_length > 0
            and Int(perf_counter_ns()) >= self._pending_send_at
        )

    def inject_send_would_block_once(mut self):
        """Fail the next `try_send` with would-block, preserving pending.

        Deterministic alternative to filling the kernel UDP send queue
        (which depends on host routing for TEST-NET and on drain timing).
        """
        self._send_would_block_once = True

    def stage_outgoing_datagram[
        origin: Origin
    ](
        mut self,
        packet: Span[Byte, origin],
        destination: SocketAddress,
        send_at: Int = 0,
    ) raises NetError:
        """Retain `packet` as the current pending UDP send.

        Test hook for send-path backpressure: stages bytes the same way
        `try_send` does after `try_send_datagram` returns a packet.
        """
        if len(packet) == 0 or len(packet) > len(self._send_buffer):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "stage QUIC datagram",
                None,
                "pending datagram length is out of range",
            )
        for i in range(len(packet)):
            self._send_buffer[i] = packet[i]
        self._pending_send_at = send_at
        self._pending_waiting_write = False
        self._pending_length = len(packet)
        self._pending_destination = Optional(destination.copy())

    def transport_timeout_micros(self) -> UInt64:
        return self._server.timeout_micros()

    def timeout_micros(self) -> UInt64:
        return self._timeout_micros_at(
            Int(perf_counter_ns()), self.transport_timeout_micros()
        )

    def on_timeout(mut self):
        self._server.on_timeout()

    def try_next_request(mut self) raises NetError -> QuicRequest:
        var length = self._server.next_request(
            Span[mut=True](self._request_buffer)
        )
        if length < 0:
            var needed = -length
            if needed > len(self._request_buffer):
                self._request_buffer = List[Byte](length=needed, fill=0)
                length = self._server.next_request(
                    Span[mut=True](self._request_buffer)
                )
        if length == 0:
            return QuicRequest(
                id=0,
                stream_id=0,
                method=String(),
                target=String(),
                scheme=String(),
                authority=String(),
                headers=List[QuicRequestHeader](),
                trailers=List[QuicRequestHeader](),
                body=List[Byte](),
            )
        if length < 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "receive HTTP/3 request",
                None,
                "HTTP/3 request record exceeds the configured buffer",
            )
        return _decode_request_record(Span(self._request_buffer)[0:length])

    def _ensure_request_buffer(
        mut self,
        max_body_bytes: Int,
        max_headers_bytes: Int,
        max_headers_count: Int,
    ):
        # ids + routing fields + header/trailer length prefixes + body
        var capacity = (
            64
            + 16384
            + max_headers_bytes
            + max_headers_count * 8
            + 8192
            + 32 * 8
            + max_body_bytes
        )
        if capacity < 1_200_000:
            capacity = 1_200_000
        if capacity > len(self._request_buffer):
            self._request_buffer = List[Byte](length=capacity, fill=0)

    def respond[
        headers_origin: Origin, body_origin: Origin, trailers_origin: Origin
    ](
        mut self,
        request_id: UInt64,
        status: Int,
        headers: Span[Byte, headers_origin],
        body: Span[Byte, body_origin],
        trailers: Span[Byte, trailers_origin],
    ) raises NetError:
        self._server.respond(request_id, status, headers, body, trailers)


def _read_request_u32[
    origin: Origin
](data: Span[Byte, origin], mut offset: Int) -> UInt32:
    var value = UInt32(0)
    for _ in range(4):
        value = (value << 8) | UInt32(data[offset])
        offset += 1
    return value


def _read_request_u64[
    origin: Origin
](data: Span[Byte, origin], mut offset: Int) -> UInt64:
    var value = UInt64(0)
    for _ in range(8):
        value = (value << 8) | UInt64(data[offset])
        offset += 1
    return value


def _read_request_bytes[
    origin: Origin
](data: Span[Byte, origin], mut offset: Int) -> List[Byte]:
    var length = Int(_read_request_u32(data, offset))
    var value = List[Byte](data[offset : offset + length])
    offset += length
    return value^


def _decode_request_record[
    origin: Origin
](data: Span[Byte, origin]) -> QuicRequest:
    var offset = 0
    var id = _read_request_u64(data, offset)
    var stream_id = _read_request_u64(data, offset)
    var method = String(from_utf8_lossy=Span(_read_request_bytes(data, offset)))
    var target = String(from_utf8_lossy=Span(_read_request_bytes(data, offset)))
    var scheme = String(from_utf8_lossy=Span(_read_request_bytes(data, offset)))
    var authority = String(
        from_utf8_lossy=Span(_read_request_bytes(data, offset))
    )
    var header_count = Int(_read_request_u32(data, offset))
    var headers = List[QuicRequestHeader]()
    for _ in range(header_count):
        var name = String(
            from_utf8_lossy=Span(_read_request_bytes(data, offset))
        )
        var value = _read_request_bytes(data, offset)
        headers.append(QuicRequestHeader(name=name^, value=value^))
    var trailer_count = Int(_read_request_u32(data, offset))
    var trailers = List[QuicRequestHeader]()
    for _ in range(trailer_count):
        var name = String(
            from_utf8_lossy=Span(_read_request_bytes(data, offset))
        )
        var value = _read_request_bytes(data, offset)
        trailers.append(QuicRequestHeader(name=name^, value=value^))
    var body = _read_request_bytes(data, offset)
    return QuicRequest(
        id=id,
        stream_id=stream_id,
        method=method^,
        target=target^,
        scheme=scheme^,
        authority=authority^,
        headers=headers^,
        trailers=trailers^,
        body=body^,
    )


def _require_ok(
    result: c_int, operation: StaticString, message: StaticString
) raises NetError:
    if result != 1:
        raise NetError(
            NetErrorKind.invalid_state(),
            String(operation),
            None,
            String(message),
        )


def _send_at(delay_ns: UInt64, now: Int) -> Int:
    if delay_ns > UInt64(Int.MAX - now):
        return Int.MAX
    return now + Int(delay_ns)
