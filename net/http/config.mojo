"""Server-wide resource bounds and deadlines.

Every value is enforced and recorded in benchmark reports. Deadlines
are absolute monotonic times derived once per phase; receiving one
more byte never extends them.
"""

from net import Timeout


@fieldwise_init
struct ServerConfig(Copyable, Movable):
    var max_connections: Int
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
    var idle_timeout: Timeout
    var shutdown_grace: Timeout
    var detached_response_timeout: Timeout
    var max_accept_per_tick: Int
    var max_bytes_per_tick: Int
    var max_requests_per_tick: Int

    @staticmethod
    def default() raises -> Self:
        return Self(
            max_connections=10000,
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
            idle_timeout=Timeout.seconds(60),
            shutdown_grace=Timeout.seconds(30),
            detached_response_timeout=Timeout.seconds(30),
            max_accept_per_tick=64,
            max_bytes_per_tick=65536,
            max_requests_per_tick=16,
        )
