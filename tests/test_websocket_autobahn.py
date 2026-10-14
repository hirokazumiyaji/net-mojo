"""Report acceptance must account for every case scheduled by upstream."""
import json
from pathlib import Path
import tempfile
import unittest

from websocket_autobahn import scheduled_cases, validate_reports


class ReportTests(unittest.TestCase):
    def validate(self, records, expected):
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory)
            (reports / "index.json").write_text(json.dumps({"net-mojo": records}))
            return validate_reports(reports, expected)

    def test_complete_strict_and_informational(self):
        self.assertEqual(self.validate({
            "1.1.1": {"behavior": "OK", "behaviorClose": "OK"},
            "7.1.6": {"behavior": "INFORMATIONAL", "behaviorClose": "INFORMATIONAL"},
        }, {"1.1.1", "7.1.6"}), 2)

    def test_partial_run_rejected(self):
        with self.assertRaisesRegex(AssertionError, "missing.*1.1.2"):
            self.validate({"1.1.1": {"behavior": "OK", "behaviorClose": "OK"}},
                          {"1.1.1", "1.1.2"})

    def test_unexpected_result_rejected(self):
        with self.assertRaisesRegex(AssertionError, "unexpected.*1.1.2"):
            self.validate({"1.1.1": {}, "1.1.2": {}}, {"1.1.1"})

    def test_nonstrict_and_missing_status_rejected(self):
        for status in ("NON-STRICT", "FAILED", None):
            with self.subTest(status=status), self.assertRaisesRegex(AssertionError, "behavior="):
                self.validate({"1.1.1": {"behavior": status, "behaviorClose": "OK"}}, {"1.1.1"})

    def test_upstream_schedule(self):
        self.assertEqual(scheduled_cases("header\nCases = ['1.1.1', '2.1']\nfooter"),
                         {"1.1.1", "2.1"})
        for output in ("", "Cases = []", "Cases = ['1.1.1', '1.1.1']", "Cases = [2]"):
            with self.subTest(output=output), self.assertRaises(AssertionError):
                scheduled_cases(output)


if __name__ == "__main__":
    unittest.main()
