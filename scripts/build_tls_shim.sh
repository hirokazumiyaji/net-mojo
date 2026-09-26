#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tls

if [ "$(uname -s)" = "Darwin" ]; then
    cc -dynamiclib -fPIC -O2 -Wall -Wextra -Werror \
        $(pkg-config --cflags openssl) net/tls/shim.c \
        -Wl,-rpath,"$CONDA_PREFIX/lib" \
        $(pkg-config --libs openssl) -o build/tls/libnet_tls
else
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
        $(pkg-config --cflags openssl) net/tls/shim.c \
        -Wl,-rpath,"$CONDA_PREFIX/lib" \
        $(pkg-config --libs openssl) -o build/tls/libnet_tls
fi

openssl req -quiet -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout build/tls/test-key.pem \
    -out build/tls/test-cert.pem \
    -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost

openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out build/tls/wrong-key.pem
