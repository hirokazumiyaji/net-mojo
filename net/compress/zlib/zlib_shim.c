#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

#include "zlib_shim.h"

struct net_gzip_encoder {
    z_stream stream;
    int finished;
};

net_gzip_encoder *net_gzip_encoder_create(int level) {
    if (level < 1 || level > 9) return NULL;
    net_gzip_encoder *encoder = calloc(1, sizeof(*encoder));
    if (encoder == NULL) return NULL;
    if (deflateInit2(&encoder->stream, level, Z_DEFLATED, 31, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        free(encoder);
        return NULL;
    }
    return encoder;
}

void net_gzip_encoder_destroy(net_gzip_encoder *encoder) {
    deflateEnd(&encoder->stream);
    free(encoder);
}

size_t net_gzip_encoder_bound(net_gzip_encoder *encoder, size_t input_length) {
    return (size_t)deflateBound(&encoder->stream, (uLong)input_length);
}

int net_gzip_encoder_process(net_gzip_encoder *encoder,
                             const uint8_t *input, size_t input_length,
                             uint8_t *output, size_t output_capacity,
                             int finish, size_t *consumed, size_t *produced) {
    *consumed = 0;
    *produced = 0;
    if (encoder->finished || input_length > UINT_MAX ||
        output_capacity == 0 || output_capacity > UINT_MAX) {
        return NET_GZIP_ERROR;
    }
    encoder->stream.next_in = (Bytef *)input;
    encoder->stream.avail_in = (uInt)input_length;
    encoder->stream.next_out = output;
    encoder->stream.avail_out = (uInt)output_capacity;
    int status = deflate(&encoder->stream, finish ? Z_FINISH : Z_NO_FLUSH);
    *consumed = input_length - encoder->stream.avail_in;
    *produced = output_capacity - encoder->stream.avail_out;
    encoder->stream.next_in = NULL;
    encoder->stream.next_out = NULL;
    encoder->stream.avail_in = 0;
    encoder->stream.avail_out = 0;
    if (status == Z_STREAM_END) {
        encoder->finished = 1;
        return NET_GZIP_FINISHED;
    }
    if (status == Z_OK || status == Z_BUF_ERROR) return NET_GZIP_MORE;
    return NET_GZIP_ERROR;
}
