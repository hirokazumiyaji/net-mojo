# Static file serving

`FileServer` implements the shared `Handler` contract for HTTP/1.1, HTTP/2,
and HTTP/3. Register it with a final `{path...}` capture named `path`:

```mojo
from net.http import ServeMux, file_server

var mux = ServeMux()
mux.handle("GET /static/{path...}", file_server("./public"))
```

The captured path is resolved relative to the configured root. Without a
`path` capture, the handler uses `req.path`. A GET route also accepts HEAD.
Other methods handled directly by `FileServer` return 405 with `Allow: GET, HEAD`.

## Filesystem boundary

`FileSystem.dir(path, follow_symlinks=False)` pins an opened directory.
Copies share that root descriptor. Resolution uses descriptor-relative opens,
rejects NUL, `.` and `..` segments, and accepts only regular files and
directories. Request paths retain their raw percent spelling.

Symlinks are refused by default. With `follow_symlinks=True`, relative links
may move through pinned ancestors only within the root; absolute links must
resolve within its canonical path. Traversal is limited to 40 links and 4096
expanded bytes. Path components are limited to 255 bytes. Replacing a pathname
does not replace a descriptor already selected for serving.

`FileSystem.open` returns an owned internal file handle with size, nanosecond
mtime, directory kind and positional reads. The HTTP layer strips duplicate
slashes and redirects directory paths to a trailing slash and regular file
paths away from one. Redirects retain the full mounted request path and query.
Traversal and backslashes are rejected before redirecting.

## Response selection

Defaults select `index.html` for a directory. Directory listing is disabled;
a directory without an index returns 404. Optional listings are plain text,
limited to 256 entries, and escape control characters and backslashes.

Regular files include `Content-Type`, `Content-Length`, `Last-Modified`,
`Accept-Ranges: bytes`, and a weak `W/"mtime_ns-size"` ETag. Known extensions
use the MIME table; unknown extensions sniff at most 512 prefix bytes.
`FileETagMode.disabled()` omits the ETag. `cache_control` adds a configured
Cache-Control field. Other middleware headers are preserved.

The conditional order is If-Match, If-Unmodified-Since when If-Match is absent,
If-None-Match, and If-Modified-Since when If-None-Match is absent. Weak validators
can satisfy If-None-Match; If-Match requires a strong comparison. Matching
If-None-Match or If-Modified-Since returns 304 without a body or Content-Length.
Failed preconditions return 412.

GET accepts one byte range: closed, open-ended, or suffix. An unsatisfiable
range returns 416 with `Content-Range: bytes */size`. Multiple ranges or unknown
units are ignored. If-Range requires an exact date match; the default weak ETag
cannot satisfy its strong comparison. HEAD ignores Range and advertises the
full selected file representation without sending its content.

## Memory and ownership

`FileServerConfig` defaults `max_in_memory_body` to 64 KiB, a 1 GiB maximum
file size, two workers and 64 pending jobs. Worker and file limits are checked
at construction; a zero pending queue refuses every streamed submission with
503 and Retry-After. Oversized files return 404.

Small files are read before successful response metadata is applied. Larger
responses detach and enqueue an owned job in the handler's long-lived worker
pool. A job owns only its file descriptor, headers, selected offset and length,
a prefix of at most 512 bytes, and a read scratch buffer of at most 64 KiB.
Chunk size is also capped by the response queue. `try_send` waits for queue
credit on a worker and observes cancellation between retries. The event loop
retains socket ownership and drains the chunks across all three protocols.

The selected length is fixed. Growth cannot add bytes to a response; truncation
or later read failure aborts its stream. Read errors before metadata becomes
visible produce a clean 500 response. The handler must remain owned by the
server or mux while serving; shutdown follows the WorkerPool grace policy.

`serve_file(req, writer, fs, path)` serves an explicit relative path without
HTTP directory redirects or index lookup. Its large-file path starts an
independently owned detached thread. The helper and filesystem may be dropped
after it returns. Thread startup failure produces a clean 500 response.
For repeated or concurrent service, use the bounded `FileServer` worker pool.

There is no sendfile path or multipart range support. Optional compression
middleware must preserve these validators and range semantics.

## Validation

- `pixi run test-http-filesystem` and `pixi run test-http-fileserver` cover
  confinement, validators, ranges, indexes, canonical paths and worker ownership.
- `pixi run test-http-fileserver-wire` hashes a complete 1 GiB HTTP/1 transfer,
  checks wire framing, measures native peak RSS below 256 MiB, and checks the
  server's buffer budget is empty after shutdown.
- Matching `sanitize-*` tasks run the same core paths under AddressSanitizer.
- `pixi run -e tls-http2 http-fileserver-h2-test` and
  `pixi run -e tls-http3 http-fileserver-h3-test` run the shared wire cases and
  1 GiB transfers with independent protocol clients.

The HTTP/1 driver requests connection closure and reads through EOF, rejecting
body bytes beyond Content-Length and any content on HEAD.
`pixi run test-http-fileserver-driver` covers early EOF and delayed excess bytes.

The wire fixture builds its native binary before RSS sampling. Clients hash
large bodies incrementally, retaining at most 256 KiB for comparisons.

The ASAN wire fixture fixes its freed-allocation quarantine to 16 MiB and
its thread-local quarantine to 64 KiB. This keeps diagnostic retention bounded
while the full 1 GiB transfer exercises redzones and ownership checks.
