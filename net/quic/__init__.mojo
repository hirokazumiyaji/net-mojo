"""Optional quiche-backed QUIC provider loaded from the HTTP/3 build artifact."""

from std.ffi import OwnedDLHandle, Pointer, c_int, c_size_t

from net.address import SocketAddress
from net.error import NetError, NetErrorKind
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
        var certificate = certificate_path.as_c_string_slice()
        var private_key = private_key_path.as_c_string_slice()
        var config = self._library.call[
            "net_quic_config_new",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](certificate.unsafe_ptr(), private_key.unsafe_ptr())
        if config == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create QUIC server config",
                None,
                "quiche could not load the certificate and private key",
            )
        var library = OwnedDLHandle(self._library_path)
        return QuicServerConfig(library^, config.value())

    def server(
        mut self, var config: QuicServerConfig
    ) raises -> QuicServer:
        var server = config._library.call[
            "net_quic_create",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](config._config)
        if server == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create QUIC server",
                None,
                "quiche could not create a server",
            )
        var library = OwnedDLHandle(self._library_path)
        return QuicServer(library^, server.value())


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

    def set_connection_limit(mut self, limit: Int) raises NetError:
        var result = self._library.call["net_quic_set_connection_limit", c_int](
            self._server, c_size_t(limit)
        )
        if result != 1:
            raise NetError(
                NetErrorKind.invalid_state(),
                "set QUIC connection limit",
                None,
                "QUIC provider could not set the connection limit",
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
        var local_c = local.as_c_string_slice()
        var remote_c = remote.as_c_string_slice()
        var result = self._library.call["net_quic_receive", c_int](
            self._server,
            packet.unsafe_ptr(),
            c_size_t(len(packet)),
            local_c.unsafe_ptr(),
            remote_c.unsafe_ptr(),
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
        var result = self._library.call["net_quic_send", c_int](
            self._server,
            packet.unsafe_ptr(),
            c_size_t(len(packet)),
            destination_ptr,
            c_size_t(len(destination)),
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
        headers_origin: Origin, body_origin: Origin
    ](
        mut self,
        request_id: UInt64,
        status: Int,
        headers: Span[Byte, headers_origin],
        body: Span[Byte, body_origin],
    ) raises NetError:
        var result = self._library.call["net_quic_respond", c_int](
            self._server,
            request_id,
            UInt32(status),
            headers.unsafe_ptr(),
            c_size_t(len(headers)),
            body.unsafe_ptr(),
            c_size_t(len(body)),
        )
        if result != 1:
            raise NetError(
                NetErrorKind.invalid_state(),
                "send HTTP/3 response",
                None,
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
    var _pending_length: Int
    var _pending_destination: Optional[SocketAddress]

    def set_connection_limit(mut self, limit: Int) raises NetError:
        self._server.set_connection_limit(limit)

    def __init__(
        out self, var server: QuicServer, var socket: UDPConn
    ):
        self._server = server^
        self._socket = socket^
        self._receive_buffer = List[Byte](length=65535, fill=0)
        self._send_buffer = List[Byte](length=65535, fill=0)
        self._request_buffer = List[Byte](length=1_200_000, fill=0)
        self._pending_length = 0
        self._pending_destination = None

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

        try:
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
            return True
        except error:
            if error.kind == NetErrorKind.timeout():
                return False
            raise error^

    def wants_write(self) -> Bool:
        return self._pending_length > 0

    def timeout_micros(self) -> UInt64:
        return self._server.timeout_micros()

    def on_timeout(mut self):
        self._server.on_timeout()

    def try_next_request(mut self) raises NetError -> QuicRequest:
        var length = self._server.next_request(
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
        return _decode_request_record(
            Span(self._request_buffer)[0:length]
        )

    def respond[
        headers_origin: Origin, body_origin: Origin
    ](
        mut self,
        request_id: UInt64,
        status: Int,
        headers: Span[Byte, headers_origin],
        body: Span[Byte, body_origin],
    ) raises NetError:
        self._server.respond(request_id, status, headers, body)


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
    var value = List[Byte]()
    value.reserve(length)
    for i in range(length):
        value.append(data[offset + i])
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
        var name = String(from_utf8_lossy=Span(_read_request_bytes(data, offset)))
        var value = _read_request_bytes(data, offset)
        headers.append(QuicRequestHeader(name=name^, value=value^))
    var trailer_count = Int(_read_request_u32(data, offset))
    var trailers = List[QuicRequestHeader]()
    for _ in range(trailer_count):
        var name = String(from_utf8_lossy=Span(_read_request_bytes(data, offset)))
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


def _copy_c_string[origin: MutOrigin](address: Pointer[Byte, origin]) -> String:
    var length = 0
    while address[unsafe_offset=length] != 0:
        length += 1
    var bytes = List[Byte]()
    for i in range(length):
        bytes.append(address[unsafe_offset=i])
    return String(from_utf8_lossy=Span(bytes))
