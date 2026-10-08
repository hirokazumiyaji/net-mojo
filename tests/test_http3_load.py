"""Exercise H3 loader window/output metadata with owned in-memory results."""

import asyncio
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "http3_load_under_test", ROOT / "benchmarks/http3_load.py"
)
loader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(loader)


class LoaderWindowTests(unittest.TestCase):
    def setUp(self):
        self.boundaries = []

    async def completed_connection(
        self, host, port, path, authority, streams, stop_at, warmup_until,
        latencies, counters,
    ):
        self.boundaries.append((warmup_until, stop_at))
        counters["ok"] += 3
        counters["warmup_ok"] += 7
        counters["late"] = counters.get("late", 0) + 2
        latencies.extend([100.0, 200.0, 300.0])

    async def connection_without_late(
        self, host, port, path, authority, streams, stop_at, warmup_until,
        latencies, counters,
    ):
        counters["ok"] += 1
        latencies.append(100.0)

    def run_result(self, connection):
        with (
            mock.patch.object(loader, "_one_connection", connection),
            mock.patch.object(
                loader.time, "perf_counter", side_effect=[100.0, 100.004]
            ),
            mock.patch.object(loader.time, "time", return_value=1700000000.002),
        ):
            return asyncio.run(loader.run_load(
                "https://127.0.0.1:18453/fixed", 1, 1, 10.0, 30.0
            ))

    def test_run_load_returns_its_scheduled_wall_window_and_phase_counts(self):
        result = self.run_result(self.completed_connection)
        self.assertEqual(result["ok"], 3)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["warmup_ok"], 7)
        self.assertEqual(result["samples"], 3)
        self.assertAlmostEqual(result["req_s"], 0.1)
        for key in (
            "late", "load_start_unix_s", "measurement_start_unix_s",
            "measurement_end_unix_s", "clock_anchor_span_s",
            "rate_denominator_s",
        ):
            self.assertIn(key, result)
        self.assertEqual(result["late"], 2)
        self.assertAlmostEqual(result["load_start_unix_s"], 1700000000.004, places=5)
        self.assertAlmostEqual(
            result["measurement_start_unix_s"], 1700000010.004, places=5
        )
        self.assertAlmostEqual(
            result["measurement_end_unix_s"], 1700000040.004, places=5
        )
        self.assertAlmostEqual(result["clock_anchor_span_s"], 0.004)
        self.assertEqual(result["rate_denominator_s"], 30.0)
        self.assertEqual(len(self.boundaries), 1)
        self.assertAlmostEqual(self.boundaries[0][0], 110.004)
        self.assertAlmostEqual(self.boundaries[0][1], 140.004)

    def test_run_load_exposes_zero_late_without_a_late_result(self):
        result = self.run_result(self.connection_without_late)
        self.assertIn("late", result)
        self.assertEqual(result["late"], 0)
        self.assertEqual(result["ok"], 1)
        self.assertEqual(result["samples"], 1)

    def test_churn_flag_runs_a_worker_per_connection_slot_and_rejects_streams(self):
        connections = 0

        async def churn(host, port, path, authority, stop_at, warmup_until,
                         latencies, counters):
            nonlocal connections
            connections += 1
            counters["ok"] += 2
            latencies.extend([150.0, 350.0])

        with (
            mock.patch.object(loader, "_churn_worker", churn),
            mock.patch.object(
                loader.time, "perf_counter", side_effect=[0.0, 0.0]
            ),
            mock.patch.object(loader.time, "time", return_value=1.0),
        ):
            result = asyncio.run(loader.run_load(
                "https://127.0.0.1:18453/fixed", 3, 1, 1.0, 2.0, churn=True,
            ))
        self.assertEqual(connections, 3)
        self.assertEqual(result["ok"], 6)
        self.assertEqual(result["samples"], 6)

        with self.assertRaises(RuntimeError):
            asyncio.run(loader.run_load(
                "https://127.0.0.1:18453/fixed", 1, 2, 1.0, 2.0, churn=True,
            ))

    def test_cli_keeps_metric_prefix_and_appends_unambiguous_window_metadata(self):
        output = io.StringIO()
        with (
            mock.patch.object(loader, "_one_connection", self.completed_connection),
            mock.patch.object(
                loader.time, "perf_counter", side_effect=[100.0, 100.004]
            ),
            mock.patch.object(loader.time, "time", return_value=1700000000.002),
            mock.patch.object(sys, "argv", [
                "http3_load.py", "--url", "https://127.0.0.1:18453/fixed",
                "--clients", "1", "--streams", "1", "--warmup", "10",
                "--duration", "30",
            ]),
            redirect_stdout(output),
        ):
            loader.main()
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0].split()[:7], [
            "req_s=0.100", "p50_us=200", "p95_us=300", "p99_us=300",
            "ok=3", "failed=0", "samples=3",
        ])
        fields = dict(token.split("=", 1) for token in lines[0].split())
        self.assertIn("warmup_successes", fields)
        self.assertIn("late_responses", fields)
        self.assertNotIn("warmup_ok", fields)
        self.assertEqual(fields["warmup_successes"], "7")
        self.assertEqual(fields["late_responses"], "2")
        self.assertAlmostEqual(float(fields["load_start_unix_s"]), 1700000000.004, places=5)
        self.assertAlmostEqual(
            float(fields["measurement_start_unix_s"]), 1700000010.004, places=5
        )
        self.assertAlmostEqual(
            float(fields["measurement_end_unix_s"]), 1700000040.004, places=5
        )
        self.assertAlmostEqual(float(fields["clock_anchor_span_s"]), 0.004)
        self.assertEqual(float(fields["rate_denominator_s"]), 30.0)


if __name__ == "__main__":
    unittest.main()
