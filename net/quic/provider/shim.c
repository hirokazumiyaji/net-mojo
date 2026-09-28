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
