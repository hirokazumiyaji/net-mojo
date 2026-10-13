"""Observe client SNI, peer identity verification, and HTTP/1.1 negotiation."""

import socket
import ssl
import subprocess
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/tls/https_client_probe"


def case(*, host="localhost", ca="test-cert.pem", sni="-", insecure=False,
         ip_certificate=False, offer_alpn=True, expected="localhost|http/1.1"):
    certificate = "client-ip-cert.pem" if ip_certificate else "test-cert.pem"
    key = "client-ip-key.pem" if ip_certificate else "test-key.pem"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ROOT / "build/tls" / certificate, ROOT / "build/tls" / key)
    if offer_alpn:
        context.set_alpn_protocols(["http/1.1"])
    names = []
    context.set_servername_callback(lambda connection, name, selected_context: names.append(name))
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(5)
    authority = f"{host}:{listener.getsockname()[1]}"
    errors = []

    def serve():
        try:
            connection, _ = listener.accept()
            connection.settimeout(5)
            try:
                with context.wrap_socket(connection, server_side=True) as secured:
                    request = b""
                    while b"\r\n\r\n" not in request:
                        chunk = secured.recv(4096)
                        if not chunk:
                            raise AssertionError("client closed before the request head")
                        request += chunk
                    assert b"Host: " + authority.encode() + b"\r\n" in request, request
                    name = names[-1] if names[-1] is not None else "none"
                    protocol = secured.selected_alpn_protocol() or "none"
                    body = f"{name}|{protocol}".encode()
                    secured.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
                                    + str(len(body)).encode() + b"\r\n\r\n" + body)
            except ssl.SSLError:
                if not expected.startswith("ERROR"):
                    raise
                connection.close()
        except BaseException as error:
            errors.append(error)
        finally:
            listener.close()

    worker = threading.Thread(target=serve)
    worker.start()
    trust = "-" if ca == "-" else str(ROOT / "build/tls" / ca)
    result = subprocess.run([str(BINARY), f"https://{authority}/",
                             trust, sni, str(insecure).lower()], cwd=ROOT,
                            capture_output=True, text=True, timeout=10)
    worker.join(timeout=6)
    assert not worker.is_alive(), "TLS server did not exit"
    assert not errors, errors
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == expected, (result.stdout, result.stderr, expected)


def main():
    subprocess.run(["mojo", "build", "--Werror", "-I", ".",
                    "tests/https_client_probe.mojo", "-o", str(BINARY)], cwd=ROOT, check=True)
    case()
    case(host="localhost.")
    case(sni="other.example", expected="other.example|http/1.1")
    case(sni="other.example.", expected="other.example|http/1.1")
    case(offer_alpn=False, expected="localhost|none")
    case(host="127.0.0.1", ca="client-ip-cert.pem", ip_certificate=True,
         expected="none|http/1.1")
    case(host="127.0.0.1", sni="localhost", expected="ERROR 1")
    case(ca="-", expected="ERROR 1")
    case(host="127.0.0.1", ca="-", insecure=True, expected="none|http/1.1")
    print("9 HTTPS client interoperability cases passed")


if __name__ == "__main__":
    main()
