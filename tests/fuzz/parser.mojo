from std.ffi import c_int, c_size_t, c_ssize_t, external_call
from std.os import getenv
from std.testing import assert_equal, assert_true

from net import IPAddress, SocketAddress
from net.error import NetErrorKind

from net.http import ServerConfig
from net.http._authority import _host_is_valid
from net.http._parser import parse_one
from net.http._http2.frame import parse_frame
from net.http._http2.frame_reader import Http2FrameReader
from net.http._http2.hpack import Http2HpackDeflater, Http2HpackInflater


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


def fuzz_frames[origin: ImmOrigin](data: Span[Byte, origin]) raises:
    var offset = 0
    while offset < len(data):
        var result = parse_frame(data[offset:])
        if not result.is_complete():
            break
        assert_true(
            result.consumed >= 9 and result.consumed <= len(data) - offset
        )
        offset += result.consumed
    var reader = Http2FrameReader()
    offset = 0
    var chunk = 1 if len(data) == 0 else 1 + Int(data[0])
    while offset < len(data):
        var end = min(offset + chunk, len(data))
        var result = reader.consume(data[offset:end])
        if result.is_error():
            break
        assert_true(result.consumed > 0 and result.consumed <= end - offset)
        offset += result.consumed


def fuzz_hpack[origin: ImmOrigin](data: Span[Byte, origin]) raises:
    var output = Array[Byte, MAX_INPUT](fill=0)
    var inflater = Http2HpackInflater("build/fuzz/libnet_hpack", 4096)
    var decoded = inflater.decode(data, MAX_INPUT, 128, Span(output))
    assert_true(
        decoded.output_length >= 0 and decoded.output_length <= MAX_INPUT
    )
    var deflater = Http2HpackDeflater("build/fuzz/libnet_hpack", 4096)
    var encoded = deflater.encode(data, MAX_INPUT, 128, Span(output))
    assert_true(
        encoded.output_length >= 0 and encoded.output_length <= MAX_INPUT
    )
    if encoded.is_success():
        var roundtrip = Array[Byte, MAX_INPUT](fill=0)
        var decoder = Http2HpackInflater("build/fuzz/libnet_hpack", 4096)
        var decoded_again = decoder.decode(
            Span(output)[0 : encoded.output_length],
            MAX_INPUT,
            128,
            Span(roundtrip),
        )
        assert_true(decoded_again.is_success())
        assert_equal(decoded_again.output_length, len(data))
        for i in range(len(data)):
            assert_equal(roundtrip[i], data[i])


def fuzz_address(target: StringSlice, text: StringSlice) raises:
    try:
        if target == "ip":
            _ = String(IPAddress.parse(text))
        else:
            _ = String(SocketAddress.parse(text))
    except error:
        if error.kind != NetErrorKind.invalid_address():
            raise error


def main() raises:
    var target = getenv("NET_FUZZ_TARGET")
    if (
        target != "http1"
        and target != "authority"
        and target != "http2-frames"
        and target != "ip"
        and target != "address"
        and target != "hpack-mojo"
    ):
        raise Error("unknown NET_FUZZ_TARGET")
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
        elif target == "http2-frames":
            fuzz_frames(data)
        elif target == "hpack-mojo":
            fuzz_hpack(data)
        else:
            var text = String(from_utf8_lossy=data)
            if target == "authority":
                _ = _host_is_valid(text)
            else:
                fuzz_address(target, text)
        count += 1
    if count == 0:
        raise Error("empty fuzz corpus")
    print(target, "replayed", count, "inputs")
