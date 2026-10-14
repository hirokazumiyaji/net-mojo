# Synchronous HTTP/1.1 client

`net.http.Client` sends plaintext HTTP/1.1 and optional HTTPS over HTTP/1.1.
HTTP/2, HTTP/3, proxies, cookie jars, automatic decompression, authentication generation, CONNECT, Upgrade and WebSocket clients are outside this version's scope.

## Public API

Import `Client`, `ClientConfig`, `ClientRequest`, `ClientRequestBody`, `Response`, `ResponseBody`, `RedirectPolicy`, `ClientTLSConfig` and `ClientError` from `net.http`.

```mojo
from net.http import Client, ClientConfig, ClientRequest

var client = Client(ClientConfig.default())
var response = client.do(ClientRequest.get("http://127.0.0.1:8080/hello"))
print(response.status)
print(String(from_utf8_lossy=response.read_all()))
client.close()
```

`ClientRequest.get(url)` creates an empty GET; `ClientRequest.post_bytes(url, bytes)` owns a replayable byte body.
The general constructor accepts a method, absolute URL, `Headers`, `ClientRequestBody` and optional `Timeout` budget.
Request bodies currently support empty or owned bytes; streamed request sources remain future work.
`Host` and `Content-Length` are generated when absent, and configured `user_agent` is generated when absent and nonempty.
Caller framing must agree with the byte body; unsupported transfer encodings and header injection fail before connecting.

URLs accept only `http` and `https`, with default ports 80 and 443.
Userinfo, zero ports, percent escapes in hosts and scoped IPv6 literals are rejected.
Fragments are removed; target percent escapes are validated and retained without decoding.
IPv6 authorities use brackets, and equivalent IPv6 spellings share one pool origin.

`do` synchronously acquires a connection, sends the request and reads the final response head.
It returns `Response.status`, `reason`, `version`, `headers` and an owned streaming `body`.
Drive each Client sequentially; use independent Client instances for concurrent driving threads.
An HTTP error status such as 404 is a normal Response, not a ClientError.

## Response reading and ownership

`response.read(buffer)` and `response.body.read(buffer)` fill the existing `List[Byte]` prefix and return the byte count.
Use a nonempty buffer; zero means EOF (or an empty destination buffer).
Fixed length, chunked and connection-close bodies are read incrementally through bounded internal buffering.
HEAD, 1xx, 204 and 304 have no body, and informational heads are skipped before returning a final response.
Duplicate Content-Length, conflicting Content-Length/Transfer-Encoding, invalid chunk metadata and forbidden trailers are rejected.

`read_all(max_bytes=-1)` materializes bytes up to the explicit limit or `ClientConfig.max_response_body` by default.
The default limit is 1 MiB; larger bodies can still be consumed with streaming `read` calls.
Exceeding a materialization limit raises `BODY_TOO_LARGE` and closes the connection.
`Response.trailers()` returns an owned Headers snapshot; completed chunked trailers become available after EOF.

Consume the body to EOF to return a reusable connection to the pool.
`ResponseBody.discard()` drains without materializing the full body.
`Response.close()` drains fixed bodies with at most 64 KiB remaining within the request and idle timeout budgets; it closes other unfinished bodies.
Read, parse and timeout errors abort the lease.
Dropping an unfinished Response closes its connection rather than performing blocking cleanup.

A Response owns its connection and shared pool state, so it remains readable after Client close or destruction.
`Client.close()` closes idle sockets, prevents new requests with `CANCELED`, and leaves active responses with their owners.
Those active sockets close at completion instead of rejoining a closed pool.

## Budgets and pooling

| ClientConfig field | Default |
| --- | --- |
| `connect_timeout` | 5 s, including TLS handshake |
| `request_timeout` | 30 s |
| `response_header_timeout` | 5 s |
| `idle_conn_timeout` | 60 s |
| `max_idle_conns_per_host` | 2 |
| `max_conns_per_host` | 32, active plus idle |
| `max_response_headers_bytes` | 32768 |
| `max_response_headers_count` | 100 |
| `max_response_body` | 1048576, default read_all cap |
| `max_chunk_metadata` | 65536 |
| `max_trailer_bytes` | 8192 |
| `max_trailer_count` | 32 |
| `user_agent` | empty |
| `redirect` | follow, at most 10 hops |
| `tls` | absent |

