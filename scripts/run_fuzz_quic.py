#!/usr/bin/env python3
"""Run the bounded, sanitizer-instrumented local QUIC provider receive target."""

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from run_fuzz import MAX_INPUT, positive


def seeds() -> list[bytes]:
    packets = [b"", b"\xc0", b"\x40\x00", bytes.fromhex("c00000000108010203040506070800"),
               bytes.fromhex("e00000000108010203040506070800"),
               bytes.fromhex("f00000000108010203040506070800")]
    batches = [struct.pack(">H", len(packet)) + packet for packet in packets]
    client = QuicConnection(configuration=QuicConfiguration(
        is_client=True, alpn_protocols=["h3"], server_name="localhost"))
    client.connect(("127.0.0.1", 4433), now=0)
    initial = b"".join(struct.pack(">H", len(packet)) + packet
                       for packet, _ in client.datagrams_to_send(now=0))
    return batches + [b"".join(batches), b"\xff\xff" + packets[3],
                      initial, initial + batches[1]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=positive, default=60)
    parser.add_argument("--seed", type=int, default=227)
    parser.add_argument("--replay", type=Path)
    args = parser.parse_args()
    root = Path("build/fuzz")
    corpus = root / "quic-recv-corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    for index, data in enumerate(seeds()):
        (corpus / f"seed-{index}").write_bytes(data)
    metadata = {"target": "quic-recv", "seed": args.seed, "seconds": args.seconds,
                "max_input": MAX_INPUT, "corpus": str(corpus),
                "input_format": "two-byte big-endian datagram lengths"}
    (root / "quic-recv-nightly.json").write_text(json.dumps(metadata, indent=2) + "\n")
    env = dict(os.environ, NET_HTTP_TEST_CERT=str(Path("build/tls/test-cert.pem").resolve()),
               NET_HTTP_TEST_KEY=str(Path("build/tls/test-key.pem").resolve()))
    command = [str(root / "quic-recv")]
    if args.replay:
        command += [str(args.replay), "-runs=1"]
    else:
        command += [str(corpus), f"-max_total_time={args.seconds}", f"-seed={args.seed}",
                    "-timeout=10", "-rss_limit_mb=2048", f"-max_len={MAX_INPUT}",
                    f"-artifact_prefix={root}/quic-recv-"]
    log = root / "quic-recv.log"
    print(f"QUIC receive log: {log}", flush=True)
    try:
        with log.open("w") as output:
            subprocess.run(command, env=env, check=True, timeout=args.seconds + 30,
                           stdout=output, stderr=subprocess.STDOUT)
    finally:
        print(log.read_text()[-16000:], flush=True)


if __name__ == "__main__":
    main()
