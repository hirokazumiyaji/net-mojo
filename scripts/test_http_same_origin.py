import asyncio
import http.client
import os
import select
import socket
import ssl
import subprocess
import tempfile

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, ProtocolNegotiated


class SameOriginClient(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.alpn = None
        self.headers = []
        self.body = bytearray()
        self.response = self._loop.create_future()
        self.terminated = self._loop.create_future()

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            self.alpn = event.alpn_protocol
        if isinstance(event, ConnectionTerminated):
            self.terminated.set_result(event.error_code)
        for message in self.http.handle_event(event):
            if isinstance(message, HeadersReceived):
                self.headers.extend(message.headers)
            elif isinstance(message, DataReceived):
                self.body.extend(message.data)
            if message.stream_ended:
                self.response.set_result(None)

    async def hello(self, authority):
        self.http.send_headers(
            self._quic.get_next_available_stream_id(),
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", authority.encode()),
                (b":path", b"/hello"),
            ],
            end_stream=True,
        )
        self.transmit()
        await asyncio.wait_for(self.response, 5)
        if self.alpn != "h3":
            raise RuntimeError(f"expected actual ALPN h3, got {self.alpn!r}")
        if (b":status", b"200") not in self.headers:
            raise RuntimeError(f"unexpected HTTP/3 headers: {self.headers!r}")
        if bytes(self.body) != b"same-origin:/hello":
            raise RuntimeError(f"unexpected HTTP/3 body: {self.body!r}")


def https_request(client, path, authority, advertisement):
    if client.selected_alpn_protocol() != "http/1.1":
        raise RuntimeError("HTTPS did not negotiate http/1.1")
    client.sendall(f"GET {path} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
    with http.client.HTTPResponse(client) as response:
        response.begin()
        body = response.read()
        if response.status != 200 or body != ("same-origin:" + path).encode():
            raise RuntimeError(f"unexpected HTTPS response: {response.status}, {body!r}")
        if response.getheader("Alt-Svc") != advertisement:
            raise RuntimeError(f"unexpected Alt-Svc: {response.getheader('Alt-Svc')!r}")


async def dual_requests(client, port, authority):
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.server_name = "localhost"
    config.load_verify_locations(cafile="build/tls/test-cert.pem")
    async with connect(
        "127.0.0.1", port, configuration=config, create_protocol=SameOriginClient
    ) as quic:
        await quic.hello(authority)
        await asyncio.to_thread(
            https_request, client, "/shutdown", authority, f'h3=":{port}"; ma=60'
        )
        code = await asyncio.wait_for(quic.terminated, 5)
        if code != 0x100:
            raise RuntimeError(f"expected graceful H3_NO_ERROR, got {code}")


def run_mode(command, mode):
    context = ssl.create_default_context(cafile="build/tls/test-cert.pem")
    context.set_alpn_protocols(["http/1.1"])
    with tempfile.TemporaryFile(mode="w+") as errors:
        process = subprocess.Popen(
            command,
            env={**os.environ, "NET_SAME_ORIGIN_MODE": mode},
            stdout=subprocess.PIPE,
            stderr=errors,
            text=True,
        )
        try:
            if not select.select([process.stdout], [], [], 15)[0]:
                raise RuntimeError("same-origin fixture readiness timed out")
            ready = process.stdout.readline().strip()
            if not ready.startswith("READY "):
                raise RuntimeError(f"same-origin fixture did not start: {ready!r}")
            port = int(ready.removeprefix("READY "))
            authority = f"localhost:{port}"
            with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname="localhost") as client:
                    advertisement = f'h3=":{port}"; ma=60' if mode == "dual" else None
                    https_request(client, "/hello", authority, advertisement)
                    if mode == "dual":
                        asyncio.run(asyncio.wait_for(dual_requests(client, port, authority), 15))
                    else:
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as unused_udp:
                            unused_udp.bind(("127.0.0.1", port))
                            https_request(client, "/shutdown", authority, None)
                    if client.recv(1) != b"":
                        raise RuntimeError("HTTPS connection did not drain to EOF")
            output, _ = process.communicate(timeout=10)
            expected = "DRAINED 3" if mode == "dual" else "DRAINED 2"
            if process.returncode != 0 or output.strip() != expected:
                raise RuntimeError(f"same-origin fixture exit {process.returncode}: {output!r}")
            errors.seek(0)
            if errors.read():
                raise RuntimeError("same-origin fixture wrote unexpected stderr")
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as released_udp:
                released_udp.bind(("127.0.0.1", port))
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as released_tcp:
                released_tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                released_tcp.bind(("127.0.0.1", port))
                released_tcp.listen(1)
            print(f"Same-origin {mode} roundtrips and cooperative shutdown succeeded")
        except BaseException:
            errors.seek(0)
            details = errors.read()
            if details:
                print(details, end="")
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def main():
    command = [
        "mojo",
        "run",
        "--Werror",
        "-I",
        ".",
        "tests/http_same_origin_fixture.mojo",
    ]
    for mode in ["dual", "https-only"]:
        run_mode(command, mode)


if __name__ == "__main__":
    main()
