#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/check
for artifact in build/tls/libnet_tls build/tls/test-cert.pem build/tls/test-key.pem; do
    [ -f "$artifact" ] || {
        echo "missing $artifact (run pixi run -e tls tls-build)" >&2
        exit 1
    }
done

mojo build --Werror --emit=llvm -I . examples/https_hello.mojo \
    -o build/check/https_hello.ll
