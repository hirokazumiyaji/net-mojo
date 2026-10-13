import asyncio
import os
import ssl
import subprocess
from pathlib import Path
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.events import StreamReset


class ResponseConnection(H3Connection):
    def __init__(self, quic):
        super().__init__(quic)
        self.head_streams = set()

    def _check_content_length(self, stream):
        if stream.stream_id not in self.head_streams:
            super()._check_content_length(stream)


class Http3ClientProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = ResponseConnection(self._quic)
        self.responses = {}
        self.resets = {}
        self.withheld = set()
        write_limits = self._quic._write_stream_limits

        def stream_limits(builder, space, stream):
            if stream.stream_id not in self.withheld:
                write_limits(builder, space, stream)

        self._quic._write_stream_limits = stream_limits

    def quic_event_received(self, event):
        if isinstance(event, StreamReset) and event.stream_id in self.resets:
            future = self.resets[event.stream_id]
            if not future.done():
                future.set_result(event.error_code)
        for item in self.http.handle_event(event):
            response = self.responses.get(item.stream_id)
            if response is None:
                continue
            if isinstance(item, HeadersReceived):
                response["headers"].extend(item.headers)
            elif isinstance(item, DataReceived):
                response["body"].extend(item.data)
            if item.stream_ended and not response["future"].done():
                response["future"].set_result(response)


ROOT = Path(__file__).resolve().parents[1]


class Client(Http3ClientProtocol):
    def begin(self, path, method=b"GET"):
        stream = self._quic.get_next_available_stream_id()
        if method == b"HEAD":
            self.http.head_streams.add(stream)
        response = {
            "future": self._loop.create_future(),
            "headers": [],
            "body": bytearray(),
        }
        self.responses[stream] = response
        self.resets[stream] = self._loop.create_future()
        self.http.send_headers(
            stream,
            [
                (b":method", method),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", path.encode()),
            ],
            end_stream=True,
        )
        self.transmit()
        return stream, response

    async def get(self, path, method=b"GET"):
        stream, response = self.begin(path, method)
        result = await asyncio.wait_for(response["future"], 5)
        status = (
            b"201"
            if path == "/deferred"
            else b"204"
            if path in ("/detached-no-body", "/detached-header-edge-204")
            else b"500"
            if path in ("/detached-too-large", "/detached-forbidden")
            else b"200"
        )
        assert (b":status", status) in result["headers"], result
        return result


async def run(port):
    config = QuicConfiguration(
        is_client=True,
        alpn_protocols=["h3"],
        verify_mode=ssl.CERT_NONE,
        max_data=64 * 1024 * 1024,
        max_stream_data=65535,
    )
    async with connect(
        "127.0.0.1", port, configuration=config, create_protocol=Client
    ) as client:
        deferred, sibling = await asyncio.gather(
            client.get("/deferred"), client.get("/alive")
        )
        assert deferred["body"] == b"deferred ok", deferred
        assert sibling["body"] == b"ok", sibling
        for path in ("/detached-stream", "/detached-trailers"):
            response = await client.get(path)
            assert response["body"] == b"".join(
                bytes([97 + i % 26]) * 4096 for i in range(40)
            ), len(response["body"])
            if path.endswith("trailers"):
                assert (b"x-digest", b"done") in response["headers"], response[
                    "headers"
                ]
        blocked, response = client.begin("/detached-stream")
        client.withheld.add(blocked)
        before = int((await client.get("/queue-count"))["body"])
        await asyncio.sleep(0.15)
        assert not response["future"].done() and not client.resets[blocked].done()
        assert int((await client.get("/queue-count"))["body"]) > before
        await client.get("/alive")
        client.withheld.remove(blocked)
        client.transmit()
        result = await asyncio.wait_for(response["future"], 3)
        expected = b"".join(bytes([97 + i % 26]) * 4096 for i in range(40))
        assert result["body"] == expected, "partial stream body lost or reordered"
        continuous, response = client.begin("/detached-continuous")
        await asyncio.sleep(0.6)
        assert not response["future"].done() and not client.resets[continuous].done()
        await client.get("/finish-continuous")
        await asyncio.wait_for(response["future"], 3)
        assert len(response["body"]) > 1024 * 1024, len(response["body"])
        for path in ("/deferred", "/detached-stream", "/detached-trailers"):
            response = await client.get(path, b"HEAD")
            assert not response["body"], response
        stream, response = client.begin("/idle-detached", b"HEAD")
        await asyncio.sleep(0.1)
        assert not response["future"].done(), "HEAD ended before producer finish"
        assert await asyncio.wait_for(client.resets[stream], 2) == 0x10C
        await client.get("/alive")
        await client.get("/detached-header-edge")
        await client.get("/detached-header-edge", b"HEAD")
        await client.get("/detached-header-edge-204")
        assert not (await client.get("/detached-no-body"))["body"]
        overflow, response = client.begin("/detached-trailer-overflow")
        assert await asyncio.wait_for(client.resets[overflow], 2) == 0x102
        await client.get("/detached-trailer-overflow", b"HEAD")
        await client.get("/alive")
        await client.get("/detached-forbidden")
        await client.get("/detached-too-large")
        await asyncio.sleep(0.05)
        assert (await client.get("/fallback-cancel-count"))["body"] == b"2"
        before = int((await client.get("/cancel-count"))["body"])
        deferred, pending = client.begin("/deferred-idle")
        await asyncio.sleep(0.02)
        client._quic.stop_stream(deferred, error_code=0x10C)
        client.transmit()
        assert await asyncio.wait_for(client.resets[deferred], 2) == 0x10C
        await asyncio.sleep(0.05)
        assert int((await client.get("/cancel-count"))["body"]) > before
        before = int((await client.get("/cancel-count"))["body"])
        stopped, pending = client.begin("/detached-hold")
        deadline = asyncio.get_running_loop().time() + 2
        while not pending["body"] and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.01)
        assert pending["body"], "no response body before STOP_SENDING"
        client._quic.stop_stream(stopped, error_code=0x10C)
        client.transmit()
        assert await asyncio.wait_for(client.resets[stopped], 2) == 0x10C
        await asyncio.sleep(0.05)
        assert int((await client.get("/cancel-count"))["body"]) > before
        await client.get("/alive")
        await client.get("/shutdown")


def main():
    fixture = (
        [os.environ["HTTP3_DETACH_BINARY"]]
        if "HTTP3_DETACH_BINARY" in os.environ
        else ["mojo", "run", "--Werror", "-I", ".", "tests/http3_detach_fixture.mojo"]
    )
    proc = subprocess.Popen(fixture, cwd=ROOT, stdout=subprocess.PIPE, text=True)
    try:
        ready = proc.stdout.readline().strip()
        assert ready.startswith("READY "), ready
        asyncio.run(run(int(ready.rsplit(":", 1)[1])))
        assert proc.wait(timeout=10) == 0
        print("HTTP/3 detached server scenarios passed")
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    main()
