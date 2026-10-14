#!/usr/bin/env python3
"""Run pinned upstream h2spec against the local ASan TLS fixture."""

from __future__ import annotations

import json
import selectors
import subprocess
from pathlib import Path

from test_http2_integration import _shutdown


BUILD = Path("build/conformance")
H2SPEC_COMMIT = "70ac2294010887f48b18e2d64f5cccd48421fad1"


def main() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    fixture_log = BUILD / "http2-server.log"
    suite_log = BUILD / "h2spec.log"
    suite_log.write_text("")
    with fixture_log.open("w") as errors:
        fixture = subprocess.Popen(
            [str(BUILD / "http2-server")],
            stdout=subprocess.PIPE,
            stderr=errors,
            text=True,
        )
        selector = selectors.DefaultSelector()
        selector.register(fixture.stdout, selectors.EVENT_READ)
        try:
            if not selector.select(30):
                raise RuntimeError("HTTP/2 fixture startup timed out")
            ready = fixture.stdout.readline()
            if not ready.startswith("READY "):
                raise RuntimeError(f"HTTP/2 fixture did not start: {ready!r}")
            port = int(ready.split()[1])
            command = [
                str(BUILD / "h2spec"),
                "--tls",
                "--insecure",
                "--host", "127.0.0.1",
                "--port", str(port),
                "--junit-report", str(BUILD / "h2spec.xml"),
            ]
            (BUILD / "h2spec.json").write_text(
                json.dumps({"h2spec_commit": H2SPEC_COMMIT, "command": command}, indent=2)
                + "\n"
            )
            with suite_log.open("w") as output:
                result = subprocess.run(
                    command, stdout=output, stderr=subprocess.STDOUT, timeout=300
                )
            _shutdown(port)
            fixture_status = fixture.wait(timeout=30)
            if fixture_status != 0:
                raise RuntimeError(f"ASan HTTP/2 fixture exited {fixture_status}")
            if result.returncode != 0:
                raise RuntimeError(f"h2spec exited {result.returncode}")
        finally:
            selector.close()
            if fixture.poll() is None:
                fixture.kill()
            fixture.wait()
            fixture.stdout.close()
            if suite_log.exists():
                print(suite_log.read_text(), end="")
            print(f"HTTP/2 fixture log: {fixture_log}")


if __name__ == "__main__":
    main()
