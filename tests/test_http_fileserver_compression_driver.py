import gzip
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import test_http_fileserver_compression as driver
from test_http_fileserver import Response


SMALL = (b"static file gzip data\n" * 512)[:8192]
LARGE = (b"detached static file data\n" * 6000)[:131072]


class Fixture:
    def __init__(self, binary, mode, root, sanitize):
        self.port = 0
        self.peak_kib = 1

    def close(self, client):
        pass


class Client:
    identity_gzip = False
    bad_vary = False

    def __init__(self, port, tls):
        pass

    def request(self, method, path, headers=()):
        fields = dict(headers)
        response = Response(status=200)
        response.headers = [("etag", 'W/"mtime-size"')]
        body = SMALL if path == "/small.txt" else LARGE
        if "If-None-Match" in fields:
            response.status = 304
            return response
        if method == "HEAD":
            response.headers.append(("content-length", str(len(body))))
            return response
        if "Range" in fields:
            response.status = 206
            body = body[2:9]
        elif path == "/small.txt" and (fields.get("Accept-Encoding") == "gzip" or self.identity_gzip):
            body = gzip.compress(body)
            response.headers.extend([("content-encoding", "gzip"), ("vary", "X-Accept-Encoding" if self.bad_vary else "Accept-Encoding")])
        response.headers.append(("content-length", str(len(body))))
        response.add(body)
        return response


class DriverTests(unittest.TestCase):
    def run_driver(self, protocol="h1"):
        with patch.object(sys, "argv", ["driver", "--protocols", protocol]), patch.object(driver.subprocess, "run"), patch.object(driver, "Fixture", Fixture), patch.object(driver, "H1Client", Client):
            driver.main()

    def test_valid_contract_passes(self):
        self.run_driver()

    def test_unknown_protocol_is_rejected(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_driver("h4")
        self.assertEqual(raised.exception.code, 2)

    def test_identity_get_cannot_be_gzip(self):
        with patch.object(Client, "identity_gzip", True), self.assertRaises(AssertionError):
            self.run_driver()

    def test_vary_requires_exact_accept_encoding_token(self):
        with patch.object(Client, "bad_vary", True), self.assertRaises(AssertionError):
            self.run_driver()


if __name__ == "__main__":
    unittest.main()
