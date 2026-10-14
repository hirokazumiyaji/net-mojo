#!/usr/bin/env python3
"""Exercises one shared listener across TLS HTTP/1.1 and HTTP/2 workers."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import select
import socket
import ssl
import subprocess

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded


def request(port: int, protocol: str, path: str = "/") -> bytes:
    context = ssl.create_default_context(cafile="build/tls/test-cert.pem")
    context.set_alpn_protocols([protocol])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as conn:
            assert conn.selected_alpn_protocol() == protocol
            if protocol == "http/1.1":
                conn.sendall(
                    f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode()
                )
                response = bytearray()
                while chunk := conn.recv(4096):
                    response.extend(chunk)
                head, body = bytes(response).split(b"\r\n\r\n", 1)
                assert head.startswith(b"HTTP/1.1 200 OK"), head
                return body
            h2 = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
            h2.initiate_connection()
            h2.send_headers(
                1,
                [(":method", "GET"), (":scheme", "https"),
                 (":authority", "localhost"), (":path", path)],
                end_stream=True,
            )
            conn.sendall(h2.data_to_send())
            body = bytearray()
            status = None
            while True:
                data = conn.recv(4096)
                assert data, "HTTP/2 connection closed before stream ended"
                ended = False
                for event in h2.receive_data(data):
                    if isinstance(event, ResponseReceived):
                        status = dict(event.headers)[":status"]
                    elif isinstance(event, DataReceived):
                        body.extend(event.data)
                        h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, StreamEnded):
                        ended = True
                outgoing = h2.data_to_send()
                if outgoing:
                    conn.sendall(outgoing)
                if ended:
                    assert status == "200", status
                    return bytes(body)


def main() -> None:
    binary = Path("build/http-pool/integration")
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["mojo", "build", "--Werror", "-I", ".", "-Xlinker", "-ldl", "tests/http_pool_integration_fixture.mojo", "-o", str(binary)],
        check=True, timeout=120,
    )
    proc = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert select.select([proc.stdout], [], [], 10)[0], "pool fixture did not start"
        ready = proc.stdout.readline().strip()
        assert ready.startswith("READY "), ready
        port = int(ready.split()[1])
        protocols = ["http/1.1", "h2"] * 32
        with ThreadPoolExecutor(max_workers=8) as executor:
            responses = list(executor.map(lambda protocol: request(port, protocol), protocols))
        assert set(responses) == {b"worker:0", b"worker:1"}, set(responses)
        for worker in range(2):
            print(f"worker {worker}: {responses.count(f'worker:{worker}'.encode())} TLS requests")
        assert request(port, "http/1.1", "/shutdown") == b"bye"
        stdout, stderr = proc.communicate(timeout=10)
        assert proc.returncode == 0, stderr
        assert stdout.strip() == "EXIT", stdout
        print("Shared-listener TLS HTTP/1.1 and HTTP/2 pool integration passed")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate(timeout=5)


if __name__ == "__main__":
    main()
