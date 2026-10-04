#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>

#include "net_quic_provider.h"
#include "quiche.h"

static int test_receive_limits(struct NetQuicServer *server) {
    quiche_config *client_config = quiche_config_new(QUICHE_PROTOCOL_VERSION);
    const uint8_t protocols[] = {2, 'h', '3'};
    if (client_config == NULL ||
        quiche_config_set_application_protos(client_config, protocols,
                                             sizeof(protocols)) != 0) {
        return 5;
    }
    quiche_config_verify_peer(client_config, false);
    struct sockaddr_in local = {0}, remote = {0};
    local.sin_family = remote.sin_family = AF_INET;
    local.sin_port = htons(54700);
    remote.sin_port = htons(4433);
    local.sin_addr.s_addr = remote.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const uint8_t source_id[16] = {0xc3};
    quiche_conn *client = quiche_connect("localhost", source_id, sizeof(source_id),
        (const struct sockaddr *)&local, sizeof(local),
        (const struct sockaddr *)&remote, sizeof(remote), client_config);
    if (client == NULL) {
        return 6;
    }
    uint8_t original[1350], packet[1350];
    quiche_send_info info;
    ssize_t length = quiche_conn_send(client, original, sizeof(original), &info);
    if (length <= 0 ||
        net_quic_set_receive_limits(server, 64, 6, 4096, 32, 16384, 4) != 1) {
        return 7;
    }
    memcpy(packet, original, (size_t)length);
    int rejected = net_quic_receive(server, packet, (size_t)length,
                                    "127.0.0.1:4433", "127.0.0.1:54700");
    int restored = net_quic_set_receive_limits(server, 64, 6, 4096, 32, 16384, 64);
    if (rejected != 0 || restored != 1) {
        fprintf(stderr, "receive rejection=%d restore=%d\n", rejected, restored);
        return 8;
    }
    memcpy(packet, original, (size_t)length);
    if (net_quic_receive(server, packet, (size_t)length,
                         "127.0.0.1:4433", "127.0.0.1:54700") != 1 ||
        net_quic_set_receive_limits(server, 65, 6, 4096, 32, 16384, 64) != -1) {
        return 9;
    }
    quiche_conn_free(client);
    quiche_config_free(client_config);
    return 0;
}

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
    int receive_result = test_receive_limits(server);
    if (receive_result != 0) {
        return receive_result;
    }
    net_quic_free(server);
    net_quic_config_free(config);
    puts("QUIC provider server ownership: ok");
    return 0;
}
