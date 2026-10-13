"""Check the raw TLS connection with an independent own-loopback client."""

import selectors
import socket
import ssl
import subprocess


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(60):
            raise TimeoutError("TLS fixture readiness timed out")
        return process.stdout.readline().strip()


def main():
    process = subprocess.Popen(
        ["mojo", "run", "--Werror", "-I", ".", "tests/http_hijacked_tls_fixture.mojo"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        ready = line(process)
        assert ready.startswith("READY "), ready
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with socket.create_connection(("127.0.0.1", int(ready.split()[1])), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname="localhost") as client:
                assert line(process) == "TLS_PENDING"
                client.sendall(b"hello-raw!")
                received = bytearray()
                while len(received) < 10:
                    chunk = client.recv(10 - len(received))
                    assert chunk, received
                    received.extend(chunk)
                assert received == b"hello-raw!"
                assert client.recv(1) == b""
        out, err = process.communicate(timeout=5)
        assert process.returncode == 0, (out, err)
        assert out.strip() == "DONE", out
        print("Raw TLS retry handoff, echo and close-notify: pass")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


if __name__ == "__main__":
    main()
