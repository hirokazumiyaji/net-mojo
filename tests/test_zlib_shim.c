#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "net/compress/zlib/zlib_shim.h"

static void roundtrip(size_t length, size_t output_step) {
    uint8_t *input = malloc(length ? length : 1);
    assert(input != NULL);
    for (size_t i = 0; i < length; ++i) {
        input[i] = (uint8_t)(i * 73u + (i >> 8));
    }
    net_gzip_encoder *encoder = net_gzip_encoder_create(5);
    assert(encoder != NULL);
    size_t capacity = net_gzip_encoder_bound(encoder, length);
    assert(capacity >= 20);
    uint8_t *compressed = malloc(capacity);
    assert(compressed != NULL);
    size_t read = 0;
    size_t written = 0;
    int status = NET_GZIP_MORE;
    while (status == NET_GZIP_MORE) {
        size_t consumed = 0;
        size_t produced = 0;
        size_t room = capacity - written;
        if (room > output_step) room = output_step;
        assert(room > 0);
        status = net_gzip_encoder_process(encoder, input + read, length - read,
                                         compressed + written, room, 1,
                                         &consumed, &produced);
        assert(status != NET_GZIP_ERROR);
        assert(consumed > 0 || produced > 0 || status == NET_GZIP_FINISHED);
        read += consumed;
        written += produced;
    }
    assert(status == NET_GZIP_FINISHED && read == length);
    assert(compressed[0] == 0x1f && compressed[1] == 0x8b);
    size_t consumed = 99, produced = 99;
    assert(net_gzip_encoder_process(encoder, input, 0, compressed, capacity, 1,
                                    &consumed, &produced) == NET_GZIP_ERROR);
    assert(consumed == 0 && produced == 0);
    net_gzip_encoder_destroy(encoder);

    z_stream decoder = {0};
    assert(inflateInit2(&decoder, 31) == Z_OK);
    uint8_t *decoded = malloc(length + 1);
    assert(decoded != NULL);
    decoder.next_in = compressed;
    decoder.avail_in = (uInt)written;
    decoder.next_out = decoded;
    decoder.avail_out = (uInt)(length + 1);
    assert(inflate(&decoder, Z_FINISH) == Z_STREAM_END);
    assert(decoder.total_out == length);
    assert(decoder.avail_in == 0);
    assert(memcmp(input, decoded, length) == 0);
    assert(inflateEnd(&decoder) == Z_OK);
    free(decoded);
    free(compressed);
    free(input);
}

static void empty_output_does_not_mutate_encoder(void) {
    net_gzip_encoder *encoder = net_gzip_encoder_create(5);
    assert(encoder != NULL);
    uint8_t input[] = "input";
    uint8_t output[128];
    size_t consumed = 1, produced = 1;
    assert(net_gzip_encoder_process(encoder, input, sizeof(input), output, 0, 1,
                                    &consumed, &produced) == NET_GZIP_ERROR);
    assert(consumed == 0 && produced == 0);
    assert(net_gzip_encoder_process(encoder, input, sizeof(input), output,
                                    sizeof(output), 1, &consumed, &produced) == NET_GZIP_FINISHED);
    assert(consumed == sizeof(input) && produced > 0);
    net_gzip_encoder_destroy(encoder);
}

int main(void) {
    assert(net_gzip_encoder_create(0) == NULL);
    assert(net_gzip_encoder_create(10) == NULL);
    empty_output_does_not_mutate_encoder();
    roundtrip(0, 1);
    roundtrip(17, 1);
    roundtrip(1024 * 1024, 17);
    roundtrip(1024 * 1024, 32768);
    return 0;
}
