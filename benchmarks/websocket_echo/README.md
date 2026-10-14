# WebSocket echo measurement

Run `pixi run -e websocket benchmark-websocket-echo`, or pass
`--iterations N` to `python3 benchmarks/websocket_echo/run.py` after building
the fixture. The independent pinned asyncio client targets only the local
repository fixture. Compression is disabled.

Each JSON record reports binary payload bytes (64, 4096, 1048576), measured
iterations, messages/second, bytes in both directions in MiB/second, and
nearest-rank p99 roundtrip latency. Five warmup echoes per size are excluded.
There are no performance pass/fail thresholds. The fixture and client run on
the same machine; compare runs with the same toolchain and environment.
