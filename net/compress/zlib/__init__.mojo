"""Owned gzip encoder backed by a separately built libz shim."""

from std.ffi import OwnedDLHandle, c_int, c_size_t
from net.error import NetError, NetErrorKind, _require_handle


@fieldwise_init
struct GzipProgress(Copyable, Movable):
    var consumed: Int
    var produced: Int
    var finished: Bool


struct GzipEncoder(Movable):
    var _library: OwnedDLHandle
    var _encoder: Pointer[Byte, MutUntrackedOrigin]

    def __init__(out self, var library_path: String, level: Int = 5) raises:
        if level < 1 or level > 9:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "create gzip encoder",
                None,
                "gzip level must be between 1 and 9",
            )
        var library = OwnedDLHandle(library_path)
        var encoder = _require_handle(
            library.call[
                "net_gzip_encoder_create",
                Optional[Pointer[Byte, MutUntrackedOrigin]],
            ](c_int(level)),
            "create gzip encoder",
            "libz could not allocate a gzip encoder",
        )
        self._library = library^
        self._encoder = encoder

    def __deinit__(deinit self):
        self._library.call["net_gzip_encoder_destroy"](self._encoder)

    def bound(self, input_length: Int) raises NetError -> Int:
        if input_length < 0:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "bound gzip output",
                None,
                "input length must be nonnegative",
            )
        var result = Int(
            self._library.call["net_gzip_encoder_bound", c_size_t](
                self._encoder, c_size_t(input_length)
            )
        )
        if result < input_length:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "bound gzip output",
                None,
                "gzip output bound overflows",
            )
        return result

    def process[
        input_origin: ImmOrigin, output_origin: MutOrigin
    ](
        mut self,
        input: Span[Byte, input_origin],
        output: Span[mut=True, Byte, output_origin],
        *,
        finish: Bool = False,
    ) raises NetError -> GzipProgress:
        var consumed = c_size_t(0)
        var produced = c_size_t(0)
        var status = self._library.call["net_gzip_encoder_process", c_int](
            self._encoder,
            input.unsafe_ptr(),
            c_size_t(len(input)),
            output.unsafe_ptr(),
            c_size_t(len(output)),
            c_int(1 if finish else 0),
            Pointer(to=consumed),
            Pointer(to=produced),
        )
        if status < 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "compress gzip body",
                None,
                "gzip encoder could not make progress",
            )
        return GzipProgress(Int(consumed), Int(produced), status == 1)
