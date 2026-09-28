#include "net_quic_provider.h"

const char *net_quic_version(void) {
    return net_quic_provider_version();
}

struct NetQuicServerConfig *net_quic_config_new(
    const char *certificate_path, const char *private_key_path) {
    return net_quic_server_config_new(certificate_path, private_key_path);
}

void net_quic_config_free(struct NetQuicServerConfig *config) {
    net_quic_server_config_free(config);
}

struct NetQuicServer *net_quic_create(struct NetQuicServerConfig *config) {
    return net_quic_server_new(config);
}

void net_quic_free(struct NetQuicServer *server) {
    net_quic_server_free(server);
}

int32_t net_quic_set_connection_limit(
    struct NetQuicServer *server, size_t limit) {
    return net_quic_server_set_connection_limit(server, limit);
}

int32_t net_quic_begin_shutdown(struct NetQuicServer *server) {
    return net_quic_server_begin_shutdown(server);
}

int32_t net_quic_finish_shutdown(struct NetQuicServer *server) {
    return net_quic_server_finish_shutdown(server);
}

int32_t net_quic_close_connections(struct NetQuicServer *server) {
    return net_quic_server_close_connections(server);
}

int32_t net_quic_shutdown_complete(const struct NetQuicServer *server) {
    return net_quic_server_shutdown_complete(server);
}

int32_t net_quic_receive(
    struct NetQuicServer *server, uint8_t *packet, size_t packet_length,
    const char *local_address, const char *remote_address) {
    return net_quic_server_recv(server, packet, packet_length, local_address,
                                remote_address);
}

int32_t net_quic_send(
    struct NetQuicServer *server, uint8_t *packet, size_t packet_capacity,
    char *remote_address, size_t address_capacity) {
    return net_quic_server_send(server, packet, packet_capacity,
                                remote_address, address_capacity);
}

uint64_t net_quic_timeout_micros(const struct NetQuicServer *server) {
    return net_quic_server_timeout_micros(server);
}

void net_quic_on_timeout(struct NetQuicServer *server) {
    net_quic_server_on_timeout(server);
}

int32_t net_quic_next_request(
    struct NetQuicServer *server, uint8_t *output, size_t output_capacity) {
    return net_quic_server_next_request(server, output, output_capacity);
}

int32_t net_quic_respond(
    struct NetQuicServer *server, uint64_t request_id, uint32_t status,
    const uint8_t *headers, size_t headers_length,
    const uint8_t *body, size_t body_length) {
    return net_quic_server_respond(server, request_id, status, headers,
                                   headers_length, body, body_length);
}
