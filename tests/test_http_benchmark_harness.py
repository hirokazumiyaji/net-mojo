#!/usr/bin/env python3
"""Exercise benchmark measurement functions with controlled loader output."""

from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
H2_RESULT = """finished in 1.00s, 100.00 req/s, 1KB/s
requests: 100 total, 100 started, 100 done, 100 succeeded, 0 failed, 0 errored, 0 timeout
request : 1us 4us 2us 3us 4us 2us 1us 100%
"""
H3_RESULT = "req_s=100.000 p50_us=2 p95_us=3 p99_us=4 ok=100 failed=0 samples=100\n"


def measurement_functions(protocol):
    script = ROOT / f"benchmarks/http/run_http{protocol}_bench.sh"
    names = ("to_us", "run_h2load") if protocol == 2 else ("run_load",)
    source = script.read_text()
    return "\n".join(
        re.search(rf"^{name}\(\) \{{\n.*?^\}}", source, re.M | re.S)[0]
        for name in names
    )


class BenchmarkHarnessTests(unittest.TestCase):
    def run_measurement(self, protocol, output, loader_rc=0, sampler=True):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            fixture = work / "loader.out"
            fixture.write_text(output)
            loader = work / "loader"
            body = f"cat {shlex.quote(str(fixture))}\nexit {loader_rc}\n"
            if protocol == 3:
                body = (
                    'if [ "${1:-}" = benchmarks/http3_load.py ]; then\n'
                    + body
                    + "fi\n"
                    + f"exec {shlex.quote(sys.executable)} \"$@\"\n"
                )
            loader.write_text("#!/usr/bin/env bash\n" + body)
            loader.chmod(0o755)
            sample = work / "peer_c1_m1_r1.sample"
            sample.write_text("cpu_pct=999 rss_kb=999 fd_count=999\n")
            sampler_body = (
                'printf "cpu_pct=1 rss_kb=2 fd_count=3\\n" >"$2"'
                if sampler
                else "return 0"
            )
            runner = work / "run.sh"
            function = "run_h2load" if protocol == 2 else "run_load"
            runner.write_text(
                "set -euo pipefail\n"
                f"OUT_DIR={shlex.quote(directory)}\n"
                "BENCH_FAILURES=0\nWARMUP_S=0\nMEASURE_S=0\nLOSS_PCT=0\n"
                f"PIXI_PYTHON={shlex.quote(str(loader))}\n"
                f"h2load() {{ {shlex.quote(str(loader))} \"$@\"; }}\n"
                f"sample_server() {{ {sampler_body}; }}\n"
                + measurement_functions(protocol)
                + f"\n{function} peer https://unused/fixed 1 1 1 1\n"
                + '[ "$BENCH_FAILURES" -eq 0 ]\n'
            )
            result = subprocess.run(
                ["bash", str(runner)], capture_output=True, text=True, timeout=10
            )
            summary = work / "summary.tsv"
            return result, summary.read_text() if summary.exists() else ""

    def test_accepts_valid_measurement_and_refreshes_sample(self):
        cases = (
            (2, H2_RESULT),
            (2, H2_RESULT.replace("100.00 req/s", "0.50 req/s")
             .replace("2us", "0.002ms").replace("3us", "0.000003s")),
            (3, H3_RESULT),
            (3, H3_RESULT.replace("req_s=100.000", "req_s=0.500")
             .replace("p50_us=2", "p50_us=0")),
        )
        for protocol, output in cases:
            with self.subTest(protocol=protocol, output=output):
                result, summary = self.run_measurement(protocol, output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("cpu_pct=1 rss_kb=2 fd_count=3", summary)
                self.assertIn("p95_us=3", summary)

    def test_rejects_empty_or_zero_work(self):
        cases = (
            (2, ""),
            (2, H2_RESULT.replace("100.00 req/s", "0.00 req/s")),
            (2, H2_RESULT.replace("100 succeeded", "0 succeeded")),
            (3, ""),
            (3, H3_RESULT.replace("req_s=100.000", "req_s=0.000")),
            (3, H3_RESULT.replace("ok=100", "ok=0")),
        )
        for protocol, output in cases:
            with self.subTest(protocol=protocol, output=output):
                result, _ = self.run_measurement(protocol, output)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_missing_or_invalid_percentiles(self):
        for protocol, output in ((2, H2_RESULT), (3, H3_RESULT)):
            cases = (
                output.replace("request : 1us 4us 2us 3us 4us 2us 1us 100%\n", "")
                if protocol == 2
                else output.replace("p95_us=3 ", ""),
                output.replace("3us", "nan")
                if protocol == 2
                else output.replace("p95_us=3", "p95_us=nan"),
                output.replace("3us", "-3us")
                if protocol == 2
                else output.replace("p95_us=3", "p95_us=-3"),
                output.replace("3us", "1us")
                if protocol == 2
                else output.replace("p95_us=3", "p95_us=1"),
                output.replace("3us", "3bogus")
                if protocol == 2
                else output.replace("p95_us=3", "p95_us=3bogus"),
            )
            for malformed in cases:
                with self.subTest(protocol=protocol, output=malformed):
                    result, _ = self.run_measurement(protocol, malformed)
                    self.assertNotEqual(result.returncode, 0)

    def test_rejects_failed_or_missing_failure_count(self):
        cases = (
            (2, H2_RESULT.replace("0 failed", "1 failed")),
            (2, H2_RESULT.replace(", 0 failed", "")),
            (2, H2_RESULT.replace("0 errored", "1 errored")),
            (2, H2_RESULT.replace(", 0 errored", "")),
            (2, H2_RESULT.replace("0 timeout", "1 timeout")),
            (2, H2_RESULT.replace(", 0 timeout", "")),
            (3, H3_RESULT.replace("failed=0", "failed=1")),
            (3, H3_RESULT.replace("failed=0 ", "")),
        )
        for protocol, output in cases:
            with self.subTest(protocol=protocol, output=output):
                result, _ = self.run_measurement(protocol, output)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_loader_failure_with_successful_output(self):
        for protocol, output in ((2, H2_RESULT), (3, H3_RESULT)):
            with self.subTest(protocol=protocol):
                result, _ = self.run_measurement(protocol, output, loader_rc=1)
                self.assertNotEqual(result.returncode, 0)

    def test_never_reuses_stale_sample_when_sampler_produces_no_output(self):
        for protocol, output in ((2, H2_RESULT), (3, H3_RESULT)):
            with self.subTest(protocol=protocol):
                result, summary = self.run_measurement(protocol, output, sampler=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("cpu_pct=999", summary)


if __name__ == "__main__":
    unittest.main()
