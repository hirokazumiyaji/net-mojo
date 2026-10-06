"""Verify actual benchmark process FD limits with owned child servers."""

import argparse
import json
import resource
import select
import socket
import subprocess
import time


def check(command, port, limits, expected):
    def constrain_child():
        resource.setrlimit(resource.RLIMIT_NOFILE, limits)

    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, preexec_fn=constrain_child if limits is not None else None)
    try:
        assert select.select([child.stdout], [], [], 5)[0], "startup metadata timed out"
        line = child.stdout.readline()
        assert line.startswith("{"), f"missing structured startup metadata: {line!r}"
        record = json.loads(line)
        assert record["event"] == "fd_limits" and record["source"] == "getrlimit"
        assert record["pid"] == child.pid
        assert isinstance(record["soft"], int) and isinstance(record["hard"], int)
        if expected is not None:
            assert (record["soft"], record["hard"]) == expected, record
        deadline = time.monotonic() + 5
        while True:
            try:
                connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                break
            except OSError:
                assert child.poll() is None, child.stderr.read()
                assert time.monotonic() < deadline, "benchmark did not listen"
                time.sleep(.01)
        with connection:
            connection.sendall(b"GET /fixed HTTP/1.1\r\nHost: localhost\r\n\r\n")
            reader = connection.makefile("rb")
            with reader:
                assert reader.readline().startswith(b"HTTP/1.1 200 ")
                headers = {}
                while (line := reader.readline()) != b"\r\n":
                    assert line, "response header EOF"
                    key, value = line.split(b":", 1)
                    headers[key.lower()] = value.strip()
                assert headers[b"content-length"] == b"64"
                assert reader.read(64) == b"a" * 64
        return record
    finally:
        child.terminate()
        child.wait(timeout=5)
        child.stdout.close()
        child.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mojo-server", required=True)
    parser.add_argument("--go-server", required=True)
    args = parser.parse_args()
    go = [args.go_server, "-addr", "127.0.0.1:18082", "-idle-timeout", "1h"]
    observations = {
        "mojo_child64": check([args.mojo_server], 18081, (64, 64), (64, 64)),
        "mojo_child_split": check([args.mojo_server], 18081, (32, 64), (32, 64)),
        "go_child64": check(go, 18082, (64, 64), (64, 64)),
        "go_runtime_adjusted": check(go, 18082, (32, 64), (63, 64)),
        "launcher_inherited": resource.getrlimit(resource.RLIMIT_NOFILE),
        "go_unconstrained": check(go, 18082, None, None),
    }
    print(json.dumps(observations))


if __name__ == "__main__":
    main()
