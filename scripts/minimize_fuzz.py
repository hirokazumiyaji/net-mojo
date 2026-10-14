#!/usr/bin/env python3
"""Reduce a retained Mojo batch while preserving a chosen failure signature."""

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
from tempfile import TemporaryDirectory
from typing import Callable, TypeVar

from run_fuzz import MAX_INPUT, REPLAY_TARGETS, write_batch


T = TypeVar("T")


def reduce_items(items: list[T], reproduces: Callable[[list[T]], bool]) -> list[T]:
    width = max(1, len(items) // 2)
    while items:
        changed = False
        for start in range(0, len(items), width):
            candidate = items[:start] + items[start + width:]
            if reproduces(candidate):
                items = candidate
                changed = True
                break
        if not changed:
            if width == 1:
                break
            width = max(1, width // 2)
        width = min(width, max(1, len(items)))
    return items


def read_batch(path: Path) -> list[bytes]:
    wire = path.read_bytes()
    inputs = []
    offset = 0
    while offset < len(wire):
        if len(wire) - offset < 4:
            raise ValueError("truncated batch length")
        length = struct.unpack_from(">I", wire, offset)[0]
        offset += 4
        if length > MAX_INPUT or length > len(wire) - offset:
            raise ValueError("invalid batch payload length")
        inputs.append(wire[offset:offset + length])
        offset += length
    return inputs


def reduce_batch(
    inputs: list[bytes], reproduces: Callable[[list[bytes]], bool]
) -> list[bytes]:
    if not reproduces(inputs):
        raise ValueError("original batch does not reproduce the selected failure")
    if reproduces([]):
        raise ValueError("failure reproduces without input; check the harness setup")
    inputs = reduce_items(inputs, reproduces)
    for index in range(len(inputs)):
        def preserves(candidate: list[int]) -> bool:
            trial = list(inputs)
            trial[index] = bytes(candidate)
            return reproduces(trial)
        inputs[index] = bytes(reduce_items(list(inputs[index]), preserves))
    return inputs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=REPLAY_TARGETS)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--signature", required=True)
    args = parser.parse_args()
    metadata_path = args.output.with_suffix(args.output.suffix + ".json")
    if args.input.resolve() in (args.output.resolve(), metadata_path.resolve()):
        parser.error("output and metadata must differ from the original artifact")
    if not args.signature:
        parser.error("signature must be nonempty")
    inputs = read_batch(args.input)
    with TemporaryDirectory(prefix="net-mojo-reduce-") as directory:
        trial = Path(directory) / "candidate.bin"
        failure_code = None

        def reproduces(candidate: list[bytes]) -> bool:
            nonlocal failure_code
            write_batch(trial, candidate)
            with trial.open("rb") as source:
                result = subprocess.run(
                    ["build/fuzz/parser"], stdin=source,
                    env=dict(os.environ, NET_FUZZ_TARGET=args.target),
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    timeout=60,
                )
            matches = result.returncode != 0 and args.signature.encode() in result.stdout
            if matches and failure_code is None:
                failure_code = result.returncode
            return matches and result.returncode == failure_code

        reduced = reduce_batch(inputs, reproduces)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_batch(args.output, reduced)
    metadata_path.write_text(
        json.dumps({
            "target": args.target,
            "signature": args.signature,
            "returncode": failure_code,
            "original_cases": len(inputs),
            "reduced_cases": len(reduced),
            "case_lengths": [len(case) for case in reduced],
        }, indent=2) + "\n"
    )
    print(f"Reduced {len(inputs)} cases to {len(reduced)}; replay {args.output}")


if __name__ == "__main__":
    main()
