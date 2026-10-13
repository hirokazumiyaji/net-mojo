import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

scripts = Path(__file__).parents[2] / "scripts"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("run_fuzz_nightly", scripts / "run_fuzz_nightly.py")
nightly = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nightly)


class NightlyReplayTests(unittest.TestCase):
    @unittest.skipUnless(Path("build/fuzz/parser").exists(), "build fuzz targets first")
    def test_retained_batch_matches_seed_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with contextlib.redirect_stdout(io.StringIO()):
                rounds = nightly.run_repeated("http2-frames", root, 0.05, 1, 227)
            self.assertGreaterEqual(rounds, 1)
            state = json.loads((root / "http2-frames-nightly.json").read_text())
            self.assertEqual(state["seed"], 227 + rounds - 1)
            self.assertEqual(state["round"], rounds - 1)
            expected = root / "expected.bin"
            nightly.write_batch(expected, nightly.make_inputs("http2-frames", state["seed"], 1))
            self.assertEqual(expected.read_bytes(), Path(state["batch"]).read_bytes())
            self.assertEqual(sorted(path.name for path in root.glob("*-nightly.*")),
                             ["http2-frames-nightly.bin", "http2-frames-nightly.json"])

    def test_failure_retains_exact_input_and_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            failure = subprocess.CalledProcessError(1, "parser")
            with patch.object(nightly, "replay", side_effect=failure) as replay:
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(subprocess.CalledProcessError):
                        nightly.run_repeated("http1", root, 1, 3, 228)
            replay.assert_called_once_with("http1", root / "http1-nightly.bin")
            state = json.loads((root / "http1-nightly.json").read_text())
            self.assertEqual(state["seed"], 228)
            self.assertEqual(state["round"], 0)
            expected = root / "expected.bin"
            nightly.write_batch(expected, nightly.make_inputs("http1", 228, 3))
            self.assertEqual(expected.read_bytes(), Path(state["batch"]).read_bytes())

    def test_dispatch_budget_bounds(self):
        workflow = Path(".github/workflows/fuzz-nightly.yml").read_text()
        validation = workflow.split("        run: |\n", 1)[1].split("          pixi run", 1)[0]
        for value in ("1", "30", "1800"):
            result = subprocess.run(["bash", "-ec", validation],
                                    env=dict(os.environ, REPLAY_SECONDS=value))
            self.assertEqual(result.returncode, 0, value)
        for value in ("0", "1801", "03410", "18446744073709551617", "-1", "x", ""):
            result = subprocess.run(["bash", "-ec", validation],
                                    env=dict(os.environ, REPLAY_SECONDS=value))
            self.assertNotEqual(result.returncode, 0, value)

    def test_native_artifact_patterns_include_leaks(self):
        workflow = Path(".github/workflows/fuzz-nightly.yml").read_text()
        for kind in ("crash", "timeout", "oom", "leak"):
            self.assertIn(f"build/fuzz/{kind}-*", workflow)

    def test_nonpositive_budget_is_rejected(self):
        for option in ("--seconds", "--iterations"):
            result = subprocess.run([sys.executable, str(scripts / "run_fuzz_nightly.py"),
                                     "http1", option, "0"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be positive", result.stderr)


if __name__ == "__main__":
    unittest.main()
