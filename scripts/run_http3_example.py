import asyncio
import os
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


async def _run_client(port):
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        server_name="localhost",
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE
    async with connect(
        "127.0.0.1",
        port,
        configuration=configuration,
        create_protocol=_Http3Client,
    ) as client:
        response = await client.get()
        if client.alpn != "h3":
            raise RuntimeError(
                f"http3_hello ALPN mismatch: {client.alpn!r}"
            )
        if (b":status", b"200") not in response["headers"]:
            raise RuntimeError(
                f"http3_hello unexpected headers: {response['headers']}"
            )
        if bytes(response["body"]) != b"hello over http/3":
            raise RuntimeError(
                f"http3_hello unexpected body: {bytes(response['body'])!r}"
            )


def _wait_ready(process):
    ready = process.stdout.readline().strip()
    if not ready.startswith("READY "):
        raise RuntimeError(
            f"http3_hello example did not start: {ready}\n"
            f"{process.stderr.read()}"
        )
    return int(ready.split()[1])


def main():
    env = dict(os.environ)
    env["HELLO_ADDRESS"] = "127.0.0.1:0"
    process = subprocess.Popen(
        ["mojo", "run", "--Werror", "-I", ".", "examples/http3_hello.mojo"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        port = _wait_ready(process)
        asyncio.run(_run_client(port))
        print("http3_hello example roundtrip succeeded")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process.returncode not in (0, -15, 143):
            sys.stderr.write(process.stderr.read())
            raise RuntimeError(
                f"http3_hello exited with {process.returncode}"
            )


main()
