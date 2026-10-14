"""Verify opt-in gzip bytes and metadata with independent HTTP clients."""

import asyncio
import gzip
import ssl
import subprocess
from pathlib import Path

import h2.config
import h2.connection
import h2.events
from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

ROOT = Path(__file__).resolve().parents[1]


class HeadAwareH3Connection(H3Connection):
    def __init__(self, quic):
        super().__init__(quic)
        self.head_streams = set()

    def _check_content_length(self, stream):
        # HEAD lengths describe the identity representation rather than DATA.
        if stream.stream_id not in self.head_streams:
            super()._check_content_length(stream)


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = HeadAwareH3Connection(self._quic)
        self.responses = {}

    async def request(self, path, method="GET", encoding="gzip"):
        stream = self._quic.get_next_available_stream_id()
        result = [[], bytearray(), asyncio.get_running_loop().create_future()]
        self.responses[stream] = result
        if method == "HEAD":
            self.http.head_streams.add(stream)
        self.http.send_headers(stream, request_headers(path, method, encoding), end_stream=True)
        self.transmit()
        try:
            return await asyncio.wait_for(result[2], 10)
        except TimeoutError as error:
            raise AssertionError(f"HTTP/3 {method} {path} timed out; headers={result[0]} bytes={len(result[1])}") from error

    def quic_event_received(self, event):
        for item in self.http.handle_event(event):
            result = self.responses[item.stream_id]
            if isinstance(item, HeadersReceived):
                result[0].extend(item.headers)
            elif isinstance(item, DataReceived):
                result[1].extend(item.data)
            if item.stream_ended:
                result[2].set_result((result[0], bytes(result[1])))


def request_headers(path, method, encoding):
    return [(b":method", method.encode()), (b":scheme", b"https"), (b":authority", b"localhost"), (b":path", path.encode()), (b"accept-encoding", encoding.encode())]


def tls_context(protocol):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols([protocol])
    return context


async def h2_request(port, path, method="GET", encoding="gzip"):
    reader, writer = await asyncio.open_connection("127.0.0.1", port, ssl=tls_context("h2"))
    assert writer.get_extra_info("ssl_object").selected_alpn_protocol() == "h2"
    http = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
    http.initiate_connection()
    http.send_headers(1, request_headers(path, method, encoding), end_stream=True)
    writer.write(http.data_to_send())
    headers, body = [], bytearray()
    try:
        while True:
            data = await asyncio.wait_for(reader.read(65536), 10)
            assert data, "HTTP/2 closed before END_STREAM"
            ended = False
            for event in http.receive_data(data):
                if isinstance(event, (h2.events.ResponseReceived, h2.events.TrailersReceived)):
                    headers.extend(event.headers)
                elif isinstance(event, h2.events.DataReceived):
                    body.extend(event.data)
                    http.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded):
                    ended = True
                elif isinstance(event, h2.events.StreamReset):
                    raise AssertionError(event)
            writer.write(http.data_to_send())
            await writer.drain()
            if ended:
                return headers, bytes(body)
    finally:
        writer.close()
        await writer.wait_closed()


async def h1_request(port, path, method="GET", encoding="gzip"):
    reader, writer = await asyncio.open_connection("127.0.0.1", port, ssl=tls_context("http/1.1"))
    assert writer.get_extra_info("ssl_object").selected_alpn_protocol() == "http/1.1"
    writer.write(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: {encoding}\r\nConnection: close\r\n\r\n".encode())
    await writer.drain()
    try:
        raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        lines = raw.split(b"\r\n")
        headers = [(b":status", lines[0].split()[1])]
        headers.extend((name.lower(), value.strip()) for name, value in (line.split(b":", 1) for line in lines[1:] if line))
        fields = dict(headers)
        body = bytearray()
        if method == "HEAD" or fields[b":status"] == b"204":
            return headers, b""
        if fields.get(b"transfer-encoding") == b"chunked":
            while True:
                count = int((await reader.readline()).strip(), 16)
                if count == 0:
                    while line := (await reader.readline()).strip():
                        name, value = line.split(b":", 1)
                        headers.append((name.lower(), value.strip()))
                    break
                body.extend(await reader.readexactly(count))
                assert await reader.readexactly(2) == b"\r\n"
        elif b"content-length" in fields:
            body.extend(await reader.readexactly(int(fields[b"content-length"])))
        else:
            body.extend(await reader.read())
        return headers, bytes(body)
    finally:
        writer.close()
        await writer.wait_closed()


async def verify(request):
    compressed = []
    for path in ("/gzip", "/length", "/trailers"):
        headers, body = await request(path)
        fields = dict(headers)
        assert fields[b":status"] == b"200", headers
        assert fields[b"content-encoding"] == b"gzip", headers
        assert gzip.decompress(body) == b"A" * 4096
        if b"content-length" in fields:
            assert int(fields[b"content-length"]) == len(body)
        assert b"accept-encoding" in b",".join(v.lower() for k, v in headers if k == b"vary")
        assert b"origin" in b",".join(v.lower() for k, v in headers if k == b"vary")
        if path == "/trailers":
            assert fields[b"x-digest"] == b"ok", headers
        compressed.append(body)
    for path, method, encoding, status, length in (("/gzip", "GET", "gzip;q=0", b"200", 4096), ("/head", "HEAD", "gzip", b"200", 0), ("/empty", "GET", "gzip", b"204", 0), ("/small", "GET", "gzip", b"200", 4), ("/partial", "GET", "gzip", b"206", 4096), ("/mime", "GET", "gzip", b"200", 4096), ("/file.gz", "GET", "gzip", b"200", 4096)):
        headers, body = await request(path, method, encoding)
        fields = dict(headers)
        assert fields[b":status"] == status, headers
        assert b"content-encoding" not in fields, headers
        assert body == b"A" * length, (path, len(body))
        if method == "HEAD":
            assert fields[b"content-length"] == b"4096", headers
    headers, body = await request("/encoded")
    assert dict(headers)[b"content-encoding"] == b"br" and body == b"A" * 4096
    headers, body = await request("/expansion")
    assert dict(headers)[b":status"] == b"500", headers
    assert b"content-encoding" not in dict(headers)
    return compressed


async def run(tcp, udp):
    h1 = await verify(lambda *args: h1_request(tcp, *args))
    h2 = await verify(lambda *args: h2_request(tcp, *args))
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"], verify_mode=ssl.CERT_NONE)
    async with connect("127.0.0.1", udp, configuration=config, create_protocol=H3Client) as client:
        h3 = await verify(client.request)
        assert h1 == h2 == h3, "protocols produced different gzip bytes"
        await client.request("/shutdown")
    print("PASS gzip HTTP/1.1, HTTP/2, HTTP/3: 36 wire cases and identical gzip bytes", flush=True)


def main():
    binary = ROOT / "build/http_compression_fixture"
    subprocess.run(["mojo", "build", "--Werror", "-I", ".", "tests/http_compression_fixture.mojo", "-o", str(binary)], cwd=ROOT, check=True)
    server = subprocess.Popen([str(binary)], cwd=ROOT, stdout=subprocess.PIPE, text=True)
    try:
        ready = server.stdout.readline().split()
        assert ready[0] == "READY", ready
        asyncio.run(run(int(ready[1].rsplit(":", 1)[1]), int(ready[2].rsplit(":", 1)[1])))
        assert server.wait(timeout=10) == 0
    finally:
        if server.poll() is None:
            server.terminate()
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
