from std.ffi import c_int, c_size_t, c_ssize_t, external_call
from std.os import getenv

from net.http import ServerConfig
from net.http._authority import _host_is_valid
from net.http._parser import parse_one


comptime MAX_INPUT = 8192


def read_exact[
    origin: MutOrigin
](data: Span[mut=True, Byte, origin],) raises -> Bool:
    var offset = 0
    while offset < len(data):
        var received = external_call["read", c_ssize_t](
            c_int(0),
            data.unsafe_ptr().unsafe_offset(offset),
            c_size_t(len(data) - offset),
        )
        if received < 0:
            raise Error("cannot read fuzz input")
        if received == 0:
            if offset != 0:
                raise Error("truncated fuzz input")
            return False
        offset += Int(received)
    return True


def main() raises:
    var target = getenv("NET_FUZZ_TARGET")
    if target != "http1" and target != "authority":
        raise Error("NET_FUZZ_TARGET must be http1 or authority")
    var config = ServerConfig.default()
    var prefix = Array[Byte, 4](fill=0)
    var buffer = Array[Byte, MAX_INPUT](fill=0)
    var count = 0
    while read_exact(Span(prefix)):
        var length = 0
        for i in range(4):
            length = (length << 8) | Int(prefix[i])
        if length > MAX_INPUT:
            raise Error("fuzz input exceeds 8192 bytes")
        var data = Span(buffer)[0:length]
        if length > 0 and not read_exact(data):
            raise Error("missing fuzz input")
        if target == "http1":
            _ = parse_one(data, config)
        else:
            var text = String(from_utf8_lossy=data)
            _ = _host_is_valid(text)
        count += 1
    if count == 0:
        raise Error("empty fuzz corpus")
    print(target, "replayed", count, "inputs")
