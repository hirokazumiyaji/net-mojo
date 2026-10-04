import socket
import ssl
import subprocess
import sys


def read_h2_frame(client):
    header = bytearray()
    while len(header) < 9:
        try:
            chunk = client.recv(9 - len(header))
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as exc:
            raise RuntimeError("connection closed before HTTP/2 response") from exc
        if not chunk:
            raise RuntimeError("connection closed before HTTP/2 response")
        header.extend(chunk)
    length = int.from_bytes(header[:3], "big")
    payload = bytearray()
    while len(payload) < length:
        try:
            chunk = client.recv(length - len(payload))
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as exc:
            raise RuntimeError("incomplete HTTP/2 response frame") from exc
        if not chunk:
            raise RuntimeError("incomplete HTTP/2 response frame")
        payload.extend(chunk)
    return (
        header[3],
        header[4],
        int.from_bytes(header[5:9], "big"),
        bytes(payload),
    )


def hpack_starts_with_status_200(payload):
    """True when the block encodes :status 200, optionally after a table-size update."""
    i = 0
    # RFC 7541 §6.3: Dynamic Table Size Update has pattern 001xxxxx.
    while i < len(payload) and (payload[i] & 0xE0) == 0x20:
        prefix = payload[i] & 0x1F
        i += 1
        if prefix == 0x1F:
            while i < len(payload) and (payload[i] & 0x80) != 0:
                i += 1
            if i < len(payload):
                i += 1
    return i < len(payload) and payload[i] == 0x88


def _h2_context():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2"])
    return context


def _h2_bootstrap(client):
    client.sendall(
        b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
    )
    bootstrap = bytearray()
    while len(bootstrap) < 24:
        chunk = client.recv(24 - len(bootstrap))
        if not chunk:
            raise RuntimeError("incomplete HTTP/2 bootstrap")
        bootstrap.extend(chunk)
    return bytes(bootstrap)


def _h2_headers_frame(stream_id, flags=0x05):
    headers = b"\x82\x86\x84\x41\x0fwww.example.com"
    return (
        len(headers).to_bytes(3, "big")
        + bytes([0x01, flags])
        + stream_id.to_bytes(4, "big")
        + headers
    )


def _h2_rst_frame(stream_id, error_code=8):
    return (
        b"\x00\x00\x04\x03\x00"
        + stream_id.to_bytes(4, "big")
        + error_code.to_bytes(4, "big")
    )


def _read_until_goaway(client, expect_error_code):
    while True:
        frame_type, flags, stream_id, payload = read_h2_frame(client)
        if frame_type == 7:
            last_stream_id = int.from_bytes(payload[:4], "big") & 0x7FFFFFFF
            error_code = int.from_bytes(payload[4:8], "big")
            if error_code != expect_error_code:
                raise RuntimeError(
                    f"unexpected GOAWAY error_code={error_code} "
                    f"last_stream_id={last_stream_id} payload={payload!r}"
                )
            return last_stream_id, error_code


def _read_response_body(client, stream_id, timeout_frames=16):
    body = bytearray()
    saw_headers = False
    for _ in range(timeout_frames):
        frame_type, flags, sid, payload = read_h2_frame(client)
        if sid != stream_id:
            if frame_type == 7:
                raise RuntimeError(
                    f"unexpected GOAWAY while reading stream {stream_id}: "
                    f"{payload!r}"
                )
            continue
        if frame_type == 1:
            saw_headers = True
        elif frame_type == 0:
            body.extend(payload)
            if flags & 1:
                return bytes(body)
        elif frame_type == 3:
            raise RuntimeError(
                f"stream {stream_id} reset unexpectedly: {payload!r}"
            )
    raise RuntimeError(
        f"timed out waiting for stream {stream_id} body "
        f"(headers={saw_headers}, body={bytes(body)!r})"
    )


