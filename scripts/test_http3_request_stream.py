import argparse
import asyncio
import ssl
import subprocess
from pathlib import Path

import pylsqpack
from aioquic.h3.connection import FrameType, HeadersState, encode_frame
from aioquic.h3.events import HeadersReceived
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration
from test_http3_detach import Http3ClientProtocol, ResponseConnection

ROOT = Path(__file__).resolve().parents[1]


class InformationalConnection(ResponseConnection):
    def _handle_request_or_push_frame(self, frame_type, frame_data, stream, stream_ended):
        events = super()._handle_request_or_push_frame(frame_type, frame_data, stream, stream_ended)
        for event in events:
            if isinstance(event, HeadersReceived) and (b":status", b"100") in event.headers:
                assert not event.stream_ended
                # Keep informational sections separate from final response headers.
                stream.headers_recv_state = HeadersState.INITIAL
        return events


class Client(Http3ClientProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = InformationalConnection(self._quic)

    def begin(self, path, upload=False, headers=()):
        stream = self._quic.get_next_available_stream_id()
        response = {"future": self._loop.create_future(), "headers": [], "body": bytearray()}
        self.responses[stream] = response
        self.resets[stream] = self._loop.create_future()
        self.http.send_headers(stream, [(b":method", b"POST" if upload else b"GET"),
            (b":scheme", b"https"), (b":authority", b"localhost"),
            (b":path", path.encode()), *headers], end_stream=not upload)
        self.transmit()
        return stream, response

    async def get(self, path):
        _, response = self.begin(path)
        return (await asyncio.wait_for(response["future"], 5))["body"]

    async def wait_value(self, path, expected):
        deadline = self._loop.time() + 5
        while self._loop.time() < deadline:
            if await self.get(path) == expected:
                return
            await asyncio.sleep(0.01)
        raise AssertionError((path, expected))


async def run(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    async with connect("127.0.0.1", port, configuration=config,
                       create_protocol=Client) as client:
        stream, response = client.begin("/upload", True, [
            (b"content-length", b"1048576"), (b"expect", b"100-continue")])
        await client.wait_value("/calls", b"1")
        deadline = client._loop.time() + 0.4
        while (b":status", b"100") not in response["headers"]:
            assert client._loop.time() < deadline, response
            await asyncio.sleep(0.005)
        assert not response["future"].done()
        for offset in range(0, 1048576, 16384):
            client.http.send_data(stream, b"a" * 16384, end_stream=False)
            client.transmit()
            if offset % 65536 == 0:
                await asyncio.sleep(0.005)
        client.http.send_headers(stream, [(b"x-finish", b"yes")], end_stream=True)
        client.transmit()
        result = await asyncio.wait_for(response["future"], 10)
        assert result["body"] == b"1048576:yes", result
        assert [value for name, value in result["headers"] if name == b":status"] == [b"100", b"200"]
        stream, response = client.begin("/upload", True)
        await client.wait_value("/calls", b"2")
        client.http.send_data(stream, b"a" * 100, end_stream=False)
        client.transmit()
        await client.wait_value("/bytes", b"100")
        client._quic.reset_stream(stream, error_code=0x10C)
        client.transmit()
        await client.wait_value("/cancelled", b"1")
        assert await client.get("/calls") == b"2"
        assert await client.get("/pause") == b"paused"
        held, pending = client.begin("/upload", True)
        await client.wait_value("/calls", b"3")
        client.http.send_data(held, b"a" * 65536, end_stream=True)
        client.transmit()
        await asyncio.sleep(0.15)
        assert await client.get("/bytes") == b"0"
        assert not pending["future"].done()
        assert await client.get("/resume") == b"resumed"
        assert (await asyncio.wait_for(pending["future"], 5))["body"] == b"65536:none"
        early, response = client.begin("/early", True)
        await client.wait_value("/calls", b"4")
        assert (await asyncio.wait_for(response["future"], 5))["body"] == b"early"
        before = int(await client.get("/done"))
        client.http.send_data(early, b"a" * 16384, end_stream=True)
        client.transmit()
        await client.wait_value("/done", str(before + 1).encode())
        assert await client.get("/bytes") == b"16384"
        standalone, response = client.begin("/standalone", True)
        await client.wait_value("/calls", b"5")
        assert (await asyncio.wait_for(response["future"], 5))["body"] == b"early"
        before = int(await client.get("/done"))
        client.http.send_data(standalone, b"a" * 8192, end_stream=True)
        client.transmit()
        await client.wait_value("/done", str(before + 1).encode())
        assert await client.get("/bytes") == b"8192"
        ignored, response = client.begin("/ignored", True)
        assert (await asyncio.wait_for(response["future"], 5))["body"] == b"ignored"
        _, response = client.begin("/ignored", headers=[(b"expect", b"100-continue")])
        result = await asyncio.wait_for(response["future"], 5)
        assert [value for name, value in result["headers"] if name == b":status"] == [b"200"]
        bad, response = client.begin("/upload", True, [(b"expect", b"other")])
        rejected = await asyncio.wait_for(response["future"], 5)
        assert (b":status", b"417") in rejected["headers"], rejected
        assert await client.get("/calls") == b"5"
        for _ in range(5):
            stream, response = client.begin("/detached-only", True)
            client.http.send_data(stream, b"a" * 1024, end_stream=True)
            client.transmit()
            assert (await asyncio.wait_for(response["future"], 2))["body"] == b"detached"
        await client.wait_value("/inputs", b"0")
        overflow, response = client.begin("/upload", True)
        await client.wait_value("/calls", b"6")
        client.http.send_data(overflow, b"a" * 100, end_stream=False)
        fields = [(b"x-finish", b"yes"), *[(f"x-budget-{i}".encode(), b"x" * 2048) for i in range(10)]]
        encoder = pylsqpack.Encoder()
        encoder.apply_settings(0, 0)
        block = b"\0\0"
        for field in fields:
            _, encoded = encoder.encode(overflow, [field])
            assert encoded[:2] == b"\0\0"
            block += encoded[2:]
        client._quic.send_stream_data(overflow, encode_frame(FrameType.HEADERS, block), end_stream=True)
        client.transmit()
        await client.wait_value("/cancelled", b"2")
        assert await client.get("/calls") == b"6"
        idle, response = client.begin("/upload", True)
        await client.wait_value("/calls", b"7")
        await client.wait_value("/cancelled", b"3")
        assert await asyncio.wait_for(client.resets[idle], 2) == 0x10C
        shutdown, response = client.begin("/upload", True)
        await client.wait_value("/calls", b"8")
        assert await client.get("/shutdown") == b"shutdown"
        client.http.send_data(shutdown, b"a" * 4096, end_stream=True)
        client.transmit()
        assert (await asyncio.wait_for(response["future"], 3))["body"] == b"4096:none"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture")
    args = parser.parse_args()
    command = [args.fixture] if args.fixture else ["mojo", "run", "--Werror", "-I", ".", "tests/http3_request_stream_fixture.mojo"]
    proc = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, text=True)
    try:
        ready = proc.stdout.readline().strip()
        assert ready.startswith("READY "), ready
        asyncio.run(run(int(ready.rsplit(":", 1)[1])))
        assert proc.wait(timeout=10) == 0
        print("HTTP/3 request streaming scenarios passed")
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    main()
