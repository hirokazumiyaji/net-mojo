"""Bounded HTTP/2 response frame generation."""

from .frame_encoder import FrameEncodeResult, encode_frame


def _append_wire(mut output: List[Byte], frame: List[Byte]):
    output.extend(Span(frame))


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
        if (
            not frame.is_complete()
            or len(frame.wire) > max_output_bytes - len(output)
        ):
            return FrameEncodeResult.failure()
        _append_wire(output, frame.wire)
        offset += chunk_length
        first = False
    return FrameEncodeResult.complete(output^)


def encode_data_frames[
    origin: Origin
](
    stream_id: UInt32,
    body: Span[Byte, origin],
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
    while offset < len(body):
        var chunk_length = min(len(body) - offset, max_frame_size)
        var final_chunk = offset + chunk_length == len(body)
        var flags = Byte(0)
        if end_stream and final_chunk:
            flags |= Byte(1)
        var frame = encode_frame(
            Byte(0),
            flags,
            stream_id,
            body[offset : offset + chunk_length],
            max_frame_size,
        )
        if (
            not frame.is_complete()
            or len(frame.wire) > max_output_bytes - len(output)
        ):
            return FrameEncodeResult.failure()
        _append_wire(output, frame.wire)
        offset += chunk_length
    if len(body) == 0 and end_stream:
        var empty = List[Byte]()
        var frame = encode_frame(Byte(0), Byte(1), stream_id, Span(empty))
        if (
            not frame.is_complete()
            or len(frame.wire) > max_output_bytes - len(output)
        ):
            return FrameEncodeResult.failure()
        _append_wire(output, frame.wire)
    return FrameEncodeResult.complete(output^)