def test_http2_shutdown_goaway():
    shutdown_process = subprocess.Popen(
        [
            "mojo",
            "run",
            "--Werror",
            "-I",
            ".",
            "tests/https_shutdown_fixture.mojo",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = shutdown_process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(f"shutdown fixture did not start: {ready}")
        port = int(ready.split()[1])
        context = _h2_context()
        with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname="localhost") as client:
                client.settimeout(5)
                _h2_bootstrap(client)
                client.sendall(_h2_headers_frame(1))
                response_ended = False
                while True:
                    frame_type, flags, stream_id, payload = read_h2_frame(client)
                    if stream_id == 1 and frame_type == 0 and flags & 1:
                        response_ended = True
                    if frame_type == 7:
                        last_stream_id = (
                            int.from_bytes(payload[:4], "big") & 0x7FFFFFFF
                        )
                        error_code = int.from_bytes(payload[4:8], "big")
                        if (
                            last_stream_id != 1
                            or error_code != 0
                            or not response_ended
                        ):
                            raise RuntimeError(
                                f"unexpected graceful shutdown frames: {frame_type, stream_id, payload!r}"
                            )
                        break
        if shutdown_process.wait(timeout=5) != 0:
            raise RuntimeError(shutdown_process.stderr.read())
    except Exception:
        shutdown_process.kill()
        shutdown_process.wait()
        sys.stderr.write(shutdown_process.stderr.read())
        raise


def test_https_alt_svc_advertisement():
    alt_process = subprocess.Popen(
        [
            "mojo",
            "run",
            "--Werror",
            "-I",
            ".",
            "tests/https_alt_svc_fixture.mojo",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = alt_process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(f"alt-svc fixture did not start: {ready}")
        port = int(ready.split()[1])
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["http/1.1"])

        with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname="localhost") as client:
                client.sendall(
                    b"GET / HTTP/1.1\r\nHost: localhost\r\n"
                    b"Connection: close\r\n\r\n"
                )
                response = bytearray()
                while chunk := client.recv(4096):
                    response.extend(chunk)
        injected = bytes(response)
        if b'Alt-Svc: h3=":8443"; ma=86400\r\n' not in injected:
            raise RuntimeError(
                f"expected injected Alt-Svc on HTTPS response: {injected!r}"
            )

        with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname="localhost") as client:
                client.sendall(
                    b"GET /custom HTTP/1.1\r\nHost: localhost\r\n"
                    b"Connection: close\r\n\r\n"
                )
                response = bytearray()
                while chunk := client.recv(4096):
                    response.extend(chunk)
        custom = bytes(response)
        if b'Alt-Svc: h3=":9443"; ma=60\r\n' not in custom:
            raise RuntimeError(
                f"handler Alt-Svc must win over config: {custom!r}"
            )
        if b'h3=":8443"; ma=86400' in custom:
            raise RuntimeError(
                f"config Alt-Svc must not replace handler value: {custom!r}"
            )
        if alt_process.wait(timeout=5) != 0:
            raise RuntimeError(alt_process.stderr.read())
    except Exception:
        alt_process.kill()
        alt_process.wait()
        sys.stderr.write(alt_process.stderr.read())
        raise


