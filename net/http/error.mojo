"""HTTP error contract for `net.http`.

Transport failures keep using `net.NetError`. HTTP-level failures map
to a status code plus a close decision, following the Phase 0 policy:

- 400 malformed syntax, bad token, obs-fold, bad Host, CL/TE clash,
  bad chunk, bad trailer use, bad Expect handling.
- 413 decoded body over limit, chunk metadata over limit where the
  headers were otherwise valid.
- 414 request target over limit.
- 431 request line over limit (non-target part), header bytes or count
  over limit, trailer bytes or count over limit.
- 505 unsupported HTTP version.
- 417 unknown `Expect` value.
- 500 handler raised or response budget exceeded after headers were
  still unsent. Details never leak into the response body.
- 503 global buffer budget exhausted before the handler ran.

When the connection state cannot carry a response safely (for example
a framing error mid-body), the server closes without sending.
"""


@fieldwise_init
struct HttpError(Copyable, Movable, Writable):
    """Owned HTTP failure value returned to the server loop."""

    var status: Int
    var message: String
    var should_close: Bool

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.status)
        writer.write(" ")
        writer.write(self.message)

    @staticmethod
    def bad_request(var message: String) -> Self:
        return Self(status=400, message=message^, should_close=True)

    @staticmethod
    def payload_too_large(var message: String) -> Self:
        return Self(status=413, message=message^, should_close=True)

    @staticmethod
    def uri_too_long(var message: String) -> Self:
        return Self(status=414, message=message^, should_close=True)

    @staticmethod
    def header_too_large(var message: String) -> Self:
        return Self(status=431, message=message^, should_close=True)

    @staticmethod
    def version_not_supported(var message: String) -> Self:
        return Self(status=505, message=message^, should_close=True)

    @staticmethod
    def expectation_failed(var message: String) -> Self:
        return Self(status=417, message=message^, should_close=True)

    @staticmethod
    def internal(var message: String) -> Self:
        return Self(status=500, message=message^, should_close=True)

    @staticmethod
    def unavailable(var message: String) -> Self:
        return Self(status=503, message=message^, should_close=True)


def _status_reason(status: Int) -> String:
    if status == 100:
        return "Continue"
    if status == 200:
        return "OK"
    if status == 400:
        return "Bad Request"
    if status == 404:
        return "Not Found"
    if status == 413:
        return "Content Too Large"
    if status == 414:
        return "URI Too Long"
    if status == 417:
        return "Expectation Failed"
    if status == 431:
        return "Request Header Fields Too Large"
    if status == 500:
        return "Internal Server Error"
    if status == 503:
        return "Service Unavailable"
    if status == 505:
        return "HTTP Version Not Supported"
    return "Unknown"
