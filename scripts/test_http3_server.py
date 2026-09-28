import asyncio
import ssl
import subprocess
import sys

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.buffer import Buffer
from aioquic.h3.connection import FrameType, H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, ProtocolNegotiated, StreamReset
from aioquic.quic.packet import QuicProtocolVersion


class Http3ClientProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = _Http3Connection(self._quic)
        self.responses = {}
        self.resets = {}
        self.terminated = self._loop.create_future()
        self.alpn = None
        self.dropped_datagrams = 0

    def transmit(self, drop_next_datagram=False):
        self._transmit_task = None
        dropped = False
        for data, address in self._quic.datagrams_to_send(now=self._loop.time()):
            if drop_next_datagram and not dropped:
                self.dropped_datagrams += 1
                dropped = True
                continue
            self._transport.sendto(data, address)

        timer_at = self._quic.get_timer()
        if self._timer is not None and self._timer_at != timer_at:
            self._timer.cancel()
            self._timer = None
        if self._timer is None and timer_at is not None:
            self._timer = self._loop.call_at(timer_at, self._handle_timer)
        self._timer_at = timer_at

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            self.alpn = event.alpn_protocol
        if isinstance(event, ConnectionTerminated) and not self.terminated.done():
            self.terminated.set_result(event.error_code)
        if isinstance(event, StreamReset) and event.stream_id in self.resets:
            self.resets[event.stream_id].set_result(event.error_code)
        for http_event in self.http.handle_event(event):
            response = self.responses.get(http_event.stream_id)
            if response is None:
                continue
            if isinstance(http_event, HeadersReceived):
                response["headers"].extend(http_event.headers)
            elif isinstance(http_event, DataReceived):
                response["body"].extend(http_event.data)
            if http_event.stream_ended:
                response["future"].set_result(response)

    async def post(self, body, trailers, drop_first_datagram=False):
        stream_id = self._quic.get_next_available_stream_id()
        future = self._loop.create_future()
        response = {"future": future, "headers": [], "body": bytearray()}
        self.responses[stream_id] = response
        self.http.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/echo?source=quic"),
                (b"content-length", str(len(body)).encode()),
            ],
            end_stream=False,
        )
        self.http.send_data(stream_id, body, end_stream=not trailers)
        if trailers:
            self.http.send_headers(
                stream_id, [(b"x-check", b"done")], end_stream=True
            )
        self.transmit(drop_next_datagram=drop_first_datagram)
        try:
            result = await asyncio.wait_for(future, timeout=10)
            result["stream_id"] = stream_id
            return result
        finally:
            self.responses.pop(stream_id, None)

    async def cancel_partial_post(self):
        stream_id = self._quic.get_next_available_stream_id()
        self.http.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/echo?source=quic"),
                (b"content-length", b"4"),
            ],
            end_stream=False,
        )
        self.http.send_data(stream_id, b"da", end_stream=False)
        self.transmit()
        self._quic.reset_stream(stream_id, error_code=0x10C)
        self.transmit()
        await asyncio.sleep(0.05)

    async def post_after_goaway(self):
        stream_id = self._quic.get_next_available_stream_id()
        future = self._loop.create_future()
        self.resets[stream_id] = future
        self.http.send_headers(
            stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/echo?source=quic"),
                (b"content-length", b"4"),
            ],
            end_stream=False,
        )
        self.http.send_data(stream_id, b"data", end_stream=True)
        self.transmit()
        try:
            return await asyncio.wait_for(future, timeout=3)
        finally:
            self.resets.pop(stream_id, None)


class _Http3Connection(H3Connection):
    def __init__(self, quic):
        super().__init__(quic)
        self.goaways = []
        self.goaway_event = asyncio.Event()

    def _handle_control_frame(self, frame_type, frame_data):
        if frame_type == FrameType.GOAWAY:
            self.goaways.append(Buffer(data=frame_data).pull_uint_var())
            self.goaway_event.set()
        super()._handle_control_frame(frame_type, frame_data)

    async def wait_for_goaways(self, count):
        while len(self.goaways) < count:
            self.goaway_event.clear()
            await self.goaway_event.wait()


async def run_client(address):
    host, port = address.rsplit(":", 1)
    configuration = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN,
        server_name="localhost",
    )
    configuration.supported_versions = [QuicProtocolVersion.VERSION_1]
    configuration.verify_mode = ssl.CERT_NONE
    async with connect(
        host,
        int(port),
        configuration=configuration,
        create_protocol=Http3ClientProtocol,
    ) as client:
        if client.alpn != "h3":
            raise RuntimeError(f"unexpected negotiated ALPN: {client.alpn!r}")
        await client.cancel_partial_post()
        first = await client.post(
            b"data", trailers=True, drop_first_datagram=True
        )
        second = await client.post(b"data", trailers=False)
        if client.dropped_datagrams != 1:
            raise RuntimeError(
                f"expected one dropped client datagram, got {client.dropped_datagrams}"
            )
        for response, expected_body in (
            (first, b"handled:data:done"),
            (second, b"handled:data"),
        ):
            if (b":status", b"200") not in response["headers"]:
                raise RuntimeError(f"unexpected HTTP/3 response headers: {response}")
            if bytes(response["body"]) != expected_body:
                raise RuntimeError(f"unexpected HTTP/3 response body: {response}")
        await asyncio.wait_for(client.http.wait_for_goaways(2), timeout=5)
        expected_goaways = [(1 << 62) - 4, second["stream_id"]]
        if client.http.goaways != expected_goaways:
            raise RuntimeError(
                f"unexpected HTTP/3 GOAWAY IDs: {client.http.goaways}"
            )
        reset_code = await client.post_after_goaway()
        if reset_code != 0x10B:
            raise RuntimeError(
                f"expected H3_REQUEST_REJECTED after GOAWAY, got {reset_code}"
            )
        close_code = await asyncio.wait_for(client.terminated, timeout=5)
        if close_code != 0x100:
            raise RuntimeError(f"expected H3_NO_ERROR close, got {close_code}")


process = subprocess.Popen(
    ["mojo", "run", "--Werror", "-I", ".", "tests/http3_server_fixture.mojo"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

try:
    ready = process.stdout.readline().strip()
    if not ready.startswith("READY "):
        details = process.stderr.read()
        raise RuntimeError(f"HTTP/3 fixture did not start: {ready}\n{details}")
    asyncio.run(run_client(ready.removeprefix("READY ")))
    process.wait(timeout=5)
    if process.returncode != 0:
        raise RuntimeError(f"HTTP/3 fixture exited with {process.returncode}")
    print("Independent aioquic HTTP/3 client roundtrips succeeded")
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    details = process.stderr.read()
    if process.returncode != 0 and details:
        print(details, file=sys.stderr, end="")
