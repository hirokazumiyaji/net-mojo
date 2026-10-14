# net-mojo

`net-mojo` is a synchronous networking package for Mojo 1.1.
It provides IPv4 and IPv6 addresses, OS name resolution, TCP, UDP, Unix stream
sockets, and an HTTP server with HTTP/1.1, HTTP/2, and HTTP/3 support.
The core runtime depends on Mojo `std` and the documented libc/POSIX ABI.
TLS, HTTP/2, and HTTP/3 are optional build environments with separate native
providers.

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

To release, set the same version in `pixi.toml` and
`conda.recipe/recipe.yaml`, move the CHANGELOG entries under
`## [X.Y.Z] - YYYY-MM-DD`, optionally add `docs/releases/vX.Y.Z.md`, and push
the tag `vX.Y.Z`. The Publish workflow checks that these agree, builds and
tests the conda package on every supported platform, uploads it to the
prefix.dev channel named by the `PREFIX_CHANNEL` repository variable (using
the `PREFIX_API_KEY` secret), and creates the GitHub Release.

Build and test the conda package locally with `bash scripts/build_conda.sh`.
Pull requests and manual Publish runs build packages without uploading to
prefix.dev or creating a Release. GitHub Releases include conda packages and
`net-<platform>.mojoc` artifacts for each supported target; rename the selected
artifact to `net.mojoc` before using it on the import path. Both distribution
formats require the exact Mojo compiler release that built them.

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

### Request body streaming

Set `config.enable_request_body_streaming = True` before constructing `Server`.
A streaming request has an empty `req.body`; its `body_reader().read(buffer)`
returns decoded bytes, zero at EOF, or `NetErrorKind.timeout()` when more input
is needed. The loop thread's read never blocks.
This interface applies to HTTP/1 Content-Length/chunked input and HTTP/2/HTTP/3
DATA. In streaming mode `max_body_bytes` bounds queued input, so a consumer can
process uploads larger than the queue. `total_buffer_budget` still bounds shared
Mojo queues; the QUIC provider also maintains its native receive pool limits.

For a worker, use `var endpoints = writer.detach_with_body(req)` and transfer
`endpoints^` into its owned context. `endpoints.receiver.receive(buffer, timeout)`
waits for input; `endpoints.sender` completes or streams the response.
`receiver.trailers()` becomes available after consumed EOF. Disconnects,
input deadlines and expired shutdown grace wake the receiver with
`NetErrorKind.cancelled()`.
Use `var reader = req.body_reader()` followed by `reader.detach()` to transfer
a receiver independently of response output.
An owned receiver keeps accepted input alive after a synchronous response FIN;
completed trailers remain available until the receiver is dropped.

Call `body_reader().discard()` to drain an unwanted body before reusing the
connection. An HTTP/1 synchronous response with an incomplete, undiscarded body
and no owned receiver closes the connection. HTTP/2 and HTTP/3 discard unclaimed
input while preserving response output. Streaming input progress renews `body_deadline`; response
and shutdown deadlines still apply.

Valid `Expect: 100-continue` receives informational headers before the handler
runs when input is incomplete. Unsupported expectations receive 417 without
handler dispatch. Accepted input can finish during graceful shutdown; grace
expiry cancels unfinished receivers.

Constraints (see `docs/design/http-server.md` for the full contract):

- The handler runs synchronously on the loop thread. HTTP/1, HTTP/2 and HTTP/3 handlers can
  move a `ResponseSender` returned by `writer.detach()` to a background
  thread for deferred or streaming responses.
- Request bodies are buffered by default, up to `max_body_bytes` (1 MiB).
  With `enable_request_body_streaming = True`, HTTP/1 handlers run after the
  headers arrive and use `req.body_reader()` to read decoded bytes. The limit
  then bounds queued body bytes; socket reads pause until the consumer drains
  them. HTTP/2 and HTTP/3 retain buffered request bodies in this slice.
