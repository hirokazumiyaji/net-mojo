"""Independent HTTP/1 raw switching checks against our own loopback fixture."""

import argparse
import contextlib
import http.client
import os
import selectors
import socket
import ssl
import subprocess
from concurrent.futures import ThreadPoolExecutor

PAYLOAD = b"hi\x00\x7f\x80\xffraw!"


def read_line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(30):
            raise TimeoutError("hijack fixture readiness timed out")
        line = process.stdout.readline().strip()
        if not line:
            _, error = process.communicate(timeout=5)
            raise RuntimeError(f"hijack fixture exited before readiness: {error}")
        return line


@contextlib.contextmanager
def fixture(transport, method, target_port=0):
    process = subprocess.Popen(
        ["build/http_hijack_fixture"],
        env=dict(os.environ, HIJACK_TRANSPORT=transport, HIJACK_METHOD=method,
                 HIJACK_TARGET_PORT=str(target_port)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        ready = read_line(process)
        assert ready.startswith("READY "), ready
        yield int(ready.split()[1])
        out, error = process.communicate(timeout=10)
        assert process.returncode == 0, (out, error)
        assert out.strip() == "DONE", (out, error)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def receive_exact(connection, length, prefix=b""):
    out = bytearray(prefix)
    while len(out) < length:
        chunk = connection.recv(length - len(out))
        assert chunk, out
        out.extend(chunk)
    assert len(out) == length, out
    return bytes(out)


def read_head(connection):
    out = bytearray()
    while b"\r\n\r\n" not in out:
        chunk = connection.recv(4096)
        assert chunk, out
        out.extend(chunk)
    head, tail = bytes(out).split(b"\r\n\r\n", 1)
    return head, tail


def tls_context():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])
    return context


def upgrade_http_client(transport):
    with fixture(transport, "upgrade") as port:
        if transport == "tls":
            client = http.client.HTTPSConnection("127.0.0.1", port, timeout=5,
                                                 context=tls_context())
        else:
            client = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            client.putrequest("GET", "/", skip_host=True, skip_accept_encoding=True)
            client.putheader("Host", "local")
            client.putheader("Connection", "Upgrade")
            client.putheader("Upgrade", "echo")
            if transport == "tls":
                prefix = b"GET / HTTP/1.1\r\nHost: local\r\nConnection: Upgrade\r\nUpgrade: echo\r\nX-Padding: "
                client.putheader("X-Padding", "x" * (8192 - len(prefix) - 4))
            client.endheaders()
            response = client.getresponse()
            assert response.status == 101, response.status
            assert response.getheader("Upgrade") == "echo"
            assert response.getheader("Content-Length") is None
            client.sock.sendall(PAYLOAD)
            assert receive_exact(client.sock, 10) == PAYLOAD
            assert client.sock.recv(1) == b""
            response.close()
        finally:
            client.close()


def upgrade_pipelined_socket():
    with fixture("plain", "upgrade") as port:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(b"GET / HTTP/1.1\r\nHost: local\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n" + PAYLOAD)
            head, tail = read_head(client)
            assert head.startswith(b"HTTP/1.1 101 Switching Protocols\r\n"), head
            assert b"Content-Length:" not in head
            assert receive_exact(client, 10, tail) == PAYLOAD
            assert client.recv(1) == b""


def echo_target(listener):
    with listener.accept()[0] as connection:
        connection.settimeout(5)
        received = receive_exact(connection, 10)
        assert received == PAYLOAD, received
        connection.sendall(received)


def connect_loopback(transport):
    with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as pool:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        target_port = listener.getsockname()[1]
        target = pool.submit(echo_target, listener)
        with fixture(transport, "connect", target_port) as port:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as plain:
                client = tls_context().wrap_socket(plain, server_hostname="localhost") if transport == "tls" else plain
                try:
                    authority = f"127.0.0.1:{target_port}".encode("ascii")
                    client.sendall(b"CONNECT " + authority + b" HTTP/1.1\r\nHost: " + authority + b"\r\n\r\n" + PAYLOAD)
                    head, tail = read_head(client)
                    assert head == b"HTTP/1.1 200 Connection Established", head
                    assert receive_exact(client, 10, tail) == PAYLOAD
                    assert client.recv(1) == b""
                finally:
                    if client is not plain:
                        client.close()
        target.result(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tls", action="store_true")
    args = parser.parse_args()
    transport = "tls" if args.tls else "plain"
    upgrade_http_client(transport)
    connect_loopback(transport)
    if not args.tls:
        upgrade_pipelined_socket()
    print(f"{transport} Upgrade, CONNECT, binary echo and ownership handoff: pass")


if __name__ == "__main__":
    main()
