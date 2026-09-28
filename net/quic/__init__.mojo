"""Optional quiche-backed QUIC provider loaded from the HTTP/3 build artifact."""

from std.ffi import OwnedDLHandle, Pointer

from net.error import NetError, NetErrorKind


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
        var config = self._library.call[
            "net_quic_config_new",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](certificate.ptr(), private_key.ptr())
        if config == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create QUIC server config",
                None,
                "quiche could not load the certificate and private key",
            )
        var library = OwnedDLHandle(self._library_path)
        return QuicServerConfig(library^, config.value())


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


def _copy_c_string(address: Pointer[Byte, MutUntrackedOrigin]) -> String:
    var length = 0
    while address[unsafe_offset=length] != 0:
        length += 1
    var bytes = List[Byte]()
    for i in range(length):
        bytes.append(address[unsafe_offset=i])
    return String(from_utf8_lossy=Span(bytes))
