# Request body streaming measurements

Run `pixi run benchmark-http-body-stream` for HTTP/1.1 chunked uploads and
HTTP/2/HTTP/3 DATA uploads of 1 MiB, 16 MiB, and 256 MiB. Each size runs once
with streaming enabled and once with buffered input. The task builds the
optional TLS, HPACK, and QUIC providers and uses Python h2 and aioquic clients.
No throughput or memory threshold determines success.

The streaming handler transfers an owned `RequestBodyReceiver` into one
WorkerPool job. Both the input queue and worker scratch buffer are 64 KiB.
The job counts decoded bytes and checks the final `X-Result: done` trailer.
The buffered handler counts `req.body` and checks the same trailer. Clients
send bounded chunks, respect HTTP/2 flow control, and keep aioquic's
unacknowledged upload buffer below approximately three 64 KiB chunks.

Each result is one JSON object. `elapsed_seconds` measures from request
submission on an established connection until the count response completes;
TLS and QUIC connection establishment are excluded. `throughput_mib_per_second`
is decoded body bytes divided by that time. All completed uploads require the
server's count to equal the requested size.

The driver compiles once, then starts a fresh server process for every
protocol, mode, and size. `/usr/bin/time -l` on macOS or `-v` on Linux measures
`peak_server_rss_bytes` for that server process, including native providers,
startup, and shutdown. Compiler and client memory are excluded. This is peak
resident memory, rather than only the configured Mojo buffer accounting.
A missing RSS measurement is reported as JSON null.

Streaming `max_body_bytes` is 64 KiB. Buffered `max_body_bytes` equals the
measured upload size, and both modes use a 1 GiB shared Mojo budget. The QUIC
receive pool has a 512 MiB request byte budget. Its buffered request storage
also has a fixed 64 MiB aggregate limit, so the 256 MiB HTTP/3 buffered baseline
is reported with `outcome: "failed"` and a reset instead of a throughput value.
The streaming 256 MiB HTTP/3 upload can complete because consumed input releases
storage and flow credit. Failed buffered measurements remain visible in the
output; failed streaming measurements make the command exit unsuccessfully.

For a shorter run in the combined provider environment:

```sh
pixi run -e http-stream-sse python benchmarks/http_body_stream.py --sizes-mib 1 --protocols h1 h2 h3 --modes streaming
```

Use `--binary /absolute/path/to/fixture` to run a previously compiled fixture,
including one built with AddressSanitizer. The regular task excludes compiler
RSS even when it compiles the fixture itself. Results depend on the host,
provider versions, client pacing, and concurrent load; compare runs under the
same conditions.
