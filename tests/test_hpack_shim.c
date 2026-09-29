#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "net/http/_http2/hpack_shim.h"

static size_t expect_field(const uint8_t *encoded, size_t encoded_length,
                           const char *name, const char *value) {
    assert(encoded_length >= 8);
    size_t name_length = ((size_t)encoded[0] << 24) |
                         ((size_t)encoded[1] << 16) |
                         ((size_t)encoded[2] << 8) | (size_t)encoded[3];
    size_t value_length = ((size_t)encoded[4] << 24) |
                          ((size_t)encoded[5] << 16) |
                          ((size_t)encoded[6] << 8) | (size_t)encoded[7];
    assert(name_length == strlen(name));
    assert(value_length == strlen(value));
    assert(encoded_length >= 8 + name_length + value_length);
    assert(memcmp(encoded + 8, name, name_length) == 0);
    assert(memcmp(encoded + 8 + name_length, value, value_length) == 0);
    return 8 + name_length + value_length;
}

static int decode(net_hpack_inflater *inflater, const uint8_t *block,
                  size_t block_length, size_t max_header_list_size,
                  size_t max_fields, uint8_t *output, size_t output_capacity,
                  size_t *output_length, size_t *field_count,
                  size_t *decoded_size) {
    return net_hpack_decode(inflater, block, block_length,
                            max_header_list_size, max_fields, output,
                            output_capacity, output_length, field_count,
                            decoded_size);
}

static size_t append_field(uint8_t *fields, size_t offset, const char *name,
                           const char *value) {
    size_t name_length = strlen(name);
    size_t value_length = strlen(value);
    fields[offset] = (uint8_t)(name_length >> 24);
    fields[offset + 1] = (uint8_t)(name_length >> 16);
    fields[offset + 2] = (uint8_t)(name_length >> 8);
    fields[offset + 3] = (uint8_t)name_length;
    fields[offset + 4] = (uint8_t)(value_length >> 24);
    fields[offset + 5] = (uint8_t)(value_length >> 16);
    fields[offset + 6] = (uint8_t)(value_length >> 8);
    fields[offset + 7] = (uint8_t)value_length;
    memcpy(fields + offset + 8, name, name_length);
    memcpy(fields + offset + 8 + name_length, value, value_length);
    return offset + 8 + name_length + value_length;
}

