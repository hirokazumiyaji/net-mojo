"""Connection-owned HPACK decoder backed by the optional native shim."""

from std.ffi import OwnedDLHandle, Pointer, c_int, c_size_t

from net.error import NetError, NetErrorKind


@fieldwise_init
struct HpackDecodeResult(Copyable, Equatable):
    var status: Int
    var output_length: Int
    var field_count: Int
    var decoded_size: Int

    def is_success(self) -> Bool:
        return self.status == 0

    def is_too_large(self) -> Bool:
        return self.status == 1

    def is_invalid(self) -> Bool:
        return self.status == 2


struct Http2HpackInflater(Movable):
    var _library: OwnedDLHandle
    var _inflater: Pointer[Byte, MutUntrackedOrigin]

    def __init__(out self, var library_path: String, max_table_size: Int) raises:
        var library = OwnedDLHandle(library_path)
        var inflater = library.call[
            "net_hpack_inflater_new",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](c_size_t(max_table_size))
        if inflater == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create HTTP/2 HPACK inflater",
                None,
                "libnghttp2 could not create an inflater",
            )
        self._library = library^
        self._inflater = inflater.value()

    def __deinit__(deinit self):
        self._library.call["net_hpack_inflater_free"](self._inflater)

    def set_max_table_size(mut self, size: Int) -> Bool:
        return self._library.call["net_hpack_inflater_set_max_table_size", c_int](
            self._inflater, c_size_t(size)
        ) == 0

    def decode[
        block_origin: ImmOrigin,
        output_origin: MutOrigin,
    ](
        mut self,
        block: Span[Byte, block_origin],
        max_header_list_size: Int,
        max_fields: Int,
        output: Span[mut=True, Byte, output_origin],
    ) -> HpackDecodeResult:
        var output_length = c_size_t(0)
        var field_count = c_size_t(0)
        var decoded_size = c_size_t(0)
        var output_length_ptr = Pointer[
            c_size_t, origin_of(output_length)
        ](to=output_length)
        var field_count_ptr = Pointer[c_size_t, origin_of(field_count)](
            to=field_count
        )
        var decoded_size_ptr = Pointer[c_size_t, origin_of(decoded_size)](
            to=decoded_size
        )
        var status = self._library.call["net_hpack_decode", c_int](
            self._inflater,
            block.unsafe_ptr(),
            c_size_t(len(block)),
            c_size_t(max_header_list_size),
            c_size_t(max_fields),
            output.unsafe_ptr(),
            c_size_t(len(output)),
            output_length_ptr,
            field_count_ptr,
            decoded_size_ptr,
        )
        return HpackDecodeResult(
            status=Int(status),
            output_length=Int(output_length),
            field_count=Int(field_count),
            decoded_size=Int(decoded_size),
        )


@fieldwise_init
struct HpackEncodeResult(Copyable, Equatable):
    var status: Int
    var output_length: Int

    def is_success(self) -> Bool:
        return self.status == 0

    def is_too_large(self) -> Bool:
        return self.status == 1

    def is_invalid(self) -> Bool:
        return self.status == 2


struct Http2HpackDeflater(Movable):
    var _library: OwnedDLHandle
    var _deflater: Pointer[Byte, MutUntrackedOrigin]

    def __init__(out self, var library_path: String, max_table_size: Int) raises:
        var library = OwnedDLHandle(library_path)
        var deflater = library.call[
            "net_hpack_deflater_new",
            Optional[Pointer[Byte, MutUntrackedOrigin]],
        ](c_size_t(max_table_size))
        if deflater == None:
            raise NetError(
                NetErrorKind.system_error(),
                "create HTTP/2 HPACK deflater",
                None,
                "libnghttp2 could not create a deflater",
            )
        self._library = library^
        self._deflater = deflater.value()

    def __deinit__(deinit self):
        self._library.call["net_hpack_deflater_free"](self._deflater)

    def set_max_table_size(mut self, size: Int) -> Bool:
        return self._library.call[
            "net_hpack_deflater_set_max_table_size", c_int
        ](self._deflater, c_size_t(size)) == 0

    def encode[
        field_origin: ImmOrigin,
        output_origin: MutOrigin,
    ](
        mut self,
        fields: Span[Byte, field_origin],
        max_header_list_size: Int,
        max_fields: Int,
        output: Span[mut=True, Byte, output_origin],
    ) -> HpackEncodeResult:
        if max_header_list_size < 0 or max_fields < 0:
            return HpackEncodeResult(status=2, output_length=0)
        var output_length = c_size_t(0)
        var output_length_ptr = Pointer[
            c_size_t, origin_of(output_length)
        ](to=output_length)
        var status = self._library.call["net_hpack_encode", c_int](
            self._deflater,
            fields.unsafe_ptr(),
            c_size_t(len(fields)),
            c_size_t(max_header_list_size),
            c_size_t(max_fields),
            output.unsafe_ptr(),
            c_size_t(len(output)),
            output_length_ptr,
        )
        return HpackEncodeResult(
            status=Int(status), output_length=Int(output_length)
        )
