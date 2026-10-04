#include <stdio.h>
#include <string.h>

#include "net_quic_provider.h"

int main(int argc, char **argv) {
    if (argc != 3 || strcmp(net_quic_version(), "0.29.3") != 0) {
        return 1;
    }

    struct NetQuicServerConfig *config =
        net_quic_config_new(argv[1], argv[2]);
    if (config == NULL) {
        return 2;
    }

    struct NetQuicServer *server = net_quic_create(config);
    if (server == NULL) {
        return 3;
    }
    uint8_t packet[1200];
    char destination[64];
    uint64_t send_delay_ns = UINT64_MAX;
    if (net_quic_send(server, packet, sizeof(packet), destination,
                      sizeof(destination), &send_delay_ns) != 0 ||
        send_delay_ns != 0) {
        return 4;
    }
    net_quic_free(server);
    net_quic_config_free(config);
    puts("QUIC provider server ownership: ok");
    return 0;
}
