#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tls
mojo build --Werror --emit=llvm -I . examples/https_hello.mojo \
    -o build/tls/https_hello.ll
