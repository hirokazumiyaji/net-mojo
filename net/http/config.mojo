"""Server-wide resource bounds and deadlines.

Every value is enforced and recorded in benchmark reports. Deadlines
are absolute monotonic times derived once per phase; receiving one
more byte never extends them.
"""

from net import Timeout


@fieldwise_init
struct ServerConfig(Copyable, Movable):
    var max_connections: Int
    var max_http2_streams_per_connection: Int
    # Tumbling 1s window; non-ACK PING/SETTINGS, WINDOW_UPDATE, PRIORITY.
    var http2_max_control_frames_per_second: Int
    # Tumbling 1s window for RST_STREAM; separate from control-frame budget.
    var http2_max_resets_per_second: Int
    var max_request_line: Int
    var max_headers_bytes: Int
    var max_headers_count: Int
    var max_body_bytes: Int
    var max_chunk_metadata: Int
    var max_trailer_bytes: Int
    var max_trailer_count: Int
    var max_response_body: Int
    var max_response_headers_bytes: Int
    var max_response_headers_count: Int
    var total_buffer_budget: Int
    var header_deadline: Timeout
    var body_deadline: Timeout
    var write_deadline: Timeout
    var tls_handshake_timeout: Timeout
    var idle_timeout: Timeout
    var shutdown_grace: Timeout
    var detached_response_timeout: Timeout
    var stream_queue_limit: Int
    var stream_idle_timeout: Timeout
    var max_accept_per_tick: Int
    var max_bytes_per_tick: Int
    var max_requests_per_tick: Int
    var hpack_library_path: String
    # Opt-in HTTPS Alt-Svc advertisement (empty disables). Set the full
    # header value, e.g. `h3=":443"; ma=86400`, when a QUIC/HTTP/3 endpoint
    # is attached on the same origin. UDP-unavailable deployments leave
    # this empty and continue serving HTTPS without advertising H3.
    var alt_svc: String

    @staticmethod
    def default() raises -> Self:
        return Self(
            max_connections=10000,
            max_http2_streams_per_connection=100,
            http2_max_control_frames_per_second=1000,
            http2_max_resets_per_second=100,
            max_request_line=8192,
            max_headers_bytes=32768,
            max_headers_count=100,
            max_body_bytes=1048576,
            max_chunk_metadata=65536,
            max_trailer_bytes=8192,
            max_trailer_count=32,
            max_response_body=1048576,
            max_response_headers_bytes=32768,
            max_response_headers_count=100,
            total_buffer_budget=268435456,
            header_deadline=Timeout.seconds(5),
            body_deadline=Timeout.seconds(30),
            write_deadline=Timeout.seconds(30),
            tls_handshake_timeout=Timeout.seconds(10),
            idle_timeout=Timeout.seconds(60),
            shutdown_grace=Timeout.seconds(30),
            detached_response_timeout=Timeout.seconds(30),
            stream_queue_limit=1048576,
            stream_idle_timeout=Timeout.seconds(300),
            max_accept_per_tick=64,
            max_bytes_per_tick=65536,
            max_requests_per_tick=16,
            hpack_library_path=String("build/http2/libnet_hpack"),
            alt_svc=String(""),
        )
