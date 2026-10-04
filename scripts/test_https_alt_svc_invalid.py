import socket
import ssl
import subprocess


def read_alive(client):
    wire = bytearray()
    while b"\r\n\r\n" not in wire:
        chunk = client.recv(4096)
        if not chunk:
            raise AssertionError("sibling/arm closed before its response")
        wire.extend(chunk)
    head, body = bytes(wire).split(b"\r\n\r\n", 1)
    if not head.startswith(b"HTTP/1.1 200 OK\r\n"):
        raise AssertionError(bytes(wire))
    lines = head.split(b"\r\n")
    if lines.count(b"Content-Length: 5") != 1:
        raise AssertionError(bytes(wire))
    if lines.count(b'Alt-Svc: h3=":9443"; ma=60') != 1:
        raise AssertionError(bytes(wire))
    if b"Connection: close" in head:
        raise AssertionError("original sibling must remain reusable")
    while len(body) < 5:
        chunk = client.recv(4096)
        if not chunk:
            raise AssertionError("truncated sibling/arm body")
        body += chunk
    if body != b"alive":
        raise AssertionError(body)


def request(client, method, path):
    client.sendall(method + b" " + path + b" HTTP/1.1\r\nHost: localhost\r\n\r\n")


def main(command=("mojo", "run", "--Werror", "-I", ".", "tests/https_alt_svc_invalid_fixture.mojo")):
    cases = [(kind, method, b"/error") for kind in ("crlf", "cr", "lf", "nul", "unit-separator", "del") for method in (b"GET", b"HEAD")]
    cases.append(("crlf-normal-fallback", b"GET", b"/normal"))
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    observed = []
    try:
        ready = process.stdout.readline().strip()
        if not ready.startswith("READY "):
            stdout, stderr = process.communicate(timeout=5)
            raise AssertionError("TLS fixture did not start: " + ready + "\n" + stdout + stderr)
        port = int(ready.split()[1])
        context = ssl.create_default_context(cafile="build/tls/test-cert.pem")
        context.check_hostname = False
        context.set_alpn_protocols(["http/1.1"])
        with socket.create_connection(("127.0.0.1", port), timeout=5) as raw_sibling:
            with context.wrap_socket(raw_sibling, server_hostname="localhost") as sibling:
                sibling.settimeout(5)
                assert sibling.selected_alpn_protocol() == "http/1.1"
                request(sibling, b"GET", b"/sibling")
                read_alive(sibling)
                for kind, method, path in cases:
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                        with context.wrap_socket(raw, server_hostname="localhost") as target:
                            target.settimeout(5)
                            assert target.selected_alpn_protocol() == "http/1.1"
                            request(target, b"GET", b"/arm")
                            read_alive(target)
                            request(target, method, path)
                            wire = bytearray()
                            while chunk := target.recv(4096):
                                wire.extend(chunk)
                            observed.append((kind, method, bytes(wire)))
                    request(sibling, b"GET", b"/sibling")
                    read_alive(sibling)
        stdout, stderr = process.communicate(timeout=5)
        if process.returncode:
            raise AssertionError(stderr + stdout)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    for kind, method, wire in observed:
        print(kind, method.decode(), repr(wire), flush=True)
    injected = [(kind, method, wire) for kind, method, wire in observed if wire]
    assert not injected, "invalid configured Alt-Svc must close only target before error wire: " + repr(injected)
    print("invalid TLS Alt-Svc target close and original sibling continuation passed")


if __name__ == "__main__":
    main()