- Response trailers: `writer.add_trailer(name, value)` queues a trailer
  on a buffered HTTP/1.1 response. The encoder switches to
  `Transfer-Encoding: chunked`, advertises the names in `Trailer:`, and
  emits the trailer section after the body (RFC 9112 §7.1.2). Framing-,
  routing-, authentication-, and payload-processing-sensitive names are
  rejected (RFC 9110 §6.5.1); HEAD and 1xx/204/205/304 responses drop
  trailers.
- `Request` owns its decoded strings, headers and body. The handler borrows
  that request and mutates the writer during `handle`; copy request fields
  you want to keep. Views borrow their source values, while public header
  getters return owned copies. The connection owns the queued response.
- HTTP/1.1 is supported over plaintext or opt-in TLS. HTTPS negotiates HTTP/2
  with ALPN `h2`; HTTP/3 uses a separately configured UDP endpoint and ALPN
  `h3`. Both protocols call the shared `Handler`.
- TLS/HTTP/2 and HTTP/3 provider dependencies are optional. Build and validate
  them with `pixi run -e tls-http2 tls-suite` plus
  `pixi run -e tls-http2 hpack-mojo-test`, and `pixi run -e tls-http3 quic-suite`
  plus `pixi run -e tls-http3 http3-client-test`.
- Same-origin HTTPS + HTTP/3: bind TCP and UDP on the same host:port (see
  `examples/http3_hello.mojo`), pass the same certificate/key to
  `TLSContext.server` (`h2,http/1.1`) and `QuicProvider.server_config` (`h3`),
  and replace `build/tls/test-*.pem` before deployment. UDP-unavailable hosts
  may serve HTTPS alone.
