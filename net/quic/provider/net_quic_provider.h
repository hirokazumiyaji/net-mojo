#ifndef NET_QUIC_PROVIDER_H
#define NET_QUIC_PROVIDER_H

#include <stddef.h>
#include <stdint.h>

struct NetQuicServerConfig;
struct NetQuicServer;

const char *net_quic_provider_version(void);
struct NetQuicServerConfig *net_quic_server_config_new(
    const char *certificate_path, const char *private_key_path);
void net_quic_server_config_free(struct NetQuicServerConfig *config);
const char *net_quic_version(void);
struct NetQuicServerConfig *net_quic_config_new(
    const char *certificate_path, const char *private_key_path);
void net_quic_config_free(struct NetQuicServerConfig *config);
struct NetQuicServer *net_quic_server_new(struct NetQuicServerConfig *config);
void net_quic_server_free(struct NetQuicServer *server);
int32_t net_quic_server_set_connection_limit(
    struct NetQuicServer *server, size_t limit);
int32_t net_quic_server_begin_shutdown(struct NetQuicServer *server);
int32_t net_quic_server_finish_shutdown(struct NetQuicServer *server);
int32_t net_quic_server_close_connections(struct NetQuicServer *server);
int32_t net_quic_server_shutdown_complete(const struct NetQuicServer *server);
int32_t net_quic_server_recv(
    struct NetQuicServer *server, uint8_t *packet, size_t packet_length,
    const char *local_address, const char *remote_address);
int32_t net_quic_server_send(
    struct NetQuicServer *server, uint8_t *packet, size_t packet_capacity,
    char *remote_address, size_t address_capacity);
uint64_t net_quic_server_timeout_micros(
    const struct NetQuicServer *server);
void net_quic_server_on_timeout(struct NetQuicServer *server);
int32_t net_quic_server_next_request(
    struct NetQuicServer *server, uint8_t *output, size_t output_capacity);
int32_t net_quic_server_respond(
    struct NetQuicServer *server, uint64_t request_id, uint32_t status,
    const uint8_t *headers, size_t headers_length,
    const uint8_t *body, size_t body_length);
struct NetQuicServer *net_quic_create(struct NetQuicServerConfig *config);
void net_quic_free(struct NetQuicServer *server);
int32_t net_quic_set_connection_limit(
    struct NetQuicServer *server, size_t limit);
int32_t net_quic_begin_shutdown(struct NetQuicServer *server);
int32_t net_quic_finish_shutdown(struct NetQuicServer *server);
int32_t net_quic_close_connections(struct NetQuicServer *server);
int32_t net_quic_shutdown_complete(const struct NetQuicServer *server);
int32_t net_quic_receive(
    struct NetQuicServer *server, uint8_t *packet, size_t packet_length,
    const char *local_address, const char *remote_address);
int32_t net_quic_send(
    struct NetQuicServer *server, uint8_t *packet, size_t packet_capacity,
    char *remote_address, size_t address_capacity);
uint64_t net_quic_timeout_micros(const struct NetQuicServer *server);
void net_quic_on_timeout(struct NetQuicServer *server);
int32_t net_quic_next_request(
    struct NetQuicServer *server, uint8_t *output, size_t output_capacity);
int32_t net_quic_respond(
    struct NetQuicServer *server, uint64_t request_id, uint32_t status,
    const uint8_t *headers, size_t headers_length,
    const uint8_t *body, size_t body_length);

#endif
