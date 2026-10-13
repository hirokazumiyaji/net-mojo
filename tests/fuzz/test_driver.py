import importlib.util
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("run_fuzz", Path(__file__).parents[2] / "scripts/run_fuzz.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class MutationDriverTests(unittest.TestCase):
    def test_serialized_xy_regression_is_replayed(self):
        fixture = Path(__file__).parents[1] / "fuzz-regressions/hpack/serialized-xy.bin"
        fields = fixture.read_bytes()
        self.assertEqual(fields, struct.pack(">II", 1, 1) + b"xy")
        for target in ("hpack", "hpack-mojo"):
            self.assertIn(fields, driver.make_inputs(target, 227, 1))

    def test_seed_reproduces_exact_inputs(self):
        for target in ("http1", "authority", "http2-frames", "ip", "address", "hpack-mojo"):
            first = driver.make_inputs(target, 227, 100)
            self.assertEqual(first, driver.make_inputs(target, 227, 100))
            self.assertNotEqual(first, driver.make_inputs(target, 228, 100))
            self.assertTrue(all(len(data) <= driver.MAX_INPUT for data in first))
            self.assertTrue(set(driver.SEEDS[target]).issubset(first))

    def test_mutation_preserves_size_bound_for_full_seed(self):
        rng = random.Random(227)
        for _ in range(1000):
            self.assertLessEqual(len(driver.mutate(b"x" * driver.MAX_INPUT, rng)), driver.MAX_INPUT)

    def test_batch_preserves_binary_bytes_and_empty_case(self):
        inputs = [b"", b"a\x00\xff\r\n", b"x" * driver.MAX_INPUT]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "inputs.bin"
            driver.write_batch(path, inputs)
            encoded = path.read_bytes()
        decoded = []
        while encoded:
            length = struct.unpack(">I", encoded[:4])[0]
            decoded.append(encoded[4:4 + length])
            encoded = encoded[4 + length:]
        self.assertEqual(inputs, decoded)

    @unittest.skipUnless(Path("build/fuzz/parser").exists(), "build fuzz targets first")
    def test_replay_rejects_malformed_batch(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.bin"
            for data in (b"\x00", struct.pack(">I", 4) + b"a", struct.pack(">I", driver.MAX_INPUT + 1)):
                path.write_bytes(data)
                with self.assertRaises(subprocess.CalledProcessError):
                    driver.replay("http1", path)

    def test_negative_duration_is_rejected_before_running_target(self):
        result = subprocess.run(["python3", str(Path(driver.__file__)), "hpack", "--seconds", "0"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be positive", result.stderr)


if __name__ == "__main__":
    unittest.main()
