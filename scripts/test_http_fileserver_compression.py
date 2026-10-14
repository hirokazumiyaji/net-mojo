#!/usr/bin/env python3
"""Run reviewed gzip middleware with the static file handler on all protocols."""

import argparse
import gzip
from pathlib import Path
import platform
import subprocess
import tempfile

from test_http_fileserver import Fixture, H1Client, H2Client, H3Client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--protocols", nargs="+", default=["h1", "h2", "h3"])
    args = parser.parse_args()
    binary = Path("build/http_fileserver_compression_fixture")
    binary.parent.mkdir(parents=True, exist_ok=True)
    command = ["mojo", "build", "--Werror", "-I", ".", "tests/http_fileserver_compression_fixture.mojo", "-o", str(binary)]
    if platform.system() == "Linux":
        command += ["-Xlinker", "-ldl"]
    subprocess.run(command, check=True)
    with tempfile.TemporaryDirectory(prefix="net-mojo-fs-gzip-") as directory:
        root = Path(directory)
        small = (b"static file gzip data\n" * 512)[:8192]
        large = (b"detached static file data\n" * 6000)[:131072]
        (root / "small.txt").write_bytes(small)
        (root / "large.txt").write_bytes(large)
        for protocol in args.protocols:
            mode = "h3" if protocol == "h3" else "tls" if protocol == "h2" else "plain"
            fixture = Fixture(binary, mode, root, False)
            client = H3Client(fixture.port) if protocol == "h3" else H2Client(fixture.port) if protocol == "h2" else H1Client(fixture.port, False)
            try:
                plain = client.request("GET", "/small.txt")
                compressed = client.request("GET", "/small.txt", (("Accept-Encoding", "gzip"),))
                assert compressed.status == 200
                assert compressed.values("content-encoding") == ["gzip"]
                assert compressed.values("content-length") == [str(compressed.count)]
                assert gzip.decompress(compressed.body) == small
                assert compressed.values("etag") == plain.values("etag")
                assert compressed.values("etag")[0].startswith('W/"')
                assert "accept-encoding" in ",".join(compressed.values("vary")).lower()
                selected = client.request("GET", "/small.txt", (("Accept-Encoding", "gzip"), ("Range", "bytes=2-8")))
                assert selected.status == 206
                assert not selected.values("content-encoding")
                assert bytes(selected.body) == small[2:9]
                assert selected.values("content-length") == ["7"]
                detached = client.request("GET", "/large.txt", (("Accept-Encoding", "gzip"),))
                assert detached.status == 200
                assert not detached.values("content-encoding")
                assert bytes(detached.body) == large
                assert detached.values("content-length") == [str(len(large))]
                head = client.request("HEAD", "/small.txt", (("Accept-Encoding", "gzip"),))
                assert head.status == 200 and head.count == 0
                assert head.values("content-length") == [str(len(small))]
                conditional = client.request("GET", "/small.txt", (("Accept-Encoding", "gzip"), ("If-None-Match", compressed.values("etag")[0])))
                assert conditional.status == 304 and conditional.count == 0
                print(f"FileServer+gzip {protocol}: full/gzip/Range/detached/HEAD/conditional PASS", flush=True)
            finally:
                fixture.close(client)
            assert fixture.peak_kib < 262144


if __name__ == "__main__":
    main()