static void test_deflater_round_trip_and_limits(void) {
    uint8_t fields[128];
    size_t fields_length = 0;
    fields_length = append_field(fields, fields_length, ":status", "200");
    fields_length = append_field(fields, fields_length, "content-type",
                                 "text/plain");

    net_hpack_deflater *deflater = net_hpack_deflater_new(4096);
    assert(deflater != NULL);
    uint8_t block[128];
    size_t block_length = 0;
    assert(net_hpack_encode(deflater, fields, fields_length, 1024, 8, block,
                            1, &block_length) == NET_HPACK_ENCODE_TOO_LARGE);
    assert(block_length == 0);
    assert(net_hpack_encode(deflater, fields, fields_length, 1024, 8, block,
                            sizeof(block), &block_length) ==
           NET_HPACK_ENCODE_OK);
    assert(block_length > 0);

    net_hpack_inflater *inflater = net_hpack_inflater_new(4096);
    assert(inflater != NULL);
    uint8_t decoded[128];
    size_t decoded_length = 0;
    size_t field_count = 0;
    size_t decoded_size = 0;
    assert(decode(inflater, block, block_length, 1024, 8, decoded,
                  sizeof(decoded), &decoded_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_OK);
    assert(field_count == 2);
    size_t offset = 0;
    offset += expect_field(decoded + offset, decoded_length - offset,
                           ":status", "200");
    offset += expect_field(decoded + offset, decoded_length - offset,
                           "content-type", "text/plain");
    assert(offset == decoded_length);

    assert(net_hpack_deflater_set_max_table_size(deflater, 64) == 0);
    assert(net_hpack_encode(deflater, fields, fields_length, 1, 8, block,
                            sizeof(block), &block_length) ==
           NET_HPACK_ENCODE_TOO_LARGE);
    net_hpack_inflater_free(inflater);
    net_hpack_deflater_free(deflater);
}

static void test_rfc_literal_and_huffman_blocks(void) {
    net_hpack_inflater *inflater = net_hpack_inflater_new(4096);
    assert(inflater != NULL);
    uint8_t output[512];
    size_t output_length = 0;
    size_t field_count = 0;
    size_t decoded_size = 0;

    const uint8_t literal_block[] = {
        0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a',
        'm',  'p',  'l',  'e',  '.',  'c', 'o', 'm',
    };
    assert(decode(inflater, literal_block, sizeof(literal_block), 1024, 16,
                  output, sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_OK);
    assert(field_count == 4);
    size_t offset = 0;
    offset += expect_field(output + offset, output_length - offset, ":method",
                           "GET");
    offset += expect_field(output + offset, output_length - offset, ":scheme",
                           "http");
    offset += expect_field(output + offset, output_length - offset, ":path",
                           "/");
    offset += expect_field(output + offset, output_length - offset,
                           ":authority", "www.example.com");
    assert(offset == output_length);

    const uint8_t huffman_block[] = {
        0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5,
        0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
    };
    assert(decode(inflater, huffman_block, sizeof(huffman_block), 1024, 16,
                  output, sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_OK);
    assert(field_count == 4);
    offset = 0;
    offset += expect_field(output + offset, output_length - offset, ":method",
                           "GET");
    offset += expect_field(output + offset, output_length - offset, ":scheme",
                           "http");
    offset += expect_field(output + offset, output_length - offset, ":path",
                           "/");
    offset += expect_field(output + offset, output_length - offset,
                           ":authority", "www.example.com");
    assert(offset == output_length);
    assert(decoded_size >= output_length);
    net_hpack_inflater_free(inflater);
}

static void test_dynamic_table_state_survives_output_limit(void) {
    net_hpack_inflater *inflater = net_hpack_inflater_new(4096);
    assert(inflater != NULL);
    uint8_t output[128];
    size_t output_length = 0;
    size_t field_count = 0;
    size_t decoded_size = 0;
    const uint8_t literal[] = {
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't', 0x05, 'f', 'i', 'r', 's', 't',
    };
    assert(decode(inflater, literal, sizeof(literal), 0, 16, output,
                  sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_TOO_LARGE);
    assert(field_count == 1);
    assert(output_length == 0);
    assert(decoded_size > 0);

    const uint8_t indexed_dynamic_entry[] = {0xbe};
    assert(decode(inflater, indexed_dynamic_entry,
                  sizeof(indexed_dynamic_entry), 1024, 16, output, 4,
                  &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_TOO_LARGE);
    assert(output_length == 0);
    assert(decode(inflater, indexed_dynamic_entry,
                  sizeof(indexed_dynamic_entry), 1024, 16, output,
                  sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_OK);
    assert(field_count == 1);
    assert(expect_field(output, output_length, "x-test", "first") ==
           output_length);

    assert(net_hpack_inflater_set_max_table_size(inflater, 32) == 0);
    const uint8_t shrink_table[] = {0x3f, 0x01};
    assert(decode(inflater, shrink_table, sizeof(shrink_table), 1024, 16,
                  output, sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_OK);
    assert(decode(inflater, indexed_dynamic_entry,
                  sizeof(indexed_dynamic_entry), 1024, 16, output,
                  sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_INVALID);
    net_hpack_inflater_free(inflater);
}

static void test_decode_limits_and_compression_errors(void) {
    net_hpack_inflater *inflater = net_hpack_inflater_new(4096);
    assert(inflater != NULL);
    uint8_t output[32];
    size_t output_length = 0;
    size_t field_count = 0;
    size_t decoded_size = 0;

    const uint8_t two_fields[] = {0x82, 0x86};
    assert(decode(inflater, two_fields, sizeof(two_fields), 1024, 1, output,
                  sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_TOO_LARGE);
    assert(field_count == 2);
    net_hpack_inflater_free(inflater);

    inflater = net_hpack_inflater_new(32);
    assert(inflater != NULL);
    const uint8_t too_large_table_update[] = {0x3f, 0x02};
    assert(decode(inflater, too_large_table_update,
                  sizeof(too_large_table_update), 1024, 16, output,
                  sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_INVALID);
    net_hpack_inflater_free(inflater);

    inflater = net_hpack_inflater_new(4096);
    assert(inflater != NULL);
    const uint8_t invalid_index[] = {0xff};
    assert(decode(inflater, invalid_index, sizeof(invalid_index), 1024, 16,
                  output, sizeof(output), &output_length, &field_count,
                  &decoded_size) == NET_HPACK_DECODE_INVALID);
    net_hpack_inflater_free(inflater);
}

int main(void) {
    test_rfc_literal_and_huffman_blocks();
    test_dynamic_table_state_survives_output_limit();
    test_decode_limits_and_compression_errors();
    test_deflater_round_trip_and_limits();
    return 0;
}
