from std.time import perf_counter_ns

from net.http import ServerConfig
from net.http._parser import parse_one


def _to_bytes(data: StringSlice) -> List[Byte]:
    var out = List[Byte]()
    var bytes = data.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _bench(name: String, raw: List[Byte], iterations: Int) raises -> Float64:
    var config = ServerConfig.default()
    # Warmup to settle caches before timing.
    for _ in range(100):
        var warm = parse_one(Span(raw), config)
        if not warm.is_complete():
            raise Error(String("warmup parse failed for ") + name)
    var started = perf_counter_ns()
    var consumed_total = 0
    for _ in range(iterations):
        var result = parse_one(Span(raw), config)
        if not result.is_complete():
            raise Error(String("benchmark parse failed for ") + name)
        consumed_total += result.consumed
    var elapsed = perf_counter_ns() - started
    if elapsed <= 0:
        raise Error("monotonic clock did not advance")
    if consumed_total == 0:
        raise Error("parser consumed no bytes")
    return Float64(elapsed) / Float64(iterations)


def main() raises:
    var small_get = _to_bytes(
        "GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )
    var json_post_head = String(
        "POST /json HTTP/1.1\r\nHost: example.com\r\nContent-Type:"
        " application/json\r\nContent-Length: 1024\r\n\r\n"
    )
    var json_body = List[Byte]()
    var head_bytes = json_post_head.as_bytes()
    for i in range(len(head_bytes)):
        json_body.append(head_bytes[i])
    for i in range(1024):
        json_body.append(Byte(ord("a") + (i % 26)))
    var chunked_head = String(
        "POST /chunked HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding:"
        " chunked\r\n\r\n"
    )
    var chunked = List[Byte]()
    var chunked_head_bytes = chunked_head.as_bytes()
    for i in range(len(chunked_head_bytes)):
        chunked.append(chunked_head_bytes[i])
    # 16 x 1 KiB chunks plus terminator, exercising chunk framing.
    for _ in range(16):
        var size_line = String("400\r\n").as_bytes()
        for i in range(len(size_line)):
            chunked.append(size_line[i])
        for i in range(1024):
            chunked.append(Byte(ord("b") + (i % 26)))
        var crlf = String("\r\n").as_bytes()
        for i in range(len(crlf)):
            chunked.append(crlf[i])
    var tail = String("0\r\n\r\n").as_bytes()
    for i in range(len(tail)):
        chunked.append(tail[i])

    var small_ns = _bench("small-get", small_get, 20000)
    var json_ns = _bench("json-post-1k", json_body, 5000)
    var chunked_ns = _bench("chunked-16k", chunked, 1000)
    print("parser time per request (ns):")
    print("  small-get:", small_ns, "input bytes:", len(small_get))
    print("  json-post-1k:", json_ns, "input bytes:", len(json_body))
    print("  chunked-16k:", chunked_ns, "input bytes:", len(chunked))
    print(
        "throughput (MiB/s):",
        Float64(len(chunked)) * 1000000000.0 / chunked_ns / 1048576.0,
        "(chunked input)",
    )
