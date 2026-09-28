#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/check
for artifact in build/tls/libnet_tls build/tls/test-cert.pem build/tls/test-key.pem build/http2/libnet_hpack; do
    [ -f "$artifact" ] || {
        echo "missing $artifact" >&2
        exit 1
    }
done

mojo build --Werror --emit=llvm -I . examples/http2_hello.mojo \
    -o build/check/http2_hello.ll