`ClientRequest.deadline`, when supplied, replaces the default request budget.
One absolute internal deadline is created at `do` entry and remains in force through DNS, dialing, writes, redirects, retries and body reads.
Connection and response-head phase budgets are capped by that deadline.
The OS DNS resolver is blocking and cannot be interrupted; elapsed resolution time counts against the budget and is checked when resolution returns.

Pools are separate for `(scheme, canonical host, port)` origins and are not shared between Client instances.
Idle entries expire when acquired.
Full origins raise `POOL_FULL` immediately; requests do not queue.
Completed responses beyond the idle cap close immediately.
`Connection: close`, HTTP/1.0 and connection-close body framing disable reuse.

## Redirects and retries

`RedirectPolicy.never()` returns redirect responses to the caller.
The default follows 301, 302, 303, 307 and 308 with a Location, resolving absolute, network-path, path-relative, query-only and fragment-only references.
Inherited paths retain their original bytes; relative paths remove literal dot segments without decoding escapes.
Missing Location leaves the response unchanged; an invalid Location or exceeded hop limit raises `REDIRECT`.

301/302/303 preserve GET and HEAD; other methods become GET with an empty body and without Content-Length, Transfer-Encoding or Content-Type.
307/308 preserve method and the replayable byte body.
Cross-origin redirects remove Authorization, Cookie and caller Host headers; origins must match scheme, canonical host and effective port to retain them.
Discarded redirect payload failures close the old socket and do not prevent following a valid Location while the overall deadline remains.

A failed reused socket gets at most one automatic attempt on a fresh connection for GET, HEAD or a request carrying Idempotency-Key.
Only read/write failures before any response bytes qualify.
Partial final heads and informational responses prevent replay; fresh connection failures, parse errors, timeouts and completed response-body failures propagate.
The retry retains connection limits and the original request deadline.

## Optional TLS

```mojo
from net.http import Client, ClientConfig, ClientRequest, ClientTLSConfig

var config = ClientConfig.default()
var tls = ClientTLSConfig.default()
tls.ca_bundle_path = "/path/to/ca-bundle.pem"
config.tls = tls^
var client = Client(config^)
var response = client.do(ClientRequest.get("https://example.com/"))
var bytes = response.read_all()
client.close()
```

HTTPS requires explicit ClientTLSConfig and the native TLS provider.
The default library path is `build/tls/libnet_tls`; build it with `pixi run -e tls tls-build`.
Absent `ca_bundle_path` uses OpenSSL's default trust paths.
Trust and URL hostname/IP verification are enabled by default, with TLS 1.2 minimum.
DNS hosts send SNI; IP hosts omit it unless explicitly overridden.
A DNS root dot is removed for SNI and certificate identity matching while the HTTP authority retains it.
`sni_override` changes SNI without changing the identity verified against the URL.
`insecure_skip_verify` defaults to false and is intended for explicit test fixtures.

Only `http/1.1` ALPN is offered.
Absent negotiated ALPN is accepted as HTTP/1.1; another selected protocol is rejected.
TLS failures never trigger plaintext fallback.
TLS sessions retain native context and library ownership when responses outlive Client.

## Errors and validation

Client operations raise `ClientError` with `kind`, `message` and optional underlying `NetError` in `transport`.
Kinds are `DIAL`, `TLS`, `WRITE`, `READ`, `PARSE`, `REDIRECT`, `TIMEOUT`, `BODY_TOO_LARGE`, `POOL_FULL` and `CANCELED`.

Core tests cover codecs, streaming, 1000 keepalive requests, 32 live leases, pool limits, lifetimes, redirects and retries.
`pixi run -e tls-http2 tls-suite` includes native ownership, HTTPS client tests, independent Python TLS interoperability and the HTTPS client example.
Run `pixi run example-http-client`, `pixi run -e tls-http2 https-client-example-run` and `pixi run benchmark-http-client` for runnable loopback entrypoints.
The benchmark has no timing threshold and measures Client plus Server together.
