from net.http import ServerConfig
from net.http._http2.hpack import Http2HpackInflater


def main() raises:
    var config = ServerConfig.default()
    if config.max_http2_streams_per_connection <= 0:
        raise Error("packaged HTTP/2 server configuration failed")
    var inflater = Http2HpackInflater("build/http2/libnet_hpack", 4096)
    var block: List[Byte] = [Byte(0x82), Byte(0x86), Byte(0x84)]
    var output = Array[Byte, 128](fill=0)
    var result = inflater.decode(Span(block), 1024, 8, Span(output))
    if not result.is_success() or result.field_count != 3:
        raise Error("packaged HTTP/2 HPACK provider failed")
    print("packaged HTTP/2 provider succeeded")
