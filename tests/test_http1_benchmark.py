#!/usr/bin/env python3
"""Wire checks for the optimized benchmark server and independent Go peer."""

import argparse
import http.client
import json
from pathlib import Path
import socket
import subprocess
import time


def ready(process, port):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"benchmark server exited: {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.01)
    raise RuntimeError("benchmark server did not listen")


def check(port):
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    results = []
    cases = [("GET", "/fixed", b"", False), ("GET", "/json", b"", False)]
    for size in (1024, 65536):
        body = bytes(range(256)) * (size // 256)
        for chunked in (False, True):
            cases.append(("POST", "/echo", body, chunked))
    try:
        for method, path, body, chunked in cases:
            content = [body[:17], body[17:]] if chunked else body
            client.request(method, path, content, encode_chunked=chunked)
            response = client.getresponse()
            actual = response.read()
            assert response.status == 200, (method, path, response.status)
            assert response.version == 11
            assert int(response.getheader("Content-Length")) == len(actual)
            if path == "/fixed":
                assert actual == b"a" * 64
            elif path == "/json":
                assert len(actual) == 1024
                assert json.loads(actual)["id"] == 1234567890
            else:
                assert actual == body, (len(body), chunked, len(actual))
            results.append((actual, response.getheader("Content-Type")))
            assert client.sock is not None, "keep-alive connection was closed"
        return results
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--go-baseline", required=True, type=Path)
    args = parser.parse_args()
    processes = []
    try:
        processes.append(subprocess.Popen([str(args.server.resolve())]))
        processes.append(subprocess.Popen([
            str(args.go_baseline.resolve()), "-addr", "127.0.0.1:18082",
        ]))
        ready(processes[0], 18081)
        ready(processes[1], 18082)
        mojo = check(18081)
        baseline = check(18082)
        assert mojo == baseline, "benchmark response bytes/types differ from Go"
        print("HTTP/1.1 benchmark: six exact keep-alive responses match Go")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    main()
