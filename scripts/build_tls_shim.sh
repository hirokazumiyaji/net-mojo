#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tls

pkg-config --exists openssl || {
    echo "openssl not found via pkg-config" >&2
    exit 1
}

read -r -a tls_cflags <<<"$(pkg-config --cflags openssl)"
read -r -a tls_libs <<<"$(pkg-config --libs openssl)"
tls_prefix="$(pkg-config --variable=prefix openssl)"

if [ "$(uname -s)" = "Darwin" ]; then
    cc -dynamiclib -fPIC -O2 -Wall -Wextra -Werror \
        "${tls_cflags[@]}" net/tls/shim.c \
        -Wl,-rpath,"$tls_prefix/lib" \
        "${tls_libs[@]}" -o build/tls/libnet_tls
else
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
        "${tls_cflags[@]}" net/tls/shim.c \
        -Wl,-rpath,"$tls_prefix/lib" \
        "${tls_libs[@]}" -o build/tls/libnet_tls
fi

openssl req -quiet -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout build/tls/test-key.pem \
    -out build/tls/test-cert.pem \
    -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost

openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out build/tls/wrong-key.pem
