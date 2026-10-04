# Pinned quiche request cancellation patch

quiche 0.29.3 retains HTTP/3 stream state when a request is aborted before the
local send direction finishes. This also affects incomplete field sections and
resets consumed by `recv_body()`. The upstream issue is
[cloudflare/quiche#2524](https://github.com/cloudflare/quiche/issues/2524);
[PR #2709](https://github.com/cloudflare/quiche/pull/2709) remains incomplete.

The source-only patch adds `h3::Connection::cancel_request()` to shut down both
request directions and release H3 state and queued Finished events. Priority
updates cannot recreate a canceled request before peer final size arrives.
Already shut or collected request streams can be cancelled again; unknown stream IDs,
control streams and unexpected transport errors are rejected. The provider
keeps QPACK dynamic-table and blocked-stream limits at zero.

Both build and test scripts stage the public Cargo archive, verify SHA-256
`61166d27591eb7cb1310eec2b8fc6ae0e0686e9e4ed742a3ffc6317171175e7d`,
and apply the patch before compilation. Cargo's same-graph `paths` override
keeps the upstream version, dependency graph and lockfile unchanged. The
archive's license remains in the generated source and `quiche-COPYING`.

The 10,000-cancellation regression measures live Rust allocations released by
dropping the server's H3 object, independently of application byte counters.
This fixes H3 request-state retention; transport collected-ID bookkeeping and
total allocator/RSS limits remain separate work. The same real-protocol fixture
checks body, partial-field and response deadlines. `pixi run -e tls-http3 quic-suite`
also runs four patched-quiche API tests for both reset entry points, pending
Finished events and canceled/future-stream priority updates.
