import socket
import ssl
import subprocess
import sys

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import (
    DataReceived,
    ResponseReceived,
    StreamEnded,
    WindowUpdated,
)


FIXTURE = ["mojo", "run", "--Werror", "-I", ".", "tests/https_server_fixture.mojo"]
AUTHORITY = "localhost"


def _tls_context():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2"])
    return context


def _connect(port):
    raw = socket.create_connection(("127.0.0.1", port), timeout=10)
    tls = _tls_context().wrap_socket(raw, server_hostname=AUTHORITY)
    if tls.selected_alpn_protocol() != "h2":
        tls.close()
        raise AssertionError("server did not negotiate ALPN h2")
    return tls


def _new_h2():
    conn = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
    conn.initiate_connection()
    return conn


def _flush(sock, conn):
    data = conn.data_to_send()
    if data:
        sock.sendall(data)


def _drive(sock, conn, done):
    while not done():
        chunk = sock.recv(65536)
        if not chunk:
            raise AssertionError("server closed connection unexpectedly")
        for event in conn.receive_data(chunk):
            yield event
        _flush(sock, conn)


def _headers(method, path, extra=None):
    headers = [
        (":method", method),
        (":scheme", "https"),
        (":authority", AUTHORITY),
        (":path", path),
    ]
    if extra:
        headers.extend(extra)
    return headers


def test_alpn_and_get(port):
    sock = _connect(port)
    try:
        conn = _new_h2()
        _flush(sock, conn)
        stream_id = conn.get_next_available_stream_id()
        conn.send_headers(stream_id, _headers("GET", "/hello"), end_stream=True)
        _flush(sock, conn)

        body = bytearray()
        ended = [False]
        status = [None]

        def done():
            return ended[0]

        for event in _drive(sock, conn, done):
            if isinstance(event, ResponseReceived) and event.stream_id == stream_id:
                for name, value in event.headers:
                    if name == ":status":
                        status[0] = value
            elif isinstance(event, DataReceived) and event.stream_id == stream_id:
                body.extend(event.data)
                conn.acknowledge_received_data(event.flow_controlled_length, stream_id)
                _flush(sock, conn)
            elif isinstance(event, StreamEnded) and event.stream_id == stream_id:
                ended[0] = True

        if status[0] != "200":
            raise AssertionError(f"unexpected status: {status[0]!r}")
        if bytes(body) != b"hello over https":
            raise AssertionError(f"unexpected GET body: {bytes(body)!r}")
    finally:
        sock.close()


def test_concurrent_streams_and_post(port):
    sock = _connect(port)
    try:
        conn = _new_h2()
        _flush(sock, conn)

        get_a = conn.get_next_available_stream_id()
        conn.send_headers(get_a, _headers("GET", "/a"), end_stream=True)

        post_id = conn.get_next_available_stream_id()
        payload = b"concurrent-post-body"
        conn.send_headers(
            post_id,
            _headers("POST", "/echo", extra=[("content-length", str(len(payload)))]),
            end_stream=False,
        )
        conn.send_data(post_id, payload, end_stream=True)

        get_b = conn.get_next_available_stream_id()
        conn.send_headers(get_b, _headers("GET", "/b"), end_stream=True)
        _flush(sock, conn)

        bodies = {get_a: bytearray(), post_id: bytearray(), get_b: bytearray()}
        ended = {get_a: False, post_id: False, get_b: False}
        statuses = {}

        def done():
            return all(ended.values())

        for event in _drive(sock, conn, done):
            if isinstance(event, ResponseReceived):
                for name, value in event.headers:
                    if name == ":status":
                        statuses[event.stream_id] = value
            elif isinstance(event, DataReceived):
                bodies[event.stream_id].extend(event.data)
                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                _flush(sock, conn)
            elif isinstance(event, StreamEnded):
                ended[event.stream_id] = True

        if any(statuses.get(sid) != "200" for sid in (get_a, post_id, get_b)):
            raise AssertionError(f"unexpected statuses: {statuses!r}")
        if bytes(bodies[get_a]) != b"hello over https":
            raise AssertionError(f"GET a body wrong: {bytes(bodies[get_a])!r}")
        if bytes(bodies[get_b]) != b"hello over https":
            raise AssertionError(f"GET b body wrong: {bytes(bodies[get_b])!r}")
        if bytes(bodies[post_id]) != b"hello over https" + payload:
            raise AssertionError(f"POST echo body wrong: {bytes(bodies[post_id])!r}")
    finally:
        sock.close()


def test_large_post_exceeds_initial_window(port):
    sock = _connect(port)
    try:
        conn = _new_h2()
        _flush(sock, conn)
        stream_id = conn.get_next_available_stream_id()
        payload_size = 128 * 1024
        payload = (b"x" * 1024) * (payload_size // 1024)
        conn.send_headers(
            stream_id,
            _headers("POST", "/large", extra=[("content-length", str(len(payload)))]),
            end_stream=False,
        )
        _flush(sock, conn)

        sent = 0
        ended = [False]
        body = bytearray()
        status = [None]

        def done():
            return ended[0]

        while sent < len(payload) or not ended[0]:
            while sent < len(payload):
                window = conn.local_flow_control_window(stream_id)
                if window <= 0:
                    break
                chunk_size = min(
                    window,
                    conn.max_outbound_frame_size,
                    len(payload) - sent,
                )
                conn.send_data(
                    stream_id,
                    payload[sent : sent + chunk_size],
                    end_stream=(sent + chunk_size == len(payload)),
                )
                sent += chunk_size
            _flush(sock, conn)

            sock.settimeout(10)
            chunk = sock.recv(65536)
            if not chunk:
                raise AssertionError("server closed before draining large POST")
            for event in conn.receive_data(chunk):
                if isinstance(event, ResponseReceived) and event.stream_id == stream_id:
                    for name, value in event.headers:
                        if name == ":status":
                            status[0] = value
                elif isinstance(event, DataReceived) and event.stream_id == stream_id:
                    body.extend(event.data)
                    conn.acknowledge_received_data(event.flow_controlled_length, stream_id)
                elif isinstance(event, StreamEnded) and event.stream_id == stream_id:
                    ended[0] = True
                elif isinstance(event, WindowUpdated):
                    pass
            _flush(sock, conn)

        if status[0] != "200":
            raise AssertionError(f"unexpected status: {status[0]!r}")
        if bytes(body) != b"hello over https" + payload:
            raise AssertionError(
                f"large POST body wrong: len={len(body)} expected={16 + len(payload)}"
            )
    finally:
        sock.close()


def main():
    process = subprocess.Popen(
        FIXTURE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise RuntimeError(f"HTTPS fixture did not start: {ready!r}")
        port = int(ready.split()[1])

        test_alpn_and_get(port)
        test_concurrent_streams_and_post(port)
        test_large_post_exceeds_initial_window(port)
        test_alpn_and_get(port)

        if process.wait(timeout=15) != 0:
            raise RuntimeError(process.stderr.read())
        print("hyper-h2 interop succeeded")
    except Exception:
        process.kill()
        process.wait()
        sys.stderr.write(process.stderr.read())
        raise


if __name__ == "__main__":
    main()
