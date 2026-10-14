import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import test_http_fileserver as fileserver
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


class TransferWaitTests(unittest.TestCase):
    def wait(self, duration, progressing, idle=1, total=4):
        now = 0.0
        with patch.object(fileserver.time, "monotonic", side_effect=lambda: now):
            progress = fileserver.TransferProgress()

            class Transfer:
                def is_alive(self):
                    return now < duration

                def join(self, timeout):
                    nonlocal now
                    now += timeout
                    if progressing:
                        progress.set()

            fileserver.wait_for_transfer(Transfer(), progress, idle, total)
        return now

    def test_progressing_transfer_can_outlive_idle_timeout(self):
        self.assertGreaterEqual(self.wait(2, True), 2)

    def test_idle_transfer_fails(self):
        with self.assertRaisesRegex(AssertionError, "idle"):
            self.wait(10, False)

    def test_continuous_transfer_has_total_cap(self):
        with self.assertRaisesRegex(AssertionError, "completion deadline"):
            self.wait(10, True, total=2)

    def test_body_bytes_refresh_progress(self):
        with patch.object(fileserver.time, "monotonic", side_effect=[0, 5]):
            progress = fileserver.TransferProgress()
            response = fileserver.Response(progress=progress)
            response.add(b"abc")
        self.assertEqual(progress.last_activity, 5)
        self.assertEqual(response.count, 3)


if __name__ == "__main__":
    unittest.main()