- `Alt-Svc` is opt-in. Set `ServerConfig.alt_svc` (for example
  `h3=":8443"; ma=86400`) only when the advertised QUIC endpoint is available.
  The server injects the configured value on TLS responses without probing that
  endpoint. Leave it empty when providing HTTPS alone. A handler-supplied
  `Alt-Svc` wins. See the [same-origin operation guide](docs/design/http3-server.md#same-origin-operation).
- HTTP/2 limits control frames, stream creation and resets. QUIC disables
  0-RTT and uses `quic_max_transport_memory_bytes` as a soft connection
  admission estimate. Receive backing and state entries have separate,
  finite provider-wide pools; these limits are not an engine RSS cap.
  Protocol behavior and unsupported features are in
  [HTTP/2](docs/design/http2-server.md) and [HTTP/3](docs/design/http3-server.md).
- HTTP/3 CI and independent-client coverage run on Linux x86_64 and aarch64;
  macOS end-to-end Mojo HTTP/3 validation runs in CI (`http3` on macos-14).
- No client, no HTTP/1.0, no WebSocket/CONNECT/Upgrade switching, no
  multipart helpers, no body compression, no static file serving.

### Method and path routing

`ServeMux` implements `Handler` and routes every HTTP protocol through the
same method/path table:

```mojo
from net.http import Request, ResponseWriter, ServeMux, ServerConfig, listen_and_serve

def greeting(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string(ServeMux.param(req, "name").value())

def main() raises:
    var mux = ServeMux()
    mux.handle("GET /hello/{name}", greeting)
    listen_and_serve("127.0.0.1:8080", ServerConfig.default(), mux)
```

Run the finite loopback example with `pixi run example-http-router`.
Patterns support literal segments, `{name}`, a final `{path...}`, subtree
paths such as `/static/`, and an exact final slash with `/static/{$}`.
GET patterns also match HEAD; more specific patterns win. Duplicate and
ambiguous routes fail at registration. A matching path with no matching
method returns 405 with a sorted `Allow` header; an unknown path returns 404.
Paths and captures retain their raw percent spelling.

Register routes before serving. `ServeMux()` permits at most 1024 routes;
each pattern is bounded to 1024 bytes, 32 segments and 16 named captures.
`ServeMux.param` returns an owned `Optional[String]` during the selected
handler call. Register concrete stateful handlers with `handle_handler`;
callbacks passed to `handle` must own their captures, using `{var value}`
or `{var value^}`. Captured views require their backing storage to outlive
the mux. Each mux and its handlers belong to one event loop.

### Function middleware

`MiddlewareFn` receives the request, writer and a borrowed `RouteHandler`.
Calling `next.handle(req, writer)` continues the chain; returning without
that call produces a response directly. `apply_middleware` consumes the
final handler and layers in outermost-first order:

```mojo
from net.http import MiddlewareFn, RouteHandler, apply_middleware

def trace(req: Request, mut writer: ResponseWriter, mut next: RouteHandler) raises:
    print(req.method, req.path)
    next.handle(req, writer)
    print(writer.status)

var layers = List[MiddlewareFn]()
layers.append(MiddlewareFn(trace))
mux.register("GET /hello/{name}", apply_middleware(RouteHandler(greeting), layers^))
```

Construct the chain before serving. Middleware callbacks own their captures
under the same contract as route callbacks. Errors propagate through `next`;
use `try`/`except` when cleanup must also run after an error.

### Handler middleware

`LoggingHandler[Inner, Sink]` owns an inner handler and an injected `LogSink`.
`StdoutLogSink` prints method, raw path, status and elapsed nanoseconds;
custom sinks can retain owned records. For example, wrap a mux with
`LoggingHandler[ServeMux](mux^, StdoutLogSink())`.
Escaping errors are logged as 500 and rethrown. Detached responses are
logged when the synchronous handler returns, before their eventual completion.

`RecoverHandler[Inner](inner^)` replaces a failed buffered response with
500, discarding its partial body, headers and trailers. Errors after detach
propagate to the server for cancellation.
`TimeoutHandler[Inner](inner^, timeout)` checks a monotonic deadline before
and after a synchronous call, replacing an expired successful response with
503. It cannot interrupt blocking work; inner errors propagate and detached
responses are unsupported. Replacement responses obey the writer's body
limit and shared buffer budget.

Optional provider pins live in `pixi.toml` (`openssl`, `libnghttp2`) and
`net/quic/provider/Cargo.toml` (quiche). After bumping a pin, refresh
`pixi.lock` / the provider `Cargo.lock`, rebuild the `tls-http2` /
`tls-http3` environments, and re-run the matching suites. Measured H2/H3
numbers are recorded in `benchmarks/http/README.md`.

### Response streaming and deferred responses

For long-running tasks (such as LLM token generation or async workers),
call `writer.detach()` to decouple the response from the event loop.
The returned `ResponseSender` is `Movable` and thread-safe on HTTP/1, HTTP/2
and HTTP/3. Move it to a worker, or retain it between server ticks. The event
loop sends the queued response data:

```mojo
from net.http import Handler, Headers, Request, ResponseWriter

struct SseHandler(Handler):
    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        if req.path == "/events":
            var sender = writer.detach()
            var headers = Headers()
            headers.add("content-type", "text/event-stream")
            sender.start(200, headers^)
            if sender.send(String("data: ready\n\n").as_bytes()):
                sender.finish()
```

- **Deferred response**: `sender.respond(status, headers, body)` sends a
  standard Content-Length response asynchronously.
- **Streaming response**: `sender.start(status, headers)` begins the response,
  `sender.send(chunk)` queues chunks, and `sender.finish()`
  completes the stream. Pass `sender.finish(trailers=trailers)` to send
  validated trailing headers after the final body chunk. Framing and routing
  headers are rejected, and trailer storage counts against the server budget.
  HTTP/1.1 uses chunked encoding; HTTP/2 and HTTP/3 use DATA frames.
- **Backpressure**: On HTTP/2 and HTTP/3, `sender.send(...)` returns `False`
  when its bounded queue is full. Retain the chunk and retry after the loop
  drains output. `sender.is_cancelled()` distinguishes terminal cancellation.
  HTTP/1 queue overflow and shared buffer budget exhaustion raise and cancel
  the response.
- **Cancellation**: Client disconnect, deadline expiry or shutdown cancels
  the sender. HTTP/2 and HTTP/3 cancel the affected stream while sibling
  streams continue.
- **Thread safety**: Background threads never touch socket descriptors
  directly; messages are queued and the event loop wakes up via a
  nonblocking wakeup channel (`socketpair`).

See `examples/http_sse.mojo` for a complete runnable Server-Sent Events example.

Run `pixi run benchmark-http-stream-sse` to measure HTTP/2 and HTTP/3 with
100 concurrent streams and 1,000 events per second per stream for one second.
The JSON output records received event counts, elapsed time, achieved event
rate, p99 request-to-headers TTFB and p99 scheduled-event-to-receipt latency.
The loopback driver checks clock compatibility and complete, ordered delivery;
latency measurements have no pass/fail threshold.

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

`ServerControl` is copyable and thread-safe. Keep a copy of `server.control`
before handing the server to its loop thread, or supply a shared control to
`serve_with_control` / `listen_and_serve_with_control`. Calling
`control.request_shutdown()` from another thread wakes the reactor immediately.
The loop owner stops accepting and drains requests; the calling thread never
operates on server sockets. Repeated requests are harmless, and copies can
outlive the server: requests after completion, an error, or server destruction
are successful no-ops. Synchronous handlers must still return before shutdown
can progress. See `tests/test_http_control.mojo` and
`test_shutdown_drains_in_flight_and_exits` in `tests/test_http_server.mojo`.

### Multiple HTTP workers

`ServerPool` runs independent event loops on OS threads over one shared TCP
listener. Each connection stays on the worker that accepted it. The factory
builds a separate handler for each worker before any worker starts. Using `HelloHandler` above:

```mojo
from net.http import HandlerFactory, ServerConfig, listen_and_serve_pool

struct HelloFactory(HandlerFactory):
    comptime HandlerType = HelloHandler

    def __init__(out self):
        pass

    def build(mut self, worker_id: Int) raises -> HelloHandler:
        return HelloHandler()

def main() raises:
    var factory = HelloFactory()
    listen_and_serve_pool("127.0.0.1:8080", ServerConfig.default(), factory, workers=4)
```

`workers=0` detects online CPUs; explicit counts are clamped to 1–1024.
`DefaultHandlerFactory[H](handler)` copies a `Copyable` handler for each worker.
Any state deliberately shared by handlers must support concurrent access.
`Server` and `listen_and_serve` continue to run one event loop.

Every `ServerConfig` bound is **per worker**: four workers with the default
configuration allow up to 40,000 TCP connections and 1 GiB of aggregate buffer
budget. A synchronous handler blocks its own worker, and must return before
that worker can process a shutdown request.

For a custom listener or TLS, construct `ServerPool(config, workers=N)`, call
`add_listener(listener^)` or `add_tls_listener(listener^, tls_context^)`, then
`serve(factory)`. Keep a copy from `pool.control()` to request shutdown from
another thread. Each worker has its own wakeup channel; one request wakes all
workers. `serve` joins every worker before returning and propagates startup or
worker errors after shutdown cleanup. A pool serves once. Linux listener
registrations use `EPOLLEXCLUSIVE`; macOS uses kqueue and handles competing
accepts as would-block.

`add_quic_endpoint(endpoint^)` assigns QUIC/HTTP/3 exclusively to worker zero.
Other workers serve TCP/TLS; a pool with only QUIC runs one worker. See
`examples/http3_pool_hello.mojo` and run
`pixi run -e tls-http3 http3-pool-example-run`.

Run `pixi run test-http-pool` and
`pixi run -e tls-http2 http-pool-integration-test` for plain/TLS HTTP/1.1 and
HTTP/2 coverage. `pixi run -e tls-http3 http-pool-quic-integration-test`
checks mixed TCP/QUIC and QUIC-only pools.

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

Run the whole test suite with `pixi run test` (and memory sanitizers with
`pixi run sanitize`), or a focused module with `pixi run test-tcp` and the
analogous `test-core`, `test-ip`, `test-address`, `test-sys`, `test-udp`,
`test-unix`, `test-poll`, `test-reactor`, `test-http-api`, `test-http-parser`,
`test-http-response`, `test-http-server`, `test-http2`, `test-http-detach`, and
`test-actor` tasks.
The default Pixi environment uses Mojo 1.1.
Run benchmarks with `pixi run benchmark-ip`, `pixi run benchmark-loopback`, `pixi run benchmark-http-parse`, `pixi run benchmark-http-server`, and `pixi run benchmark-http-stream`.
Benchmarks report measurements and do not define pass or fail thresholds.
HTTP examples: `pixi run example-http-hello`, `pixi run example-http-json`, and `pixi run example-http-sse`. Optional protocol examples are `examples/http2_hello.mojo` (`pixi run -e tls-http2 http2-example-build`) and `examples/http3_hello.mojo` (`pixi run -e tls-http3 http3-example-build`). The HTTPS, HTTP/2, and HTTP/3 examples use test certificate paths generated by `tls-build`; replace them before deployment. The HTTP/3 example binds TCP and UDP on the same port. Run TLS interoperability with `pixi run -e tls-http2 tls-suite` and `pixi run -e tls-http3 http3-client-test`.

## Development and CI

Format source with `pixi run format`.
CI runs the complete warning-clean suite on all supported runners and keeps separate AddressSanitizer steps defined in `pixi.toml`.
Mojo marks foundational standard APIs unstable, so CI uses `--Werror` without `--warn-on-unstable-apis`.
Parser mutation smoke runs with `pixi run -e fuzz fuzz-smoke`; scheduled
Linux replay retains input batches and native corpora. See
[tests/fuzz/README.md](tests/fuzz/README.md) for targets and reproduction.
Sanitizer tasks build standalone ASan executables in the dedicated `sanitize` environment.
macOS uses a pinned upstream LLVM runtime; Linux requires a system C compiler, such as GCC.

The package excludes asynchronous I/O, a custom DNS client, raw IP and
multicast APIs, Linux abstract Unix sockets, Unix datagram sockets, Happy
Eyeballs, Windows, and 32-bit ABIs. TLS and HTTP/2/HTTP/3 providers are
optional and are not required by the core `net` package.

## 日本語

`net-mojo` は Mojo 1.1 用の同期ネットワーク package です。
IPv4、IPv6、OS の名前解決、TCP、UDP、Unix stream socket を提供します。
core runtime 依存は Mojo の `std` と文書化した libc/POSIX ABI です。
HTTP/2 と HTTP/3 は TLS／protocol provider を含む optional environment で
利用できます。

対応環境は macOS arm64 と Linux x86_64 / aarch64 です。
Windows、32-bit ABI、表にない target は対象外です。

環境は `pixi install --frozen` で構築します。
test は全体を `pixi run test`、個別を `pixi run test-tcp` のように実行します。
examples は loopback だけを使い、benchmarks は閾値を持たない測定プログラムです。
HTTP server は `net.http` から利用します（`pixi run example-http-hello`）。
HTTPS は ALPN `h2` を交渉し、HTTP/3 は UDP endpoint を追加して ALPN `h3` を
利用します。
handler は loop 上で同期実行されますが、`writer.detach()` を呼ぶことで別スレッドへの応答切り離し（遅延応答・SSE レスポンスストリーミング）が可能です（`pixi run example-http-sse`）。
詳細は [docs/design/http-server.md](docs/design/http-server.md) を参照してください。

hostname は OS の同期 `getaddrinfo` で解決されます。
名前解決の時間は connect timeout に含まれません。
各操作は一つの絶対 deadline を使い、partial read、`write_all`、UDP の connected mode と unconnected mode を明確に区別します。

Unix socket の path は library が削除しません。
全 descriptor を close した後の削除は利用側が行います。
詳細な設計理由は [docs/design/net-package.md](docs/design/net-package.md) を参照してください。
