#ifndef NET_HTTP2_HPACK_SHIM_H
#define NET_HTTP2_HPACK_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct net_hpack_inflater net_hpack_inflater;
typedef struct net_hpack_deflater net_hpack_deflater;

enum {
    NET_HPACK_DECODE_OK = 0,
    NET_HPACK_DECODE_TOO_LARGE = 1,
    NET_HPACK_DECODE_INVALID = 2,
    NET_HPACK_ENCODE_OK = 0,
    NET_HPACK_ENCODE_TOO_LARGE = 1,
    NET_HPACK_ENCODE_INVALID = 2,
};

net_hpack_inflater *net_hpack_inflater_new(size_t max_table_size);
void net_hpack_inflater_free(net_hpack_inflater *inflater);
int net_hpack_inflater_set_max_table_size(net_hpack_inflater *inflater,
                                          size_t max_table_size);
int net_hpack_decode(net_hpack_inflater *inflater, const uint8_t *block,
                     size_t block_length, size_t max_header_list_size,
                     size_t max_fields, uint8_t *output,
                     size_t output_capacity, size_t *output_length,
                     size_t *field_count, size_t *decoded_size);

net_hpack_deflater *net_hpack_deflater_new(size_t max_table_size);
void net_hpack_deflater_free(net_hpack_deflater *deflater);
int net_hpack_deflater_set_max_table_size(net_hpack_deflater *deflater,
                                          size_t max_table_size);
int net_hpack_encode(net_hpack_deflater *deflater, const uint8_t *fields,
                    size_t fields_length, size_t max_header_list_size,
                    size_t max_fields, uint8_t *output,
                    size_t output_capacity, size_t *output_length);

#endif
