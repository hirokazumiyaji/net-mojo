#!/usr/bin/env python3
"""Pinned aioquic HTTP/3 baseline server for Issue #42 PR 10.

Pin: pixi feature.http3 `aioquic==1.3.0` (see pixi.toml).

Handlers match `benchmarks/http_go/main.go` / Mojo H2+H3 benches:
  GET /fixed  -> 64 B text/plain
  GET /json   -> exactly 1024 B application/json
  POST /echo  -> echo body (cap 1 MiB)

Usage (from repository root, after tls-build):
  pixi run -e tls-http3 python benchmarks/http3_aioquic_baseline.py \\
    --host 127.0.0.1 --port 18452 \\
    --certificate build/tls/test-cert.pem \\
    --private-key build/tls/test-key.pem
"""

from __future__ import annotations

import argparse
import asyncio
import logging
from typing import Dict, List, Optional, Tuple

import aioquic
from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived, H3Event
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated, QuicEvent

FIXED_BODY = b"a" * 64
_PAD = b'"pad":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",'
_JSON = (
    b"{"
    b'"id":1234567890,'
    b'"name":"net-mojo baseline payload",'
    b'"tags":["http","benchmark","baseline","mojo","go","server","api","test"],'
    b'"nested":{"a":1,"b":2,"c":3,"d":4,"e":5},'
    + _PAD * 8
    + b'"ok":true}'
)
if len(_JSON) < 1024:
    JSON_BODY = _JSON + (b" " * (1024 - len(_JSON)))
else:
    JSON_BODY = _JSON[:1024]

MAX_ECHO = 1 << 20


def _header_map(headers: List[Tuple[bytes, bytes]]) -> Dict[bytes, bytes]:
    return {k: v for k, v in headers}


class _PendingRequest:
    __slots__ = ("method", "path", "body", "ended")

    def __init__(self, method: bytes, path: bytes) -> None:
        self.method = method
        self.path = path
        self.body = bytearray()
        self.ended = False


class Http3BaselineProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._http: Optional[H3Connection] = None
        self._pending: Dict[int, _PendingRequest] = {}

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated):
            if event.alpn_protocol in H3_ALPN:
                self._http = H3Connection(self._quic)
        if self._http is None:
            return
        for http_event in self._http.handle_event(event):
            self._http_event_received(http_event)

    def _http_event_received(self, event: H3Event) -> None:
        assert self._http is not None
        if isinstance(event, HeadersReceived):
            existing = self._pending.get(event.stream_id)
            if existing is not None:
                # Trailers arrive as a second HeadersReceived without
                # pseudo-headers; retain the initial method/path/body.
                if event.stream_ended:
                    existing.ended = True
                    self._respond(event.stream_id, existing)
                return
            headers = _header_map(event.headers)
            method = headers.get(b":method", b"")
            path = headers.get(b":path", b"/")
            # Strip query for path match (handlers ignore query).
            path_only = path.split(b"?", 1)[0]
            req = _PendingRequest(method, path_only)
            self._pending[event.stream_id] = req
            if event.stream_ended:
                req.ended = True
                self._respond(event.stream_id, req)
        elif isinstance(event, DataReceived):
            req = self._pending.get(event.stream_id)
            if req is None:
                return
            if event.data:
                req.body.extend(event.data)
            if event.stream_ended:
                req.ended = True
                self._respond(event.stream_id, req)

    def _respond(self, stream_id: int, req: _PendingRequest) -> None:
        assert self._http is not None
        self._pending.pop(stream_id, None)
        status = b"200"
        content_type = b"text/plain"
        body = b""

        if req.method == b"GET" and req.path == b"/fixed":
            body = FIXED_BODY
            content_type = b"text/plain"
        elif req.method == b"GET" and req.path == b"/json":
            body = JSON_BODY
            content_type = b"application/json"
        elif req.method == b"POST" and req.path == b"/echo":
            if len(req.body) > MAX_ECHO:
                status = b"413"
                body = b"Content Too Large"
                content_type = b"text/plain"
            else:
                body = bytes(req.body)
                content_type = b"application/octet-stream"
        else:
            status = b"404"
            body = b"not found"

        self._http.send_headers(
            stream_id=stream_id,
            # Same header set as the Mojo handler (:status, content-type,
            # content-length): an extra `server` field would charge only
            # this baseline with additional QPACK bytes on the measured
            # 64-byte workload.
            headers=[
                (b":status", status),
                (b"content-type", content_type),
                (b"content-length", str(len(body)).encode()),
            ],
            end_stream=False,
        )
        self._http.send_data(stream_id=stream_id, data=body, end_stream=True)
        self.transmit()


async def _run(host: str, port: int, cert: str, key: str) -> None:
    configuration = QuicConfiguration(
        is_client=False,
        alpn_protocols=H3_ALPN,
    )
    configuration.load_cert_chain(cert, key)
    await serve(
        host,
        port,
        configuration=configuration,
        create_protocol=Http3BaselineProtocol,
    )
    logging.info(
        "aioquic %s HTTP/3 baseline listening on udp://%s:%s",
        aioquic.__version__,
        host,
        port,
    )
    await asyncio.Future()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18452)
    parser.add_argument(
        "--certificate", default="build/tls/test-cert.pem"
    )
    parser.add_argument(
        "--private-key", default="build/tls/test-key.pem"
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        asyncio.run(_run(args.host, args.port, args.certificate, args.private_key))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
