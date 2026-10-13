"""Measure upload throughput and peak server RSS with independent HTTP clients."""

import argparse
import asyncio
import json
import os
import re
import signal
import ssl
import subprocess
import sys
import tempfile
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
CHUNK = b"a" * 65536
TRAILERS = [(b"x-result", b"done")]


def headers(path, size=None):
    values = [(b":method", b"POST" if size is not None else b"GET"), (b":scheme", b"https"), (b":authority", b"localhost"), (b":path", path.encode())]
    if size is not None:
        values.append((b"content-length", str(size).encode()))
    return values


async def h1_request(port, size=None):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        started = time.perf_counter()
        if size is None:
            writer.write(b"GET /shutdown HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        else:
            writer.write(b"POST /upload HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nTrailer: X-Result\r\nConnection: close\r\n\r\n")
            remaining = size
            while remaining:
                count = min(remaining, len(CHUNK))
                writer.write(f"{count:x}\r\n".encode() + CHUNK[:count] + b"\r\n")
                await writer.drain()
                remaining -= count
            writer.write(b"0\r\nX-Result: done\r\n\r\n")
        await writer.drain()
        wire = await reader.read()
        head, _, body = wire.partition(b"\r\n\r\n")
        if b" 200 " not in head.split(b"\r\n", 1)[0]:
            raise RuntimeError(f"HTTP/1 response: {head!r}")
        if size is not None and body != str(size).encode():
            raise RuntimeError(f"HTTP/1 byte count mismatch: {body!r}")
        return time.perf_counter() - started
    finally:
        writer.close()
        await writer.wait_closed()


async def h2_request(port, size=None):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE
    tls.set_alpn_protocols(["h2"])
    reader, writer = await asyncio.open_connection("127.0.0.1", port, ssl=tls)
    connection = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
    connection.initiate_connection()
    connection.send_headers(1, headers("/upload" if size is not None else "/shutdown", size), end_stream=size is None)
    expected = size
    trailers_sent = False
    remaining = size or 0
    body = bytearray()
    status = None
    finished = False
    started = time.perf_counter()
    try:
        while not finished:
            while remaining:
                count = min(remaining, connection.local_flow_control_window(1), connection.max_outbound_frame_size)
                if count == 0:
                    break
                connection.send_data(1, CHUNK[:count])
                remaining -= count
            if size is not None and remaining == 0 and not trailers_sent:
                connection.send_headers(1, TRAILERS, end_stream=True)
                trailers_sent = True
            writer.write(connection.data_to_send())
            await writer.drain()
            data = await reader.read(65536)
            if not data:
                raise RuntimeError("HTTP/2 closed before response")
            for event in connection.receive_data(data):
                if isinstance(event, h2.events.ResponseReceived):
                    status = dict(event.headers)[b":status"]
                elif isinstance(event, h2.events.DataReceived):
                    body.extend(event.data)
                    connection.acknowledge_received_data(event.flow_controlled_length, 1)
                elif isinstance(event, h2.events.StreamEnded):
                    finished = True
                elif isinstance(event, h2.events.ConnectionTerminated):
                    if expected is None and event.error_code == 0:
                        finished = True
                    else:
                        raise RuntimeError(f"HTTP/2 interrupted: {event}")
                elif isinstance(event, h2.events.StreamReset):
                    raise RuntimeError(f"HTTP/2 interrupted: {event}")
        if expected is not None and status != b"200":
            raise RuntimeError(f"HTTP/2 status: {status!r}")
        if expected is not None and body != str(expected).encode():
            raise RuntimeError(f"HTTP/2 byte count mismatch: {body!r}")
        return time.perf_counter() - started
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionError:
            if expected is not None:
                raise


class H3Upload(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.future = asyncio.get_running_loop().create_future()
        self.body = bytearray()
        self.status = None

    def quic_event_received(self, event):
        if isinstance(event, (StreamReset, ConnectionTerminated)):
            if not self.future.done():
                self.future.set_exception(RuntimeError(f"HTTP/3 interrupted: {event}"))
            return
        for value in self.http.handle_event(event):
            if isinstance(value, HeadersReceived):
                fields = dict(value.headers)
                if b":status" in fields:
                    self.status = fields[b":status"]
            elif isinstance(value, DataReceived):
                self.body.extend(value.data)
            if isinstance(value, (HeadersReceived, DataReceived)) and value.stream_ended and not self.future.done():
                self.future.set_result(bytes(self.body))

    async def request(self, size=None):
        stream = self._quic.get_next_available_stream_id()
        started = time.perf_counter()
        self.http.send_headers(stream, headers("/upload" if size is not None else "/shutdown", size), end_stream=size is None)
        self.transmit()
        remaining = size or 0
        while remaining and not self.future.done():
            sender = self._quic._streams[stream].sender
            # aioquic has no upload drain API; keep its unacknowledged buffer bounded.
            while sender._buffer_stop - sender._buffer_start >= 2 * len(CHUNK) and not self.future.done():
                self.transmit()
                await asyncio.sleep(0.001)
            if self.future.done():
                break
            count = min(remaining, len(CHUNK))
            self.http.send_data(stream, CHUNK[:count], end_stream=False)
            remaining -= count
            self.transmit()
            await asyncio.sleep(0)
        if size is not None and not self.future.done():
            self.http.send_headers(stream, TRAILERS, end_stream=True)
            self.transmit()
        body = await self.future
        if self.status != b"200":
            raise RuntimeError(f"HTTP/3 status: {self.status!r}")
        if size is not None and body != str(size).encode():
            raise RuntimeError(f"HTTP/3 byte count mismatch: {body!r}")
        return time.perf_counter() - started


async def h3_request(port, size=None):
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"], verify_mode=ssl.CERT_NONE)
    async with connect("127.0.0.1", port, configuration=config, create_protocol=H3Upload) as client:
        return await client.request(size)


CLIENTS = {"h1": h1_request, "h2": h2_request, "h3": h3_request}


def peak_rss(text):
    if sys.platform == "darwin":
        match = re.search(r"(\d+)\s+maximum resident set size", text)
        return int(match[1]) if match else None
    match = re.search(r"Maximum resident set size \(kbytes\):\s+(\d+)", text)
    return int(match[1]) * 1024 if match else None


async def measure(binary, protocol, mode, size):
    command = ["/usr/bin/time", "-l" if sys.platform == "darwin" else "-v", str(binary), protocol, mode, str(size)]
    result = {"protocol": protocol, "mode": mode, "body_bytes": size, "stream_queue_bytes": 65536 if mode == "streaming" else None, "client_chunk_bytes": len(CHUNK), "server_body_limit_bytes": 65536 if mode == "streaming" else size, "server_buffer_budget_bytes": 1024 * 1024 * 1024}
    with tempfile.TemporaryFile(mode="w+") as diagnostics:
        server = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=diagnostics, text=True, start_new_session=True)
        try:
            ready = await asyncio.wait_for(asyncio.to_thread(server.stdout.readline), 20)
            tag, address = ready.split()
            if tag != "READY":
                raise RuntimeError(f"server readiness: {ready!r}")
            port = int(address.rsplit(":", 1)[1])
            try:
                seconds = await asyncio.wait_for(CLIENTS[protocol](port, size), 120)
                result.update(outcome="completed", elapsed_seconds=seconds, throughput_mib_per_second=size / 1048576 / seconds, received_body_bytes=size)
            except Exception as error:
                result.update(outcome="failed", error=str(error))
            await asyncio.wait_for(CLIENTS[protocol](port), 10)
            code = await asyncio.wait_for(asyncio.to_thread(server.wait), 10)
            if code != 0:
                raise RuntimeError(f"server exit: {code}")
        except Exception as error:
            result.update(outcome="failed", error=str(error))
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                await asyncio.to_thread(server.wait)
            server.stdout.close()
            diagnostics.seek(0)
            diagnostic_text = diagnostics.read()
            result["peak_server_rss_bytes"] = peak_rss(diagnostic_text)
            if result["outcome"] == "failed":
                result["server_diagnostics"] = diagnostic_text[-1500:]
    print(json.dumps(result), flush=True)
    return result


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sizes-mib", nargs="+", type=int, default=[1, 16, 256])
    parser.add_argument("--protocols", nargs="+", choices=CLIENTS, default=list(CLIENTS))
    parser.add_argument("--modes", nargs="+", choices=["streaming", "buffered"], default=["streaming", "buffered"])
    parser.add_argument("--binary", type=Path)
    options = parser.parse_args()
    if any(size <= 0 for size in options.sizes_mib):
        parser.error("upload sizes must be positive")
    binary = options.binary or ROOT / "build/http_body_stream"
    if options.binary is None:
        binary.parent.mkdir(exist_ok=True)
        subprocess.run(["mojo", "build", "--Werror", "-I", ".", "benchmarks/http_body_stream.mojo", "-o", str(binary)], cwd=ROOT, check=True)
    results = []
    for protocol in options.protocols:
        for mode in options.modes:
            for size_mib in options.sizes_mib:
                results.append(await measure(binary, protocol, mode, size_mib * 1048576))
    if any(value["outcome"] != "completed" for value in results if value["mode"] == "streaming"):
        raise SystemExit("streaming upload benchmark did not complete")


if __name__ == "__main__":
    asyncio.run(main())
