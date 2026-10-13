"""Budgets and policy for the synchronous HTTP/1.1 client."""

from net.timeout import Timeout
from .client_error import ClientError


@fieldwise_init
struct RedirectPolicy(Copyable, Movable):
    var max_hops: Int
    var follow: Bool

    @staticmethod
    def follow_default() -> Self:
        return Self(10, True)

    @staticmethod
    def never() -> Self:
        return Self(0, False)


@fieldwise_init
struct ClientTLSConfig(Copyable, Movable):
    var library_path: String
    var ca_bundle_path: Optional[String]
    var alpn: String
    var insecure_skip_verify: Bool
    var sni_override: Optional[String]

    @staticmethod
    def default() -> Self:
        return Self("build/tls/libnet_tls", None, "http/1.1", False, None)


@fieldwise_init
struct ClientConfig(Copyable, Movable):
    var connect_timeout: Timeout
    var request_timeout: Timeout
    var response_header_timeout: Timeout
    var idle_conn_timeout: Timeout
    var max_idle_conns_per_host: Int
    var max_conns_per_host: Int
    var max_response_headers_bytes: Int
    var max_response_headers_count: Int
    var max_response_body: Int
    var max_chunk_metadata: Int
    var max_trailer_bytes: Int
    var max_trailer_count: Int
    var user_agent: String
    var redirect: RedirectPolicy
    var tls: Optional[ClientTLSConfig]

    @staticmethod
    def default() raises ClientError -> Self:
        var connect: Timeout
        var request: Timeout
        var header: Timeout
        var idle: Timeout
        try:
            connect = Timeout.seconds(5)
            request = Timeout.seconds(30)
            header = Timeout.seconds(5)
            idle = Timeout.seconds(60)
        except error:
            raise ClientError(
                ClientError.PARSE, "invalid client timeout", error^
            )
        return Self(
            connect^,
            request^,
            header^,
            idle^,
            2,
            32,
            32768,
            100,
            1048576,
            65536,
            8192,
            32,
            "",
            RedirectPolicy.follow_default(),
            None,
        )

    def _validate(self) raises ClientError:
        if (
            self.max_conns_per_host < 1
            or self.max_idle_conns_per_host < 0
            or self.max_response_headers_bytes < 1
            or self.max_response_headers_count < 1
            or self.max_response_body < 0
            or self.max_chunk_metadata < 1
            or self.max_trailer_bytes < 1
            or self.max_trailer_count < 0
            or self.redirect.max_hops < 0
        ):
            raise ClientError.parse("invalid client resource bounds")
        if self.tls:
            if self.tls.value().alpn != "http/1.1":
                raise ClientError.parse(
                    "the client only supports HTTP/1.1 ALPN"
                )
