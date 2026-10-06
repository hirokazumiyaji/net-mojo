import asyncio
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "benchmarks/http"))

from sibling_metrics import begin_sibling_window, sibling_metrics


def valid(record):
    return record.get("status") == b"200" and bytes(record.get("body", b"")) == b"x"


def response(start, done, status=b"200", body=b"x"):
    return {"start": start, "done_at": done, "status": status, "body": body}


class SiblingMetricsTests(unittest.TestCase):
    def test_success_window_excludes_known_idle_poll_and_uses_floor_ranks(self):
        records = [response(1.4, 1.8), response(2.0, 2.1),
                   response(2.0, 2.3), response(2.8, 3.0)]
        stats = sibling_metrics(records, valid, (1.0, 1700000000.0, 0.002), 9.0)
        self.assertEqual(stats["sibling_samples"], 4)
        self.assertEqual(stats["sibling_completed"], 4)
        self.assertEqual(stats["sibling_missing_timing"], 0)
        self.assertEqual(stats["sibling_window_scope"], "all_completed")
        self.assertEqual(stats["sibling_window_s"], 2.0)
        self.assertEqual(stats["sibling_req_s"], 2.0)
        self.assertAlmostEqual(stats["sibling_p50_us"], 200000.0)
        self.assertAlmostEqual(stats["sibling_p95_us"], 300000.0)
        self.assertAlmostEqual(stats["sibling_p99_us"], 300000.0)
        self.assertAlmostEqual(stats["sibling_window_start_unix_s"], 1700000000.001)
        self.assertAlmostEqual(stats["sibling_window_end_unix_s"], 1700000002.001)

    def test_partial_failure_keeps_actual_observation_window_and_only_valid_samples(self):
        records = [response(1.0, 2.0), response(1.0, 3.0, body=b"partial"),
                   response(1.0, 4.0, status=b"500"), response(1.0, None),
                   TimeoutError("incomplete")]
        stats = sibling_metrics(records, valid, (1.0, 100.0, 0.0), 9.0)
        self.assertEqual(stats["sibling_samples"], 1)
        self.assertEqual(stats["sibling_completed"], 3)
        self.assertEqual(stats["sibling_missing_timing"], 2)
        self.assertEqual(stats["sibling_window_scope"], "failed_phase_observation")
        self.assertEqual(stats["sibling_window_s"], 8.0)
        self.assertEqual(stats["sibling_req_s"], 0.125)
        self.assertEqual(stats["sibling_p99_us"], 1000000.0)

    def test_zero_samples_never_synthesize_completion_or_quantiles(self):
        records = [response(1.0, None), response(None, 2.0),
                   response(0.0, 2.0), response(1.0, 10.0)]
        stats = sibling_metrics(records, valid, (1.0, 100.0, 0.0), 9.0)
        self.assertEqual(stats["sibling_samples"], 0)
        self.assertEqual(stats["sibling_req_s"], 0.0)
        for key in ("sibling_p50_us", "sibling_p95_us", "sibling_p99_us"):
            self.assertIsNone(stats[key])

    def test_anchor_brackets_epoch_read_and_reports_uncertainty(self):
        with patch("sibling_metrics.time.perf_counter", side_effect=[10.0, 10.004]), \
             patch("sibling_metrics.time.time", return_value=1700000000.0):
            window = begin_sibling_window()
        stats = sibling_metrics([response(10.01, 10.1)], valid, window, 20.0)
        self.assertAlmostEqual(stats["sibling_clock_anchor_span_s"], 0.004)
        self.assertAlmostEqual(stats["sibling_clock_anchor_uncertainty_s"], 0.002)
        self.assertAlmostEqual(stats["sibling_window_start_unix_s"], 1700000000.002)


class MemorySocket:
    def __init__(self):
        self.sent = bytearray()

    def sendall(self, data):
        self.sent.extend(data)


class ProtocolTimingTests(unittest.TestCase):
    def test_h2_get_and_post_record_dispatch_and_actual_stream_end(self):
        import http2_scenarios as h2
        client = h2.H2ScenarioClient(MemorySocket(), b"localhost")
        with patch("http2_scenarios.time.perf_counter", return_value=1.0):
            get_id = client.get()
        with patch("http2_scenarios.time.perf_counter", return_value=2.0):
            post_id = client.post_echo(b"x", 30.0)
        self.assertEqual(client.responses[get_id]["start"], 1.0)
        self.assertEqual(client.responses[post_id]["start"], 2.0)
        self.assertIsNone(client.responses[get_id]["done_at"])
        event = h2.StreamEnded(stream_id=get_id)
        with patch("http2_scenarios.time.perf_counter", return_value=3.0):
            client._handle([event])
        self.assertEqual(client.responses[get_id]["done_at"], 3.0)
        self.assertIsNone(client.responses[post_id]["done_at"])

    def test_h3_actual_data_end_preserves_timestamp_and_exact_body_sample(self):
        import http3_scenarios as h3
        from aioquic.quic.connection import QuicConnection
        async def consume():
            protocol = h3.ScenarioProtocol(QuicConnection(configuration=h3.QuicConfiguration(is_client=True)))
            record = {"future": asyncio.get_running_loop().create_future(),
                      "body": bytearray(), "status": None, "start": 3.0,
                      "done_at": None, "stream_id": 0, "cancelled": False}
            protocol._consume(record, h3.HeadersReceived(headers=[(b":status", b"200")], stream_id=0, stream_ended=False))
            with patch("http3_scenarios.time.perf_counter", return_value=4.0):
                protocol._consume(record, h3.DataReceived(data=b"x", stream_id=0, stream_ended=True))
            self.assertIs(record["future"].result(), record)
            stats = sibling_metrics([record], valid, (2.0, 100.0, 0.0), 9.0)
            self.assertEqual(stats["sibling_window_s"], 2.0)
            self.assertEqual(stats["sibling_samples"], 1)
            self.assertEqual(stats["sibling_p50_us"], 1000000.0)
        asyncio.run(consume())


if __name__ == "__main__":
    unittest.main()
