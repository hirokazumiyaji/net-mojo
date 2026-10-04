"""Verify a full 1 MiB HTTP/3 echo and reuse with the normal aioquic sender."""

import argparse
import asyncio
import json
from pathlib import Path
import ssl
import sys
from urllib.parse import urlparse

from aioquic.asyncio import connect
from aioquic.h3.connection import H3_ALPN
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.packet import QuicProtocolVersion

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "benchmarks/http"))
from http3_scenarios import FIXED_BODY, ScenarioProtocol, _wait_alpn


async def check(url):
    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port
    authority = f"{host}:{port}".encode()
    configuration = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN, server_name="localhost"
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE
    body = bytes(range(256)) * 4096
    async with connect(
        host, port, configuration=configuration, create_protocol=ScenarioProtocol
    ) as client:
        await _wait_alpn(client)
        response = await client.post_echo(body, authority)
        assert response["status"] == b"200", response["status"]
        assert bytes(response["body"]) == body
        reused = await asyncio.wait_for(client.get(b"/fixed", authority), 10)
        assert reused["status"] == b"200", reused["status"]
        assert bytes(reused["body"]) == FIXED_BODY
        assert reused["stream_id"] > response["stream_id"]
        print(json.dumps({
            "verdict": "pass", "request_bytes": len(body),
            "response_bytes": len(response["body"]), "reuse_ok": True,
            "alpn": str(client.alpn),
        }))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    asyncio.run(check(parser.parse_args().url))
