#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include "net/http/_http2/hpack_shim.h"
static int successes;
static int tracked_encode(net_hpack_deflater *wrapper, const uint8_t *fields,
                          size_t length, size_t budget, size_t count,
                          uint8_t *output, size_t capacity, size_t *written) {
    int result = net_hpack_encode(wrapper, fields, length, budget, count,
                                 output, capacity, written);
    successes += result == NET_HPACK_ENCODE_OK && length != 0;
    return result;
}
#define net_hpack_encode tracked_encode
#include "hpack.c"
int main(void) {
    uint8_t fields[] = {0,0,0,1,0,0,0,1,'x','y'};
    LLVMFuzzerTestOneInput(fields, sizeof(fields));
    assert(successes > 0);
    return 0;
}
