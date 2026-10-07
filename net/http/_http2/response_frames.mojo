"""Bounded HTTP/2 response frame generation."""

from .frame_encoder import FrameEncodeResult, encode_frame


def encode_headers_block[
    origin: Origin
](
    stream_id: UInt32,
    block: Span[Byte, origin],
    end_stream: Bool,
    max_frame_size: Int,
    max_output_bytes: Int,
) -> FrameEncodeResult:
    if (
        stream_id == UInt32(0)
        or stream_id > UInt32(0x7FFFFFFF)
        or max_frame_size < 1
        or max_frame_size > 0xFFFFFF
        or max_output_bytes < 9
    ):
        return FrameEncodeResult.failure()

    var output = List[Byte]()
    var offset = 0
    var first = True
    while first or offset < len(block):
        var remaining = len(block) - offset
        var chunk_length = min(remaining, max_frame_size)
        var final_chunk = chunk_length == remaining
        var frame_type = Byte(9)
        var flags = Byte(0)
        if first:
            frame_type = Byte(1)
            if end_stream:
                flags |= Byte(1)
        if final_chunk:
            flags |= Byte(4)
        var frame = encode_frame(
            frame_type,
            flags,
            stream_id,
            block[offset : offset + chunk_length],
            max_frame_size,
        )
        if not frame.is_complete() or len(frame.wire) > max_output_bytes - len(
            output
        ):
            return FrameEncodeResult.failure()
        output.extend(Span(frame.wire))
        offset += chunk_length
        first = False
    return FrameEncodeResult.complete(output^)
