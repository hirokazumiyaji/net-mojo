#!/usr/bin/env python3
"""Regression tests for structured reduction using a harmless fixed marker."""

from pathlib import Path
import tempfile
import unittest
import sys

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts"))

from minimize_fuzz import read_batch, reduce_batch
from run_fuzz import write_batch


MARKER = b"NET-MOJO-REDUCE"


def contains_marker(cases: list[bytes]) -> bool:
    return any(MARKER in case for case in cases)


class ReduceTests(unittest.TestCase):
    def test_reduces_cases_and_payload_to_fixed_marker(self) -> None:
        cases = [b"before", b"noise" + MARKER + b"tail", b"after"]
        self.assertEqual(reduce_batch(cases, contains_marker), [MARKER])

    def test_keeps_two_cases_when_predicate_requires_both(self) -> None:
        def contains_two_markers(cases: list[bytes]) -> bool:
            return sum(MARKER in case for case in cases) == 2
        cases = [b"noise", MARKER + b"x", b"y" + MARKER]
        self.assertEqual(reduce_batch(cases, contains_two_markers), [MARKER, MARKER])

    def test_nonreproducing_input_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "does not reproduce"):
            reduce_batch([b"ordinary"], contains_marker)

    def test_batch_roundtrip_preserves_binary_and_empty_cases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "batch.bin"
            cases = [b"", b"\x00\xff", MARKER]
            write_batch(path, cases)
            self.assertEqual(read_batch(path), cases)

    def test_truncated_lengths_and_payloads_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "batch.bin"
            for wire in [b"\x00", b"\x00\x00\x00\x02x", b"\x00\x00\x20\x01"]:
                path.write_bytes(wire)
                with self.assertRaises(ValueError):
                    read_batch(path)


if __name__ == "__main__":
    unittest.main()
