#ifndef NET_ZLIB_SHIM_H
#define NET_ZLIB_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct net_gzip_encoder net_gzip_encoder;

enum { NET_GZIP_ERROR = -1, NET_GZIP_MORE = 0, NET_GZIP_FINISHED = 1 };

net_gzip_encoder *net_gzip_encoder_create(int level);
void net_gzip_encoder_destroy(net_gzip_encoder *encoder);
size_t net_gzip_encoder_bound(net_gzip_encoder *encoder, size_t input_length);
int net_gzip_encoder_process(net_gzip_encoder *encoder,
                             const uint8_t *input, size_t input_length,
                             uint8_t *output, size_t output_capacity,
                             int finish, size_t *consumed, size_t *produced);

#endif
