import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from test_http_fileserver import H1Client


class ClosedSocket:
    def __init__(self):
        self.reads = 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def sendall(self, data):
        pass

    def setsockopt(self, *args):
        pass

    def recv(self, length):
        self.reads += 1
        if self.reads > 3:
            raise RuntimeError("driver spun after EOF")
        return b""


class ScriptedSocket(ClosedSocket):
    def __init__(self, chunks):
        super().__init__()
        self.chunks = chunks
        self.sent = b""

    def sendall(self, data):
        self.sent += data

    def recv(self, length):
        self.reads += 1
        return self.chunks.pop(0) if self.chunks else b""


class DriverTests(unittest.TestCase):
    def client(self):
        peer = ClosedSocket()
        client = H1Client(0, False)
        client._open = lambda: peer
        return client, peer

    def test_head_rejects_body_arriving_after_headers(self):
        client = H1Client(0, False)
        client._open = lambda: ScriptedSocket([b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n", b"forbidden"])
        with self.assertRaisesRegex(AssertionError, "excess body"):
            client.request("HEAD", "/file.txt")

    def test_empty_get_rejects_delayed_excess_body(self):
        client = H1Client(0, False)
        client._open = lambda: ScriptedSocket([b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", b"forbidden"])
        with self.assertRaisesRegex(AssertionError, "excess body"):
            client.request("GET", "/file.txt")

    def test_known_length_get_rejects_delayed_excess_body(self):
        client = H1Client(0, False)
        client._open = lambda: ScriptedSocket([b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n", b"abc", b"excess"])
        with self.assertRaisesRegex(AssertionError, "excess body"):
            client.request("GET", "/file.txt")

    def test_complete_response_reads_through_eof(self):
        client = H1Client(0, False)
        peer = ScriptedSocket([b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc", b""])
        client._open = lambda: peer
        response = client.request("GET", "/file.txt")
        self.assertEqual(bytes(response.body), b"abc")
        self.assertEqual(peer.reads, 2)
        self.assertIn(b"Connection: close\r\n", peer.sent)

    def test_request_rejects_eof_before_headers(self):
        client, peer = self.client()
        with self.assertRaisesRegex(AssertionError, "closed before headers"):
            client.request("GET", "/large.bin")
        self.assertEqual(peer.reads, 1)

    def test_paused_reader_rejects_eof_before_headers(self):
        client, peer = self.client()
        with self.assertRaisesRegex(AssertionError, "closed before headers"):
            client.slow_cancel()
        self.assertEqual(peer.reads, 1)


if __name__ == "__main__":
    unittest.main()
