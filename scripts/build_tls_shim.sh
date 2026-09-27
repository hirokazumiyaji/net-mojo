#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tls

pkg-config --exists openssl || {
    echo "openssl not found via pkg-config" >&2
    exit 1
}

read -r -a tls_cflags <<<"$(pkg-config --cflags-only-other openssl)"
read -r -a tls_libs <<<"$(pkg-config --libs-only-l openssl)"
read -r -a tls_ldflags <<<"$(pkg-config --libs-only-other openssl)"
tls_includedir="$(pkg-config --variable=includedir openssl)"
tls_libdir="$(pkg-config --variable=libdir openssl)"

if [ "$(uname -s)" = "Darwin" ]; then
    cc -dynamiclib -fPIC -O2 -Wall -Wextra -Werror \
        -I"$tls_includedir" "${tls_cflags[@]}" net/tls/shim.c \
        -Wl,-rpath,"$tls_libdir" -L"$tls_libdir" \
        "${tls_libs[@]}" "${tls_ldflags[@]}" -o build/tls/libnet_tls
else
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
        -I"$tls_includedir" "${tls_cflags[@]}" net/tls/shim.c \
        -Wl,-rpath,"$tls_libdir" -L"$tls_libdir" \
        "${tls_libs[@]}" "${tls_ldflags[@]}" -o build/tls/libnet_tls
fi

openssl req -quiet -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout build/tls/test-key.pem \
    -out build/tls/test-cert.pem \
    -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost

openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out build/tls/wrong-key.pem

cc -O2 -Wall -Wextra -Werror \
    -I"$tls_includedir" "${tls_cflags[@]}" tests/test_tls_shim.c net/tls/shim.c \
    -L"$tls_libdir" "${tls_libs[@]}" "${tls_ldflags[@]}" \
    -o build/tls/test_tls_shim
build/tls/test_tls_shim build/tls/test-cert.pem build/tls/test-key.pem
