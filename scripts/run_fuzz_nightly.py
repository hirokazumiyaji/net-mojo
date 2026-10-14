#!/usr/bin/env python3
"""Run bounded parser replay batches while retaining the exact current input."""

import argparse
import json
from pathlib import Path
import subprocess
import time

from run_fuzz import MAX_INPUT, REPLAY_TARGETS, SEEDS, make_inputs, positive, replay, write_batch


def run_repeated(target: str, root: Path, seconds: float, iterations: int, seed: int) -> int:
    root.mkdir(parents=True, exist_ok=True)
    batch = root / f"{target}-nightly.bin"
    metadata = root / f"{target}-nightly.json"
    deadline = time.monotonic() + seconds
    rounds = 0
    while time.monotonic() < deadline:
        current_seed = seed + rounds
        write_batch(batch, make_inputs(target, current_seed, iterations))
        metadata.write_text(json.dumps({
            "target": target,
            "seed": current_seed,
            "batch": str(batch),
            "iterations": iterations,
            "round": rounds,
        }, indent=2) + "\n")
        print(f"{target}: round={rounds} seed={current_seed}; replay {batch}", flush=True)
        replay(target, batch)
        rounds += 1
    return rounds


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=[*REPLAY_TARGETS, "hpack"])
    parser.add_argument("--seconds", type=positive, default=1800)
    parser.add_argument("--iterations", type=positive, default=10000)
    parser.add_argument("--seed", type=int, default=227)
    args = parser.parse_args()
    root = Path("build/fuzz")
    root.mkdir(parents=True, exist_ok=True)
    if args.target == "hpack":
        corpus = root / "hpack-corpus"
        corpus.mkdir(exist_ok=True)
        for index, data in enumerate(SEEDS["hpack"]):
            (corpus / f"seed-{index}").write_bytes(data)
        (root / "hpack-nightly.json").write_text(json.dumps({
            "target": "hpack", "seed": args.seed, "seconds": args.seconds,
            "max_input": MAX_INPUT, "corpus": str(corpus),
        }, indent=2) + "\n")
        subprocess.run([str(root / "hpack"), str(corpus), f"-max_total_time={args.seconds}",
                        "-timeout=10", "-rss_limit_mb=2048", f"-max_len={MAX_INPUT}",
                        f"-seed={args.seed}", f"-artifact_prefix={root}/"],
                       check=True, timeout=args.seconds + 30)
    else:
        rounds = run_repeated(args.target, root, args.seconds, args.iterations, args.seed)
        print(f"{args.target}: completed {rounds} replay batches")


if __name__ == "__main__":
    main()
