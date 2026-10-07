#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <nghttp2/nghttp2.h>

#include "hpack_shim.h"

struct net_hpack_inflater {
    nghttp2_hd_inflater *inflater;
};

struct net_hpack_deflater {
    nghttp2_hd_deflater *deflater;
};

net_hpack_inflater *net_hpack_inflater_new(size_t max_table_size) {
    if (max_table_size > UINT32_MAX) {
        return NULL;
    }

    net_hpack_inflater *wrapper = malloc(sizeof(*wrapper));
    if (wrapper == NULL) {
        return NULL;
    }
    if (nghttp2_hd_inflate_new(&wrapper->inflater) != 0) {
        free(wrapper);
        return NULL;
    }
    if (nghttp2_hd_inflate_change_table_size(wrapper->inflater,
                                              max_table_size) != 0) {
        nghttp2_hd_inflate_del(wrapper->inflater);
        free(wrapper);
        return NULL;
    }
    return wrapper;
}

void net_hpack_inflater_free(net_hpack_inflater *wrapper) {
    if (wrapper == NULL) {
        return;
    }
    nghttp2_hd_inflate_del(wrapper->inflater);
    free(wrapper);
}

int net_hpack_inflater_set_max_table_size(net_hpack_inflater *wrapper,
                                          size_t max_table_size) {
    if (wrapper == NULL || max_table_size > UINT32_MAX) {
        return -1;
    }
    return nghttp2_hd_inflate_change_table_size(wrapper->inflater,
                                                 max_table_size);
}

