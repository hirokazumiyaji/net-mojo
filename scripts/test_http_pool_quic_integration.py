#!/usr/bin/env python3
"""Proves QUIC ownership stays on worker zero with shared TCP workers."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
import os
import http.client
from pathlib import Path
import select
import ssl
import subprocess
import time

from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.packet import QuicProtocolVersion

from run_http3_example import _Http3Client


def h1_request(port: int) -> bytes:
    context = ssl.create_default_context(cafile="build/tls/test-cert.pem")
    context.set_alpn_protocols(["http/1.1"])
    client = http.client.HTTPSConnection("localhost", port, context=context, timeout=5)
    try:
        client.request("GET", "/", headers={"Connection": "close"})
        assert client.sock.selected_alpn_protocol() == "http/1.1"
        response = client.getresponse()
        assert response.status == 200, response.status
        return response.read()
    finally:
        client.close()


async def h3_request(port: int, path: str = "/") -> bytes:
    configuration = QuicConfiguration(is_client=True, alpn_protocols=["h3"], server_name="localhost")
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_REQUIRED
    configuration.load_verify_locations(cafile="build/tls/test-cert.pem")
    async with connect("127.0.0.1", port, configuration=configuration, create_protocol=_Http3Client) as client:
        response = await client.get(path)
        assert client.alpn == "h3", client.alpn
        assert (b":status", b"200") in response["headers"], response["headers"]
        return bytes(response["body"])


async def h3_batch(port: int) -> list[bytes]:
    return await asyncio.gather(*(h3_request(port) for _ in range(4)))


def exercise(binary: Path, quic_only: bool) -> None:
    env = dict(os.environ)
    env["POOL_QUIC_ONLY"] = "1" if quic_only else "0"
    proc = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    try:
        assert select.select([proc.stdout], [], [], 10)[0], "QUIC pool fixture did not start"
        ready = proc.stdout.readline().strip()
        assert ready.startswith("READY "), ready
        port = int(ready.split()[1])
        if quic_only:
            time.sleep(0.4)
        else:
            with ThreadPoolExecutor(max_workers=8) as executor:
                responses = list(executor.map(lambda _: h1_request(port), range(64)))
            assert set(responses) == {b"worker:0", b"worker:1"}, set(responses)
            for worker in range(2):
                print(f"worker {worker}: {responses.count(f'worker:{worker}'.encode())} TCP/TLS requests")
        responses = asyncio.run(h3_batch(port))
        assert responses == [b"worker:0"] * 4, responses
        print(f"QUIC-only={quic_only}: all {len(responses)} HTTP/3 responses came from worker 0")
        assert asyncio.run(h3_request(port, "/shutdown")) == b"bye"
        stdout, stderr = proc.communicate(timeout=10)
        assert proc.returncode == 0, stderr
        assert stdout.strip() == "EXIT", stdout
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate(timeout=5)


def main() -> None:
    binary = Path("build/http-pool/quic-integration")
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["mojo", "build", "--Werror", "-I", ".", "-Xlinker", "-ldl", "tests/http_pool_quic_integration_fixture.mojo", "-o", str(binary)],
        check=True, timeout=120,
    )
    exercise(binary, quic_only=False)
    exercise(binary, quic_only=True)
    print("Shared TCP and worker-zero HTTP/3 pool integration passed")


if __name__ == "__main__":
    main()
