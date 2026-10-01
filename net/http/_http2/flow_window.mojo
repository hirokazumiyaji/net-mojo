"""HTTP/2 stream or connection flow-control windows."""


struct Http2FlowWindow(Movable):
    var _initial_send_window: Int
    var _send_window: Int
    var _receive_window: Int
    var _pending_receive_credit: Int

    def __init__(
        out self, initial_send_window: Int, initial_receive_window: Int
    ):
        self._initial_send_window = initial_send_window
        self._send_window = initial_send_window
        self._receive_window = initial_receive_window
        self._pending_receive_credit = 0

    def consume_outbound(mut self, amount: Int) -> Bool:
        if amount < 0 or amount > self._send_window:
            return False
        self._send_window -= amount
        return True

    def apply_window_update(mut self, increment: Int) -> Bool:
        if increment <= 0 or increment > 0x7FFFFFFF:
            return False
        if increment > 0x7FFFFFFF - self._send_window:
            return False
        self._send_window += increment
        return True

    def receive_data(mut self, flow_bytes: Int) -> Bool:
        if flow_bytes < 0 or flow_bytes > self._receive_window:
            return False
        self._receive_window -= flow_bytes
        self._pending_receive_credit += flow_bytes
        return True

    def release_received(mut self, amount: Int) -> Bool:
        if amount < 0 or amount > self._pending_receive_credit:
            return False
        if amount > 0x7FFFFFFF - self._receive_window:
            return False
        self._pending_receive_credit -= amount
        self._receive_window += amount
        return True

    def update_initial_send_window(mut self, value: Int) -> Bool:
        if value < 0 or value > 0x7FFFFFFF:
            return False
        var delta = value - self._initial_send_window
        if delta > 0 and self._send_window > 0x7FFFFFFF - delta:
            return False
        self._send_window += delta
        self._initial_send_window = value
        return True

    def send_window(self) -> Int:
        return self._send_window

    def receive_window(self) -> Int:
        return self._receive_window

    def pending_receive_credit(self) -> Int:
        return self._pending_receive_credit
