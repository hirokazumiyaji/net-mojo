#ifndef NET_QUIC_PROVIDER_H
#define NET_QUIC_PROVIDER_H

struct NetQuicServerConfig;

const char *net_quic_provider_version(void);
struct NetQuicServerConfig *net_quic_server_config_new(
    const char *certificate_path, const char *private_key_path);
void net_quic_server_config_free(struct NetQuicServerConfig *config);
const char *net_quic_version(void);
struct NetQuicServerConfig *net_quic_config_new(
    const char *certificate_path, const char *private_key_path);
void net_quic_config_free(struct NetQuicServerConfig *config);

#endif
