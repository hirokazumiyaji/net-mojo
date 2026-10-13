"""Smoke test the long-running example through independent HTTP requests."""

import http.client
import os
import pathlib
import socket
import subprocess
import time


root = pathlib.Path(__file__).resolve().parents[1]
with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]
environment = dict(os.environ, DOGFOOD_ADDRESS=f"127.0.0.1:{port}")
process = subprocess.Popen([str(root / "build/http-dogfood")], env=environment)


def request(method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(method, path, body)
        response = connection.getresponse()
        return response.status, response.getheader("Content-Type"), response.read()
    finally:
        connection.close()


try:
    deadline = time.monotonic() + 10
    while True:
        if process.poll() is not None:
            raise RuntimeError(f"dogfood exited with {process.returncode}")
        try:
            status, media_type, body = request("GET", "/json")
            break
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.02)
    assert status == 200 and media_type == "application/json"
    assert body == b'{"message":"hello, mojo http json","ok":true}'
    assert request("POST", "/echo", b"dogfood\x00payload")[2] == b"dogfood\x00payload"
    assert request("GET", "/missing")[0] == 404
    assert request("HEAD", "/json")[2] == b""
    status, media_type, body = request("GET", "/metrics")
    assert status == 200 and media_type == "text/plain; version=0.0.4"
    metrics = dict(line.split() for line in body.decode().splitlines() if not line.startswith("#"))
    first_uptime = int(metrics["net_mojo_uptime_seconds"])
    assert int(metrics["net_mojo_requests_total"]) == 5
    time.sleep(1.1)
    body = request("GET", "/metrics")[2]
    metrics = dict(line.split() for line in body.decode().splitlines() if not line.startswith("#"))
    assert int(metrics["net_mojo_uptime_seconds"]) > first_uptime
    assert int(metrics["net_mojo_requests_total"]) == 6
    assert process.poll() is None
    print("Dogfood HTTP/metrics smoke: PASS")
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
