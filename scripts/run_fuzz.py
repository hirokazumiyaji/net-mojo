#!/usr/bin/env python3
"""Seed, mutate and retain bounded smoke inputs for the fuzzing targets."""

import argparse
import os
from pathlib import Path
import random
import struct
import subprocess

MAX_INPUT = 8192
SEEDS = {
    "http1": [
        b"",
        b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n",
        b"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ndata",
        b"POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
        b"3\r\nabc\r\n0\r\nX-Trace: ok\r\n\r\n",
        b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n"
        b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        b"GET http://example.com/x?q=1 HTTP/1.1\r\nHost: example.com\r\n\r\n",
        b"GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n",
        b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999999999999999999\r\n\r\n",
        b"GET / HTTP/1.1\r\nHost: x\r\nX: " + b"a" * 8100 + b"\r\n\r\n",
    ],
    "authority": [
        b"", b"localhost", b"example.com:443", b"[::1]:65535", b"[2001:db8::1]",
        b"example%2ecom", b"x%", b"x%GG", b"[::1", b"x:65536", b"user@host",
        b"x\r\nHost: evil", b"\x00", b"\xff\xfe", b"a" * MAX_INPUT,
    ],
    "hpack": [
        b"\x82\x86\x84", b"\x82\x86\x84\x41\x0fwww.example.com",
        b"\x20", b"\xff", b"\x40\x01x\x01y",
        struct.pack(">II", 1, 1) + b"xy",
        struct.pack(">II", 0xffffffff, 0xffffffff),
    ],
}


def mutate(data: bytes, rng: random.Random) -> bytes:
    position = rng.randrange(len(data) + 1)
    operation = rng.randrange(5)
    if operation == 0:
        return data[:position]
    if operation == 1:
        return data[:position] + data[min(position + rng.randrange(1, 33), len(data)):]
    if operation == 2:
        return (data[:position] + rng.randbytes(rng.randrange(1, 33)) + data[position:])[:MAX_INPUT]
    if operation == 3:
        return (data[:position] + bytes([rng.randrange(256)]) + data[position + 1:])[:MAX_INPUT]
    fragment = data[position:position + rng.randrange(1, 33)]
    return (data[:position] + fragment * rng.randrange(2, 65) + data[position:])[:MAX_INPUT]


def make_inputs(target: str, seed: int, iterations: int) -> list[bytes]:
    rng = random.Random(seed)
    corpus = SEEDS[target]
    inputs = list(corpus)
    for data in corpus:
        inputs.extend(data[:end] for end in range(min(len(data), 128)))
    for _ in range(iterations):
        source = rng.choice(corpus if rng.randrange(2) == 0 else inputs)
        inputs.append(mutate(source, rng))
    return inputs


def write_batch(path: Path, inputs: list[bytes]) -> None:
    with path.open("wb") as output:
        for data in inputs:
            output.write(struct.pack(">I", len(data)))
            output.write(data)


def replay(target: str, path: Path) -> None:
    with path.open("rb") as source:
        subprocess.run(["build/fuzz/parser"], stdin=source,
                       env=dict(os.environ, NET_FUZZ_TARGET=target), check=True, timeout=60)


def positive(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["http1", "authority", "hpack", "smoke"])
    parser.add_argument("--seed", type=int, default=227)
    parser.add_argument("--iterations", type=positive, default=10000)
    parser.add_argument("--seconds", type=positive, default=60)
    parser.add_argument("--replay", type=Path)
    args = parser.parse_args()
    if args.replay:
        if args.target not in ("http1", "authority"):
            parser.error("--replay requires http1 or authority")
        replay(args.target, args.replay)
        return
    root = Path("build/fuzz")
    root.mkdir(parents=True, exist_ok=True)
    targets = ["http1", "authority", "hpack"] if args.target == "smoke" else [args.target]
    for target in targets:
        if target == "hpack":
            corpus = root / "hpack-corpus"
            corpus.mkdir(exist_ok=True)
            for index, data in enumerate(SEEDS[target]):
                (corpus / f"seed-{index}").write_bytes(data)
            subprocess.run([str(root / "hpack"), str(corpus), f"-max_total_time={args.seconds}",
                            "-timeout=10", "-rss_limit_mb=2048", f"-max_len={MAX_INPUT}",
                            f"-seed={args.seed}", f"-artifact_prefix={root}/"],
                           check=True, timeout=args.seconds + 30)
        else:
            path = root / f"{target}-seed-{args.seed}.bin"
            write_batch(path, make_inputs(target, args.seed, args.iterations))
            print(f"Replay: python3 scripts/run_fuzz.py {target} --replay {path}", flush=True)
            replay(target, path)


if __name__ == "__main__":
    main()
