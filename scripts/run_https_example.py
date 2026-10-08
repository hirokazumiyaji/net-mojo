import os
import socket
import ssl
import subprocess
import sys


def _wait_ready(process):
    ready = process.stdout.readline().strip()
    if not ready.startswith("READY "):
        raise RuntimeError(
            f"https_hello example did not start: {ready}\n"
            f"{process.stderr.read()}"
        )
    return int(ready.split()[1])


def _run_request(port):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as client:
            if client.selected_alpn_protocol() != "http/1.1":
                raise RuntimeError("https_hello did not negotiate http/1.1")
            client.sendall(
                b"GET / HTTP/1.1\r\nHost: localhost\r\n"
                b"Connection: close\r\n\r\n"
            )
            response = bytearray()
            while chunk := client.recv(4096):
                response.extend(chunk)
    wire = bytes(response)
    if not wire.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected https_hello status: {wire!r}")
    if not wire.endswith(b"hello over https"):
        raise RuntimeError(f"unexpected https_hello body: {wire!r}")


def main():
    env = dict(os.environ)
    env["HELLO_ADDRESS"] = "127.0.0.1:0"
    process = subprocess.Popen(
        ["mojo", "run", "--Werror", "-I", ".", "examples/https_hello.mojo"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        port = _wait_ready(process)
        _run_request(port)
        print("https_hello example roundtrip succeeded")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process.returncode not in (0, -15, 143):
            sys.stderr.write(process.stderr.read())
            raise RuntimeError(
                f"https_hello exited with {process.returncode}"
            )


main()
