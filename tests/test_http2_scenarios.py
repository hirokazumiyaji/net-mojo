#!/usr/bin/env python3
"""HTTP/2 scenario upload progress against an in-memory hyper-h2 peer."""

import importlib.util
from pathlib import Path
import socket
import time
import unittest

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, RequestReceived, StreamEnded


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "http2_scenarios", ROOT / "benchmarks/http/http2_scenarios.py"
)
scenarios = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scenarios)


class InMemoryH2Socket:
    def __init__(self):
        self.server = H2Connection(config=H2Configuration(client_side=False))
        self.server.initiate_connection()
        self.events = []
        self.bodies = {}
        self.ended = set()
        self.credit_idle_polls = 0

    def sendall(self, data):
        self.events.append("send")
        for event in self.server.receive_data(data):
            if isinstance(event, RequestReceived):
                self.bodies[event.stream_id] = bytearray()
            elif isinstance(event, DataReceived):
                self.bodies[event.stream_id].extend(event.data)
                self.server.acknowledge_received_data(
                    event.flow_controlled_length, event.stream_id
                )
            elif isinstance(event, StreamEnded):
                self.ended.add(event.stream_id)

    def settimeout(self, timeout):
        pass

    def recv(self, size):
        self.events.append("recv")
        data = self.server.data_to_send(size)
        if data:
            return data
        for stream_id in self.bodies:
            if stream_id not in self.ended and (
                self.client._conn.local_flow_control_window(stream_id) >= 16384
            ):
                self.credit_idle_polls += 1
        raise socket.timeout()


class Http2ScenarioUploadTests(unittest.TestCase):
    def setUp(self):
        self.socket = InMemoryH2Socket()
        self.client = scenarios.H2ScenarioClient(self.socket, b"localhost")
        self.socket.client = self.client
        self.client.pump(time.perf_counter() + 1)
        self.socket.events.clear()

    def upload(self):
        body = b"x" * 100_000
        stream_id = self.client.post_echo(body, time.perf_counter() + 1)
        self.assertEqual(bytes(self.socket.bodies[stream_id]), body)
        self.assertIn(stream_id, self.socket.ended)

    def test_transmits_queued_data_before_waiting_for_upload_credit(self):
        self.upload()
        self.assertEqual(self.socket.events[0], "send")

    def test_resumes_upload_without_idle_poll_after_credit_is_restored(self):
        self.upload()
        self.assertEqual(self.socket.credit_idle_polls, 0)

    def test_normal_pump_drains_available_frames_until_peer_is_idle(self):
        self.socket.server.ping(b"drainh2!")
        self.client.pump(time.perf_counter() + 1)
        self.assertEqual(self.socket.events, ["recv", "send", "recv"])


if __name__ == "__main__":
    unittest.main()
