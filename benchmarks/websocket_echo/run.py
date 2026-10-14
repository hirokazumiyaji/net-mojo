#!/usr/bin/env python3
"""Record own-loopback echo throughput and p99 without pass/fail thresholds."""
import argparse
import asyncio
import json
import math
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from test_http_websocket_interop import fixture
from websockets.asyncio.client import connect


async def measure(iterations: int) -> None:
    with fixture() as port:
        async with connect(f"ws://127.0.0.1:{port}/echo", compression=None,
                           proxy=None, max_size=2 * 1024 * 1024,
                           open_timeout=10, close_timeout=10) as ws:
            for size in (64, 4096, 1_048_576):
                payload = b"x" * size
                for _ in range(5):
                    await ws.send(payload)
                    assert await asyncio.wait_for(ws.recv(), timeout=10) == payload
                samples = []
                started = time.perf_counter()
                for _ in range(iterations):
                    before = time.perf_counter_ns()
                    await ws.send(payload)
                    assert await asyncio.wait_for(ws.recv(), timeout=10) == payload
                    samples.append(time.perf_counter_ns() - before)
                elapsed = time.perf_counter() - started
                samples.sort()
                print(json.dumps({
                    "transport": "ws", "payload_bytes": size, "iterations": iterations,
                    "messages_per_second": iterations / elapsed,
                    "roundtrip_mib_per_second": 2 * size * iterations / elapsed / 1_048_576,
                    "p99_ms": samples[math.ceil(iterations * 0.99) - 1] / 1_000_000,
                }), flush=True)


def positive(value: str) -> int:
    count = int(value)
    if count <= 0:
        raise argparse.ArgumentTypeError("iterations must be positive")
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=positive, default=200)
    args = parser.parse_args()
    asyncio.run(measure(args.iterations))


if __name__ == "__main__":
    main()
