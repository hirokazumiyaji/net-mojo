#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "net/http/_http2/hpack_shim.h"

static void fuzz_limits(const uint8_t *data, size_t size, size_t capacity,
                        size_t max_fields, size_t table_size) {
    uint8_t output[8192];
    size_t output_length = 0, field_count = 0, decoded_size = 0;
    net_hpack_inflater *inflater = net_hpack_inflater_new(table_size);
    net_hpack_deflater *deflater = net_hpack_deflater_new(table_size);
    if (inflater == NULL || deflater == NULL) {
        abort();
    }
    int decoded = net_hpack_decode(inflater, data, size, 8192, max_fields,
                                   output, capacity, &output_length,
                                   &field_count, &decoded_size);
    assert(decoded >= NET_HPACK_DECODE_OK && decoded <= NET_HPACK_DECODE_INVALID);
    assert(output_length <= capacity);
    net_hpack_inflater_free(inflater);

    size_t bound = 0;
    (void)net_hpack_deflate_bound(deflater, data, size, &bound);
    int encoded = net_hpack_encode(deflater, data, size, 8192, max_fields,
                                   output, capacity, &output_length);
    assert(encoded >= NET_HPACK_ENCODE_OK && encoded <= NET_HPACK_ENCODE_INVALID);
    assert(output_length <= capacity);
    net_hpack_deflater_free(deflater);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    fuzz_limits(data, size, 8192, 128, 4096);
    size_t capacity = size == 0 ? 0 : (size_t)data[size - 1] * 32;
    size_t max_fields = size < 2 ? 0 : data[size - 2];
    size_t table_size = size < 3 ? 0 : (size_t)data[size - 3] * 32;
    fuzz_limits(data, size, capacity, max_fields, table_size);
    return 0;
}