static void write_u32(uint8_t *output, uint32_t value) {
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static void add_decoded_size(size_t *total, size_t name_length,
                             size_t value_length, int *too_large) {
    if (name_length > SIZE_MAX - 32 ||
        value_length > SIZE_MAX - 32 - name_length) {
        *total = SIZE_MAX;
        *too_large = 1;
        return;
    }
    size_t field_size = name_length + value_length + 32;
    if (*total > SIZE_MAX - field_size) {
        *total = SIZE_MAX;
        *too_large = 1;
        return;
    }
    *total += field_size;
}

static void copy_field(uint8_t *output, size_t offset, const nghttp2_nv *field) {
    write_u32(output + offset, (uint32_t)field->namelen);
    write_u32(output + offset + 4, (uint32_t)field->valuelen);
    if (field->namelen != 0) {
        memcpy(output + offset + 8, field->name, field->namelen);
    }
    if (field->valuelen != 0) {
        memcpy(output + offset + 8 + field->namelen, field->value,
               field->valuelen);
    }
}

int net_hpack_decode(net_hpack_inflater *wrapper, const uint8_t *block,
                     size_t block_length, size_t max_header_list_size,
                     size_t max_fields, uint8_t *output,
                     size_t output_capacity, size_t *output_length,
                     size_t *field_count, size_t *decoded_size) {
    if (wrapper == NULL || (block == NULL && block_length != 0) ||
        (output == NULL && output_capacity != 0) || output_length == NULL ||
        field_count == NULL || decoded_size == NULL) {
        return NET_HPACK_DECODE_INVALID;
    }

    *output_length = 0;
    *field_count = 0;
    *decoded_size = 0;
    static const uint8_t empty_block = 0;
    const uint8_t *cursor = block_length == 0 ? &empty_block : block;
    size_t remaining = block_length;
    int too_large = 0;

    for (;;) {
        nghttp2_nv field;
        int flags = 0;
        nghttp2_ssize consumed = nghttp2_hd_inflate_hd3(
            wrapper->inflater, &field, &flags, cursor, remaining, 1);
        if (consumed < 0 || (size_t)consumed > remaining) {
            return NET_HPACK_DECODE_INVALID;
        }
        cursor += consumed;
        remaining -= (size_t)consumed;

        if ((flags & NGHTTP2_HD_INFLATE_EMIT) != 0) {
            if (*field_count == SIZE_MAX) {
                too_large = 1;
            } else {
                ++*field_count;
            }
            add_decoded_size(decoded_size, field.namelen, field.valuelen,
                             &too_large);
            if (*decoded_size > max_header_list_size ||
                *field_count > max_fields || field.namelen > UINT32_MAX ||
                field.valuelen > UINT32_MAX) {
                too_large = 1;
            }

            if (!too_large) {
                if (field.valuelen > SIZE_MAX - 8 ||
                    field.namelen > SIZE_MAX - 8 - field.valuelen) {
                    too_large = 1;
                } else {
                    size_t encoded_length =
                        8 + field.namelen + field.valuelen;
                    if (*output_length > output_capacity ||
                        encoded_length > output_capacity - *output_length) {
                        too_large = 1;
                    } else {
                        copy_field(output, *output_length, &field);
                        *output_length += encoded_length;
                    }
                }
            }
        }

        if ((flags & NGHTTP2_HD_INFLATE_FINAL) != 0) {
            if (remaining != 0 ||
                nghttp2_hd_inflate_end_headers(wrapper->inflater) != 0) {
                return NET_HPACK_DECODE_INVALID;
            }
            return too_large ? NET_HPACK_DECODE_TOO_LARGE
                             : NET_HPACK_DECODE_OK;
        }
        if (consumed == 0 && (flags & NGHTTP2_HD_INFLATE_EMIT) == 0) {
            return NET_HPACK_DECODE_INVALID;
        }
    }
}

net_hpack_deflater *net_hpack_deflater_new(size_t max_table_size) {
    if (max_table_size > UINT32_MAX) {
        return NULL;
    }

    net_hpack_deflater *wrapper = malloc(sizeof(*wrapper));
    if (wrapper == NULL) {
        return NULL;
    }
    if (nghttp2_hd_deflate_new(&wrapper->deflater, max_table_size) != 0) {
        free(wrapper);
        return NULL;
    }
    return wrapper;
}

void net_hpack_deflater_free(net_hpack_deflater *wrapper) {
    if (wrapper == NULL) {
        return;
    }
    nghttp2_hd_deflate_del(wrapper->deflater);
    free(wrapper);
}

int net_hpack_deflater_set_max_table_size(net_hpack_deflater *wrapper,
                                          size_t max_table_size) {
    if (wrapper == NULL || max_table_size > UINT32_MAX) {
        return -1;
    }
    return nghttp2_hd_deflate_change_table_size(wrapper->deflater,
                                                 max_table_size);
}

static uint32_t read_u32(const uint8_t *input) {
    return ((uint32_t)input[0] << 24) | ((uint32_t)input[1] << 16) |
           ((uint32_t)input[2] << 8) | (uint32_t)input[3];
}

int net_hpack_encode(net_hpack_deflater *wrapper, const uint8_t *fields,
                    size_t fields_length, size_t max_header_list_size,
                    size_t max_fields, uint8_t *output,
                    size_t output_capacity, size_t *output_length) {
    if (wrapper == NULL || (fields == NULL && fields_length != 0) ||
        (output == NULL && output_capacity != 0) || output_length == NULL) {
        return NET_HPACK_ENCODE_INVALID;
    }

    *output_length = 0;
    size_t count = 0;
    size_t offset = 0;
    size_t decoded_size = 0;
    while (offset < fields_length) {
        if (fields_length - offset < 8) {
            return NET_HPACK_ENCODE_INVALID;
        }
        uint32_t name_length = read_u32(fields + offset);
        uint32_t value_length = read_u32(fields + offset + 4);
        offset += 8;
        if (name_length == 0 || name_length > fields_length - offset ||
            value_length > fields_length - offset - name_length) {
            return NET_HPACK_ENCODE_INVALID;
        }
        if (count == SIZE_MAX) {
            return NET_HPACK_ENCODE_TOO_LARGE;
        }
        ++count;
        size_t name_size = name_length;
        size_t value_size = value_length;
        if (name_size > SIZE_MAX - value_size ||
            name_size + value_size > SIZE_MAX - 32) {
            return NET_HPACK_ENCODE_TOO_LARGE;
        }
        size_t field_size = name_size + value_size + 32;
        if (decoded_size > SIZE_MAX - field_size) {
            return NET_HPACK_ENCODE_TOO_LARGE;
        }
        decoded_size += field_size;
        offset += (size_t)name_length + value_length;
    }
    if (count > max_fields || decoded_size > max_header_list_size) {
        return NET_HPACK_ENCODE_TOO_LARGE;
    }
    if (count > SIZE_MAX / sizeof(nghttp2_nv)) {
        return NET_HPACK_ENCODE_TOO_LARGE;
    }

    nghttp2_nv *nva = NULL;
    if (count != 0) {
        nva = malloc(count * sizeof(*nva));
        if (nva == NULL) {
            return NET_HPACK_ENCODE_INVALID;
        }
    }
    offset = 0;
    for (size_t i = 0; i < count; ++i) {
        uint32_t name_length = read_u32(fields + offset);
        uint32_t value_length = read_u32(fields + offset + 4);
        offset += 8;
        nva[i].name = (uint8_t *)(fields + offset);
        nva[i].namelen = name_length;
        offset += name_length;
        nva[i].value = (uint8_t *)(fields + offset);
        nva[i].valuelen = value_length;
        nva[i].flags = NGHTTP2_NV_FLAG_NONE;
        offset += value_length;
    }

    size_t bound = nghttp2_hd_deflate_bound(wrapper->deflater, nva, count);
    if (bound > output_capacity) {
        free(nva);
        return NET_HPACK_ENCODE_TOO_LARGE;
    }
    static uint8_t empty_output;
    uint8_t *output_buffer = output_capacity == 0 ? &empty_output : output;
    nghttp2_ssize encoded = nghttp2_hd_deflate_hd2(
        wrapper->deflater, output_buffer, output_capacity, nva, count);
    free(nva);
    if (encoded < 0) {
        return NET_HPACK_ENCODE_INVALID;
    }
    *output_length = (size_t)encoded;
    return NET_HPACK_ENCODE_OK;
}
