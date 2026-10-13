import asyncio
import os
import ssl
import subprocess
import sys

from aioquic.asyncio import connect
from aioquic.h3.connection import H3_ALPN, H3Connection, MessageError
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.packet import QuicProtocolVersion
from http_router_contract import CASES, check
from test_http3_server import Http3ClientProtocol, require_http3_alpn


class HeadAwareConnection(H3Connection):
    def __init__(self, quic):
        super().__init__(quic)
        self.head_streams = set()

    def _check_content_length(self, stream):
        # aioquic 1.3 does not retain request methods for HEAD framing.
        if stream.stream_id in self.head_streams:
            if stream.content_length != 0:
                raise MessageError("HEAD response contains data")
        else:
            super()._check_content_length(stream)


class RouterProtocol(Http3ClientProtocol):
    def create_http_connection(self):
        return HeadAwareConnection(self._quic)


async def run(address):
    host, port = address.rsplit(":", 1)
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, server_name="localhost")
    config.supported_versions = [QuicProtocolVersion.VERSION_1]
    config.verify_mode = ssl.CERT_NONE
    async with connect(host, int(port), configuration=config, create_protocol=RouterProtocol) as client:
        require_http3_alpn(client.alpn)
        for case in CASES:
            method, path, body, *_ = case
            print(f"HTTP/3 router: {method} {path}", flush=True)
            stream = client._quic.get_next_available_stream_id()
            if method == "HEAD":
                client.http.head_streams.add(stream)
            response = {"future": asyncio.get_running_loop().create_future(), "headers": [], "body": bytearray()}
            client.responses[stream] = response
            try:
                client.http.send_headers(stream, [(b":method", method.encode()), (b":scheme", b"https"),
                    (b":authority", b"localhost"), (b":path", path.encode())], end_stream=not body)
                if body:
                    client.http.send_data(stream, body, end_stream=True)
                client.transmit()
                result = await asyncio.wait_for(response["future"], timeout=10)
                headers = [(n.decode(), v.decode()) for n, v in result["headers"]]
                status = int(next(v for n, v in headers if n == ":status"))
                check(case, status, bytes(result["body"]), headers)
            finally:
                client.responses.pop(stream)
                client.http.head_streams.discard(stream)


def main():
    env = dict(os.environ, HTTP3_FIXTURE_EXPECT=str(len(CASES)))
    proc = subprocess.Popen(["mojo", "run", "--Werror", "-I", ".", "tests/http3_server_fixture.mojo"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    try:
        line = proc.stdout.readline().strip()
        assert line.startswith("READY "), line
        asyncio.run(run(line.removeprefix("READY ")))
        assert proc.wait(timeout=15) == 0, proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        sys.stderr.write(proc.stderr.read())
    print("Shared router contract passed on HTTP/3")


if __name__ == "__main__":
    main()
