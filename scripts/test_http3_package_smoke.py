import asyncio
import ssl
import subprocess
import sys

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated
from aioquic.quic.packet import QuicProtocolVersion


class _Http3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.response = {
            "future": self._loop.create_future(),
            "headers": [],
            "body": bytearray(),
        }
        self.stream_id = None
        self.alpn = None

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            self.alpn = event.alpn_protocol
        for http_event in self.http.handle_event(event):
            if http_event.stream_id != self.stream_id:
                continue
            if isinstance(http_event, HeadersReceived):
                self.response["headers"].extend(http_event.headers)
            elif isinstance(http_event, DataReceived):
                self.response["body"].extend(http_event.data)
            if http_event.stream_ended and not self.response["future"].done():
                self.response["future"].set_result(self.response)

    async def get(self):
        self.stream_id = self._quic.get_next_available_stream_id()
        self.http.send_headers(
            self.stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/"),
            ],
            end_stream=True,
        )
        self.transmit()
        return await asyncio.wait_for(self.response["future"], timeout=10)


async def _run_client(address):
    host, port = address.rsplit(":", 1)
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        server_name="localhost",
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE
    async with connect(
        host,
        int(port),
        configuration=configuration,
        create_protocol=_Http3Client,
    ) as client:
        response = await client.get()
        if client.alpn != "h3":
            raise RuntimeError(
                f"packaged HTTP/3 ALPN mismatch: {client.alpn!r}"
            )
        if (b":status", b"200") not in response["headers"]:
            raise RuntimeError(
                f"packaged HTTP/3 unexpected headers: {response['headers']}"
            )
        if bytes(response["body"]) != b"packaged http/3 ok":
            raise RuntimeError(
                f"packaged HTTP/3 unexpected body: {bytes(response['body'])!r}"
            )


def main():
    process = subprocess.Popen(
        [
            "mojo",
            "run",
            "--Werror",
            "-I",
            "build",
            "tests/http3_package_smoke.mojo",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(
                f"packaged HTTP/3 fixture did not start: {ready}\n"
                f"{process.stderr.read()}"
            )
        asyncio.run(_run_client(ready.removeprefix("READY ")))
        process.wait(timeout=10)
        if process.returncode != 0:
            raise RuntimeError(process.stderr.read())
        print("packaged HTTP/3 provider roundtrip succeeded")
    except Exception:
        process.kill()
        process.wait()
        sys.stderr.write(process.stderr.read())
        raise


main()
