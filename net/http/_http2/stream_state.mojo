"""Socket-independent HTTP/2 stream half-close tracking."""


struct Http2StreamState(Movable):
    var remote_headers_received: Bool
    var remote_trailers_received: Bool
    var remote_closed: Bool
    var local_headers_sent: Bool
    var local_closed: Bool
    var reset_done: Bool

    def __init__(out self):
        self.remote_headers_received = False
        self.remote_trailers_received = False
        self.remote_closed = False
        self.local_headers_sent = False
        self.local_closed = False
        self.reset_done = False

    def receive_headers(mut self, end_stream: Bool) -> Bool:
        if self.reset_done or self.remote_closed:
            return False

        if self.remote_headers_received:
            if self.remote_trailers_received or not end_stream:
                return False
            self.remote_trailers_received = True
        else:
            self.remote_headers_received = True

        if end_stream:
            self.remote_closed = True
        return True

    def receive_data(mut self, end_stream: Bool) -> Bool:
        if (
            self.reset_done
            or not self.remote_headers_received
            or self.remote_closed
        ):
            return False
        if end_stream:
            self.remote_closed = True
        return True

    def send_headers(mut self, end_stream: Bool) -> Bool:
        if (
            self.reset_done
            or not self.remote_headers_received
            or self.local_closed
        ):
            return False
        self.local_headers_sent = True
        if end_stream:
            self.local_closed = True
        return True

    def send_data(mut self, end_stream: Bool) -> Bool:
        if self.reset_done or not self.local_headers_sent or self.local_closed:
            return False
        if end_stream:
            self.local_closed = True
        return True

    def reset(mut self) -> Bool:
        if (
            not self.remote_headers_received
            or self.reset_done
            or self.is_closed()
        ):
            return False
        self.reset_done = True
        return True

    def is_remote_closed(self) -> Bool:
        return self.remote_closed

    def is_local_closed(self) -> Bool:
        return self.local_closed

    def is_closed(self) -> Bool:
        return self.reset_done or (self.remote_closed and self.local_closed)
