# net-mojo

`net-mojo` is a synchronous networking package for Mojo 1.0.0.
It provides IPv4 and IPv6 addresses, OS name resolution, TCP, UDP, and Unix stream sockets.
The runtime depends on Mojo `std` and the documented libc/POSIX ABI only.

The design rationale is documented in [docs/design/net-package.md](docs/design/net-package.md).

## Supported Platforms

| OS | Architecture | CI runner |
| --- | --- | --- |
| macOS | arm64, 64-bit | `macos-14` |
| Linux | x86_64, 64-bit | `ubuntu-24.04` |
| Linux | aarch64, 64-bit | `ubuntu-24.04-arm` |

Windows, 32-bit ABIs, and unlisted targets are outside the supported matrix.

## Installation

Install [pixi](https://pixi.sh/), then create the pinned environment from the repository root:

```bash
pixi install --frozen
```

Run a Mojo program with the repository on the import path:

```bash
pixi run example-tcp
```

Depend on a pinned source revision and put the repository on the import
path (`mojo run -I <repo> ...`). For a faster build, use the precompiled
artifact instead:

```bash
pixi run package
# then: mojo run -I build my_program.mojo  # `from net import ...`
```

Precompiled artifacts are tied to the compiler version that produced
them; rebuilding from source always works.

## Versioning and compatibility

Releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the version source of truth in `pixi.toml`. Changes are recorded in
[CHANGELOG.md](CHANGELOG.md). Public API is every name reachable from
`net` that does not start with an underscore; anything under `net/_sys/`
or starting with `_` is internal and may change without a version bump.

## Public API

Import public types and functions from `net`:

```mojo
from net import (
    IPAddress, SocketAddress, Timeout,
    dial_tcp, dial_udp, dial_unix,
    listen_tcp, listen_udp, listen_unix,
    resolve_socket_addresses,
)
```

Numeric addresses use `192.0.2.1`, `2001:db8::1`, and `[2001:db8::1]:443` forms.
IPv6 zones use `[fe80::1%en0]:443` or `[fe80::1%3]:443`.
Hostnames are resolved by synchronous OS `getaddrinfo`; resolver time is outside the connect timeout.
The resolver preserves OS candidate order and scans at most the first 64 `addrinfo` entries (skipped families included).
A wildcard host (`:port`, `[::]:port`) listens dual-stack (`IPV6_V6ONLY=0`) so IPv4 clients can connect; pass `ipv6_only=True` to restrict to IPv6 (Go `tcp6` equivalent). If IPv6 is unavailable, wildcard falls back to `0.0.0.0`.

Each operation converts its relative timeout to one absolute deadline.
`None` means no deadline, while zero means do not wait after the first immediate attempt.
TCP and Unix stream reads may be partial, and `write_all` loops until all bytes are written or an error occurs.
A `read` returning `0` means the peer shut down its write side (EOF), except on an empty buffer, which also returns `0`.
`dial_udp` returns connected mode for `read` and `write`; `listen_udp` returns unconnected mode for `recv_from` and `send_to`.
Connections and listeners own their descriptors through move-only types.
One thread can serve many connections: register each socket's `raw_fd()` with `Poller`, call `wait`, then use `try_read` / `try_write` / `try_accept` on the ready indices. A would-block `try_*` call reports `timeout` instead of waiting.
To release a thread blocked in `read`, call `shutdown` from another thread (only the raw fd number crosses threads; exactly one owner closes).
TCP connections default to `TCP_NODELAY=1` (Go parity); tune with
`set_no_delay`, `set_keep_alive`, `set_keep_alive_period`,
`set_read_buffer`, `set_write_buffer`, and `set_linger`.

Unix socket paths are never removed by the library.
Callers must remove a path after closing all descriptors.

## HTTP/1.1 origin server

`net.http` is a plaintext HTTP/1.1 origin server on a single event loop
(epoll on Linux, kqueue on macOS). Import from `net.http`, not from `net`:

```mojo
from net import listen_tcp
from net.http import Handler, Request, ResponseWriter, Server, ServerConfig

struct HelloHandler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/hello":
            writer.set_status(200)
            writer.write_string("hello")
        else:
            writer.set_status(404)
            writer.write_string("missing")

def main() raises:
    var server = Server(ServerConfig.default())
    var handler = HelloHandler()
    server.serve(listen_tcp("127.0.0.1:8080"), handler)
```

Constraints (see `docs/design/http-server.md` for the full contract):

- The handler runs synchronously on the loop thread. Blocking I/O or
  long CPU work inside `handle` stalls every connection.
- Bounded buffered requests only: the full body (up to
  `max_body_bytes`, default 1 MiB) is received before `handle` runs.
  Request streaming, response streaming, `Flush`, routers, and
  middleware are not included.
- `Request` views and `ResponseWriter` are valid only during the
  `handle` call. Copy values you want to keep; the server owns the
  receive buffer and the queued response.
- Plaintext origin server only. Terminate TLS in front; the server
  itself has no TLS, HTTP/2, or HTTP/3 support yet (Issue #42
  Phases 6-10).
- No client, no HTTP/1.0, no WebSocket/CONNECT/Upgrade switching, no
  multipart helpers, no body compression, no static file serving.

Resource bounds default to `max_connections=10,000`,
request line 8 KiB, headers 32 KiB / 100 entries, body 1 MiB,
response body 1 MiB, total buffer budget 256 MiB, header/body/write
deadlines 5 s / 30 s / 30 s, idle keep-alive 60 s, shutdown grace
30 s. Every value is enforced; see `net/http/config.mojo` and
`ServerConfig.default()`.

Shutdown is cooperative and single-threaded. Drive `add_listener` + `tick`
from the loop owner and call `server.request_shutdown()` between ticks;
that stops accepting, closes idle connections, drains in-flight requests
within the grace period, then makes `tick` return `False`:

```mojo
server.add_listener(listen_tcp("127.0.0.1:8080"))
while server.tick(handler):
    if should_stop:
        server.request_shutdown()
```

A running blocking `serve` cannot currently be stopped from another
thread or from the same thread: `ServerControl` is not thread-safe and
`serve_with_control` mutably borrows its `control` for the whole call,
so the handle cannot be used while `serve_with_control` runs.
Pre-requesting shutdown on the caller-held control before entry only
makes it exit promptly. Cross-thread shutdown with a wakeup fd is
future work. See `tests/test_http_server.mojo`
(`test_shutdown_drains_in_flight_and_exits`).

Reproduce the performance comparison with
`benchmarks/http/README.md` (Go baseline in `benchmarks/http_go`,
parser benchmark `pixi run benchmark-http-parse`, server benchmark
`pixi run benchmark-http-server`). CI does not gate on timing numbers.

## Examples, Benchmarks, and Tests

Examples are loopback-only and self-check their payloads:

```bash
pixi run example-tcp
pixi run example-udp
pixi run example-unix
```

Run the whole test suite with `pixi run test`, or a focused module with `pixi run test-tcp` and the analogous `test-core`, `test-ip`, `test-address`, `test-sys`, `test-udp`, `test-unix`, `test-poll`, `test-reactor`, `test-http-api`, `test-http-parser`, `test-http-response`, and `test-http-server` tasks.
Run benchmarks with `pixi run benchmark-ip`, `pixi run benchmark-loopback`, `pixi run benchmark-http-parse`, and `pixi run benchmark-http-server`.
Benchmarks report measurements and do not define pass or fail thresholds.
HTTP examples: `pixi run example-http-hello`, `pixi run example-http-json`.

## Development and CI

Format source with `pixi run format`.
CI runs the complete warning-clean suite on both supported runners and keeps separate AddressSanitizer steps.
Mojo 1.0.0 marks foundational standard APIs unstable, so CI uses `--Werror` without `--warn-on-unstable-apis`.
The local macOS arm64 toolchain may fail to resolve `___asan_*` runtime symbols before sanitizer tests start.

The initial release excludes asynchronous I/O, a custom DNS client, TLS, raw IP and multicast APIs, Linux abstract Unix sockets, Unix datagram sockets, Happy Eyeballs, Windows, and 32-bit ABIs.

## 日本語

`net-mojo` は Mojo 1.0.0 用の同期ネットワーク package です。
IPv4、IPv6、OS の名前解決、TCP、UDP、Unix stream socket を提供します。
runtime 依存は Mojo の `std` と文書化した libc/POSIX ABI だけです。

対応環境は macOS arm64 と Linux x86_64 / aarch64 です。
Windows、32-bit ABI、表にない target は対象外です。

環境は `pixi install --frozen` で構築します。
test は全体を `pixi run test`、個別を `pixi run test-tcp` のように実行します。
examples は loopback だけを使い、benchmarks は閾値を持たない測定プログラムです。
HTTP/1.1 origin server は `net.http` から利用します（`pixi run example-http-hello`）。
handler は loop 上で同期実行されるため、blocking 処理は入れません。
詳細は [docs/design/http-server.md](docs/design/http-server.md) を参照してください。

hostname は OS の同期 `getaddrinfo` で解決されます。
名前解決の時間は connect timeout に含まれません。
各操作は一つの絶対 deadline を使い、partial read、`write_all`、UDP の connected mode と unconnected mode を明確に区別します。

Unix socket の path は library が削除しません。
全 descriptor を close した後の削除は利用側が行います。
詳細な設計理由は [docs/design/net-package.md](docs/design/net-package.md) を参照してください。
