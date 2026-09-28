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
    net_quic_config_free(config);
    puts("QUIC provider config: ok");
    return 0;
}
