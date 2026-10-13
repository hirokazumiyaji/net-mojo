"""Measure detached SSE delivery on 100 multiplexed HTTP/2 and HTTP/3 streams."""

import asyncio
import json
import math
import ssl
import subprocess
import time
from pathlib import Path

import h2.config
import h2.connection
import h2.events
from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, StreamReset

ROOT = Path(__file__).resolve().parents[1]
STREAMS = 100
EVENTS = 1000


def clock_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


class Response:
    def __init__(self, path):
        self.path = path
        self.sent = clock_ns()
        self.ttfb = None
        self.pending = bytearray()
        self.latencies = []
        self.future = asyncio.get_running_loop().create_future()

    def headers(self, headers):
        assert (b":status", b"200") in headers, headers
        if self.ttfb is None:
            self.ttfb = clock_ns() - self.sent

    def data(self, data):
        received = clock_ns()
        self.pending.extend(data)
        if self.path != "/events":
            return
        while b"\n\n" in self.pending:
            event, _, remaining = self.pending.partition(b"\n\n")
            self.pending = bytearray(remaining)
            prefix, sequence, planned = event.split()
            assert prefix == b"data:" and int(sequence) == len(self.latencies), event
            latency = received - int(planned)
            assert latency >= 0, "producer and receiver clocks differ"
            self.latencies.append(latency)

    def finish(self):
        if self.path == "/events":
            assert len(self.latencies) == EVENTS, len(self.latencies)
            assert not self.pending, self.pending
        elif self.path == "/clock":
            assert self.sent <= int(self.pending) <= clock_ns(), "Mojo and Python monotonic clock epochs differ"
        assert self.ttfb is not None, "missing response headers"
        self.future.set_result(self)


class H2Client:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.http = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
        self.responses = {}
        self.http.initiate_connection()
        self.writer.write(self.http.data_to_send())
        self.task = asyncio.create_task(self.read())

    def begin(self, path):
        stream = self.http.get_next_available_stream_id()
        response = Response(path)
        self.responses[stream] = response
        self.http.send_headers(stream, [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", b"localhost"), (b":path", path.encode())], end_stream=True)
        self.writer.write(self.http.data_to_send())
        return response

    async def read(self):
        try:
            while data := await self.reader.read(65536):
                for event in self.http.receive_data(data):
                    if isinstance(event, h2.events.ResponseReceived):
                        self.responses[event.stream_id].headers(event.headers)
                    elif isinstance(event, h2.events.DataReceived):
                        self.responses[event.stream_id].data(event.data)
                        self.http.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, h2.events.StreamEnded):
                        self.responses[event.stream_id].finish()
                    elif isinstance(event, (h2.events.StreamReset, h2.events.ConnectionTerminated)):
                        raise RuntimeError(f"HTTP/2 benchmark interrupted: {event}")
                self.writer.write(self.http.data_to_send())
                await self.writer.drain()
            raise RuntimeError("HTTP/2 connection closed before benchmark completed")
        except Exception as error:
            for response in self.responses.values():
                if not response.future.done():
                    response.future.set_exception(error)

    async def close(self):
        self.task.cancel()
        await asyncio.gather(self.task, return_exceptions=True)
        self.writer.close()
        await self.writer.wait_closed()


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.responses = {}

    def begin(self, path):
        stream = self._quic.get_next_available_stream_id()
        response = Response(path)
        self.responses[stream] = response
        self.http.send_headers(stream, [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", b"localhost"), (b":path", path.encode())], end_stream=True)
        self.transmit()
        return response

    def quic_event_received(self, event):
        try:
            if isinstance(event, (StreamReset, ConnectionTerminated)):
                raise RuntimeError(f"HTTP/3 benchmark interrupted: {event}")
            for item in self.http.handle_event(event):
                response = self.responses[item.stream_id]
                if isinstance(item, HeadersReceived):
                    response.headers(item.headers)
                elif isinstance(item, DataReceived):
                    response.data(item.data)
                if item.stream_ended:
                    response.finish()
        except Exception as error:
            for response in self.responses.values():
                if not response.future.done():
                    response.future.set_exception(error)


def p99(values):
    return sorted(values)[math.ceil(len(values) * 0.99) - 1] / 1_000_000


async def measure(client, protocol):
    await asyncio.wait_for(client.begin("/clock").future, 10)
    started = clock_ns()
    responses = [client.begin("/events") for _ in range(STREAMS)]
    await asyncio.wait_for(asyncio.gather(*(response.future for response in responses)), 30)
    seconds = (clock_ns() - started) / 1_000_000_000
    latencies = [value for response in responses for value in response.latencies]
    print(json.dumps({"protocol": protocol, "streams": STREAMS, "events_per_stream": EVENTS, "target_events_per_second_per_stream": 1000, "events_received": len(latencies), "elapsed_seconds": seconds, "events_per_second": len(latencies) / seconds, "p99_ttfb_ms": p99([response.ttfb for response in responses]), "p99_event_latency_ms": p99(latencies)}), flush=True)


async def run(tcp_port, udp_port):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE
    tls.set_alpn_protocols(["h2"])
    reader, writer = await asyncio.open_connection("127.0.0.1", tcp_port, ssl=tls)
    assert writer.get_extra_info("ssl_object").selected_alpn_protocol() == "h2"
    client = H2Client(reader, writer)
    try:
        await measure(client, "h2")
    finally:
        await client.close()
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"], verify_mode=ssl.CERT_NONE, max_data=64 * 1024 * 1024, max_stream_data=65535)
    async with connect("127.0.0.1", udp_port, configuration=config, create_protocol=H3Client) as client:
        await measure(client, "h3")
        await asyncio.wait_for(client.begin("/shutdown").future, 10)


async def main():
    binary = ROOT / "build/http_stream_sse"
    subprocess.run(["mojo", "build", "--Werror", "-I", ".", "benchmarks/http_stream_sse.mojo", "-o", str(binary)], cwd=ROOT, check=True)
    with subprocess.Popen([str(binary)], cwd=ROOT, stdout=subprocess.PIPE, text=True) as server:
        try:
            ready = await asyncio.wait_for(asyncio.to_thread(server.stdout.readline), 20)
            tag, tcp, udp = ready.split()
            assert tag == "READY", ready
            await run(int(tcp.rsplit(":", 1)[1]), int(udp.rsplit(":", 1)[1]))
            code = await asyncio.wait_for(asyncio.to_thread(server.wait), 10)
            assert code == 0, code
        finally:
            if server.poll() is None:
                server.kill()
                server.wait()


if __name__ == "__main__":
    asyncio.run(main())
