"""Exercise all HTTP ServerConfig receive pools through the Mojo/C boundary."""

import asyncio
import os
import ssl
import subprocess

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, HandshakeCompleted
from aioquic.quic.packet import QuicProtocolVersion


class PoolProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.handshake = asyncio.get_running_loop().create_future()
        self.closed = asyncio.get_running_loop().create_future()
        self.response = asyncio.get_running_loop().create_future()
        self.status = None
        self.body = bytearray()

    def quic_event_received(self, event):
        if isinstance(event, HandshakeCompleted) and not self.handshake.done():
            self.handshake.set_result(None)
        if isinstance(event, ConnectionTerminated) and not self.closed.done():
            self.closed.set_result(event.error_code)
        for http_event in self.http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                self.status = dict(http_event.headers).get(b":status")
            elif isinstance(http_event, DataReceived):
                self.body.extend(http_event.data)
                if http_event.stream_ended and not self.response.done():
                    self.response.set_result((self.status, bytes(self.body)))

    def get(self):
        stream = self._quic.get_next_available_stream_id()
        self.http.send_headers(stream, [
            (b":method", b"GET"), (b":scheme", b"https"),
            (b":authority", b"localhost"), (b":path", b"/alive"),
        ], end_stream=True)
        self.transmit()


async def check(address, mode):
    host, port = address.rsplit(":", 1)
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN,
                               server_name="localhost")
    config.supported_versions = [QuicProtocolVersion.VERSION_1]
    config.verify_mode = ssl.CERT_NONE
    async with connect(host, int(port), configuration=config,
                       create_protocol=PoolProtocol, wait_connected=False) as client:
        client.transmit()
        if mode in ("crypto_bytes", "crypto_slots"):
            try:
                await asyncio.wait_for(client.handshake, 0.3)
            except asyncio.TimeoutError:
                assert not client.closed.done(), "Initial rejection fabricated a close"
                return
            raise AssertionError("CRYPTO capacity should reject Initial")
        if mode in ("control_slots", "control_bytes"):
            expected = {"control_slots": 0x1, "control_bytes": 0x1}[mode]
            actual = await asyncio.wait_for(client.closed, 0.8)
            assert actual == expected, (mode, actual, expected)
            return
        await asyncio.wait_for(client.wait_connected(), 0.8)
        client.get()
        if mode == "default":
            assert await asyncio.wait_for(client.response, 0.8) == (b"200", b"alive")
        else:
            assert await asyncio.wait_for(client.closed, 0.8) == 0x1


def main():
    for mode in ("default", "request_bytes", "request_slots", "control_bytes",
                 "control_slots", "crypto_bytes", "crypto_slots"):
        env = dict(os.environ)
        env["HTTP3_RECEIVE_POOL"] = mode
        process = subprocess.Popen(["mojo", "run", "--Werror", "-I", ".",
                                    "tests/http3_receive_budget_fixture.mojo"], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env)
        try:
            ready = process.stdout.readline().strip()
            assert ready.startswith("READY "), (mode, ready, process.stderr.read())
            assert process.poll() is None, (mode, "fixture exited before readiness was observed")
            asyncio.run(check(ready.removeprefix("READY "), mode))
            out, err = process.communicate(timeout=3)
            assert process.returncode == 0, (mode, out, err)
            assert out.strip() == ("HANDLED 1" if mode == "default" else "HANDLED 0"), (mode, out)
            print(f"HTTP receive pool={mode}: pass")
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=3)


if __name__ == "__main__":
    main()