def test_http2_new_stream_flood_isolates_connections():
    process = subprocess.Popen(
        ["mojo", "run", "--Werror", "-I", ".", "tests/https_flood_fixture.mojo"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(f"stream-rate fixture did not start: {ready}")
        port = int(ready.split()[1])
        context = _h2_context()
        with context.wrap_socket(
            socket.create_connection(("127.0.0.1", port), timeout=5),
            server_hostname="localhost",
        ) as client_a, context.wrap_socket(
            socket.create_connection(("127.0.0.1", port), timeout=5),
            server_hostname="localhost",
        ) as client_b:
            _h2_bootstrap(client_a)
            _h2_bootstrap(client_b)
            for stream_id in (1, 3):
                client_a.sendall(_h2_headers_frame(stream_id))
                body = _read_response_body(client_a, stream_id)
                if body != b"flood-ok":
                    raise RuntimeError(f"unexpected stream-rate response: {body!r}")
            client_a.sendall(_h2_headers_frame(5))
            last_stream_id, _ = _read_until_goaway(client_a, expect_error_code=11)
            if last_stream_id != 3:
                raise RuntimeError(f"stream-rate GOAWAY last ID: {last_stream_id}")
            client_b.sendall(_h2_headers_frame(1))
            body = _read_response_body(client_b, 1)
            if body != b"flood-ok":
                raise RuntimeError(f"stream-rate flood affected sibling: {body!r}")
        if process.wait(timeout=10) != 0:
            raise RuntimeError(process.stderr.read())
    except Exception:
        process.kill()
        process.wait()
        sys.stderr.write(process.stderr.read())
        raise


def test_http2_reset_flood_isolates_connections():
    """RST storm on connection A; connection B still completes a request."""
    flood_process = subprocess.Popen(
        [
            "mojo",
            "run",
            "--Werror",
            "-I",
            ".",
            "tests/https_flood_fixture.mojo",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = flood_process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(f"flood fixture did not start: {ready}")
        port = int(ready.split()[1])
        context = _h2_context()

        raw_a = socket.create_connection(("127.0.0.1", port), timeout=5)
        client_a = context.wrap_socket(raw_a, server_hostname="localhost")
        client_a.settimeout(5)
        raw_b = socket.create_connection(("127.0.0.1", port), timeout=5)
        client_b = context.wrap_socket(raw_b, server_hostname="localhost")
        client_b.settimeout(5)
        try:
            if client_a.selected_alpn_protocol() != "h2":
                raise RuntimeError("connection A did not negotiate HTTP/2")
            if client_b.selected_alpn_protocol() != "h2":
                raise RuntimeError("connection B did not negotiate HTTP/2")

            _h2_bootstrap(client_a)
            _h2_bootstrap(client_b)

            # Connection A: complete stream 1, keep stream 3 healthy, then RST-storm.
            client_a.sendall(_h2_headers_frame(1, flags=0x05))
            body_a = _read_response_body(client_a, 1)
            if body_a != b"flood-ok":
                raise RuntimeError(f"unexpected A stream 1 body: {body_a!r}")

            # Healthy / in-progress stream on the same connection.
            client_a.sendall(_h2_headers_frame(3, flags=0x04))

            # Fixture max_resets_per_second=2; third RST triggers ENHANCE_YOUR_CALM.
            client_a.sendall(
                _h2_rst_frame(1) + _h2_rst_frame(1) + _h2_rst_frame(1)
            )
            last_stream_id, error_code = _read_until_goaway(client_a, 11)
            if last_stream_id < 3:
                raise RuntimeError(
                    f"GOAWAY last_stream_id={last_stream_id} expected >= 3"
                )
            if error_code != 11:
                raise RuntimeError(f"expected ENHANCE_YOUR_CALM, got {error_code}")

            # Check the sibling before provoking a TLS error on A: CPython can
            # leave OpenSSL thread-local errors that poison reads on B.
            client_b.sendall(_h2_headers_frame(1, flags=0x05))
            body_b = _read_response_body(client_b, 1)
            if body_b != b"flood-ok":
                raise RuntimeError(f"unexpected B body after A flood: {body_b!r}")

            # No further request completes on the flooded connection, and the
            # server must close it after flushing GOAWAY (not leave it idle
            # until timeout). A timeout here means the leak is present.
            closed = False
            try:
                client_a.sendall(_h2_headers_frame(5, flags=0x05))
                for _ in range(16):
                    frame_type, flags, stream_id, payload = read_h2_frame(
                        client_a
                    )
                    if stream_id == 5 and frame_type == 1:
                        raise RuntimeError(
                            "flooded connection completed a request after GOAWAY"
                        )
                    # RST for stream 5 or another GOAWAY does not prove the
                    # connection closed; keep reading until EOF/reset.
                    continue
            except (TimeoutError, socket.timeout) as exc:
                raise RuntimeError(
                    "flooded connection stayed open after GOAWAY "
                    "(expected EOF/reset, got timeout)"
                ) from exc
            except RuntimeError as exc:
                if "connection closed" in str(exc) or "incomplete HTTP/2" in str(
                    exc
                ):
                    closed = True
                else:
                    raise
            except (ssl.SSLError, OSError) as exc:
                msg = str(exc).lower()
                if any(
                    s in msg
                    for s in (
                        "closed",
                        "reset",
                        "eof",
                        "broken pipe",
                        "connection",
                    )
                ):
                    closed = True
                else:
                    raise RuntimeError(
                        f"unexpected error waiting for flooded close: {exc!r}"
                    ) from exc
            if not closed:
                raise RuntimeError(
                    "flooded connection stayed open after GOAWAY "
                    "(expected EOF/reset)"
                )
        finally:
            try:
                client_a.close()
            except OSError:
                pass
            try:
                client_b.close()
            except OSError:
                pass

        if flood_process.wait(timeout=10) != 0:
            raise RuntimeError(flood_process.stderr.read())
    except Exception:
        flood_process.kill()
        flood_process.wait()
        sys.stderr.write(flood_process.stderr.read())
        raise


process = subprocess.Popen(
    ["mojo", "run", "--Werror", "-I", ".", "tests/https_server_fixture.mojo"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

try:
    # Independent of the shared fixture: opt-in Alt-Svc advertisement.
    test_https_alt_svc_advertisement()

    ready = process.stdout.readline().strip()
    if not ready.startswith("READY "):
        raise RuntimeError(f"HTTPS fixture did not start: {ready}")
    port = int(ready.split()[1])

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])

    http2_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    http2_context.check_hostname = False
    http2_context.verify_mode = ssl.CERT_NONE
    http2_context.set_alpn_protocols(["h2"])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with http2_context.wrap_socket(raw, server_hostname="localhost") as client:
            if client.selected_alpn_protocol() != "h2":
                raise RuntimeError("server did not negotiate HTTP/2")
            client.sendall(
                b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
            )
            response = bytearray()
            while len(response) < 24:
                chunk = client.recv(24 - len(response))
                if not chunk:
                    break
                response.extend(chunk)
            if len(response) != 24:
                raise RuntimeError(
                    f"incomplete HTTP/2 bootstrap response: {bytes(response)!r}"
                )
            if (
                response[3] != 4
                or response[10] != 3
                or response[14] != 100
                or response[18] != 4
                or response[19] != 1
            ):
                raise RuntimeError(
                    f"unexpected HTTP/2 bootstrap frames: {bytes(response)!r}"
                )

            compressed_headers = b"\x82\x86\x84\x41\x0fwww.example.com"
            headers_frame = (
                len(compressed_headers).to_bytes(3, "big")
                + b"\x01\x04\x00\x00\x00\x01"
                + compressed_headers
            )
            request_body = b"from h2"
            data_frame = (
                len(request_body).to_bytes(3, "big")
                + b"\x00\x01\x00\x00\x00\x01"
                + request_body
            )
            second_headers_frame = (
                len(compressed_headers).to_bytes(3, "big")
                + b"\x01\x05\x00\x00\x00\x03"
                + compressed_headers
            )
            client.sendall(headers_frame + data_frame + second_headers_frame)

            connection_credit = read_h2_frame(client)
            stream_credit = read_h2_frame(client)
            if (
                connection_credit[0] != 8
                or connection_credit[2] != 0
                or connection_credit[3][-1] != len(request_body)
                or stream_credit[0] != 8
                or stream_credit[2] != 1
                or stream_credit[3][-1] != len(request_body)
            ):
                raise RuntimeError(
                    "unexpected HTTP/2 receive credit: "
                    f"{connection_credit!r}, {stream_credit!r}"
                )

            response_bodies = {}
            for _ in range(4):
                frame = read_h2_frame(client)
                if frame[0] == 1:
                    if not hpack_starts_with_status_200(frame[3]):
                        raise RuntimeError(
                            f"unexpected HTTP/2 headers: {frame!r}"
                        )
                    response_bodies[frame[2]] = bytearray()
                elif frame[0] == 0 and frame[2] in response_bodies:
                    response_bodies[frame[2]].extend(frame[3])
            if response_bodies != {
                1: b"hello over httpsfrom h2",
                3: b"hello over https",
            }:
                raise RuntimeError(
                    f"unexpected multiplexed HTTP/2 bodies: {response_bodies!r}"
                )

    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with http2_context.wrap_socket(raw, server_hostname="localhost") as client:
            client.sendall(
                b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                b"\x00\x00\x06\x04\x00\x00\x00\x00\x00"
                b"\x00\x04\x00\x00\x00\x00"
            )
            bootstrap = bytearray()
            while len(bootstrap) < 24:
                chunk = client.recv(24 - len(bootstrap))
                if not chunk:
                    break
                bootstrap.extend(chunk)
            if len(bootstrap) != 24:
                raise RuntimeError("incomplete HTTP/2 SETTINGS response")
            compressed_headers = b"\x82\x86\x84\x41\x0fwww.example.com"
            client.sendall(
                len(compressed_headers).to_bytes(3, "big")
                + b"\x01\x05\x00\x00\x00\x01"
                + compressed_headers
            )
            limited_headers = read_h2_frame(client)
            if (
                limited_headers[0] != 1
                or limited_headers[2] != 1
                or (limited_headers[1] & 1) != 0
                or not hpack_starts_with_status_200(limited_headers[3])
            ):
                raise RuntimeError(
                    f"server exceeded a zero HTTP/2 send window: {limited_headers!r}"
                )
            stream_increment = b"\x00\x00\x00\x20"
            client.sendall(
                b"\x00\x00\x04\x08\x00\x00\x00\x00\x01"
                + stream_increment
            )
            response_data = read_h2_frame(client)
            if (
                response_data[0] != 0
                or response_data[1] & 1 == 0
                or response_data[2] != 1
                or response_data[3] != b"hello over https"
            ):
                raise RuntimeError(
                    f"server did not resume HTTP/2 body after credit: {response_data!r}"
                )

    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as client:
            if client.selected_alpn_protocol() != "http/1.1":
                raise RuntimeError("server did not negotiate HTTP/1.1")
            client.sendall(
                b"POST /hello HTTP/1.1\r\nHost: localhost\r\n"
                b"Content-Length: 3\r\nExpect: 100-continue\r\n"
                b"Connection: close\r\n\r\n"
            )
            interim = bytearray()
            while len(interim) < 25:
                chunk = client.recv(25 - len(interim))
                if not chunk:
                    raise RuntimeError("HTTPS closed before 100 Continue")
                interim.extend(chunk)
            if interim != b"HTTP/1.1 100 Continue\r\n\r\n":
                raise RuntimeError(f"unexpected HTTPS interim response: {interim!r}")
            client.sendall(b"abc")
            response = bytearray()
            while chunk := client.recv(4096):
                response.extend(chunk)

    wire = bytes(response)
    if not wire.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected HTTPS response: {wire!r}")
    if not wire.endswith(b"hello over httpsabc"):
        raise RuntimeError(f"unexpected HTTPS response body: {wire!r}")
    if b"Alt-Svc:" in wire:
        raise RuntimeError(
            f"Alt-Svc must be absent when ServerConfig.alt_svc is empty: {wire!r}"
        )
    if process.wait(timeout=5) != 0:
        raise RuntimeError(process.stderr.read())
    test_http2_shutdown_goaway()
    test_http2_reset_flood_isolates_connections()
    test_http2_new_stream_flood_isolates_connections()
    print("HTTP/2 bootstrap and HTTPS roundtrips succeeded")
except Exception:
    process.kill()
    process.wait()
    sys.stderr.write(process.stderr.read())
    raise
