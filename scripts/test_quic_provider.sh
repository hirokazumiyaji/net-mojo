#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" = "Linux" ]; then
    export CMAKE_TOOLCHAIN_FILE="$PWD/net/quic/provider/toolchain.cmake"
    quic_gcc_target="$(cc -dumpmachine)"
    quic_gcc_include="$(printf '%s\n' "$CONDA_PREFIX"/lib/gcc/"$quic_gcc_target"/*/include | tail -n 1)"
    export LIBCLANG_PATH="$CONDA_PREFIX/lib"
    export BINDGEN_EXTRA_CLANG_ARGS="-isystem $quic_gcc_include -isystem $CONDA_PREFIX/$quic_gcc_target/sysroot/usr/include"
fi

NET_HTTP_TEST_CERT="$PWD/build/tls/test-cert.pem" \
NET_HTTP_TEST_KEY="$PWD/build/tls/test-key.pem" \
    cargo test --locked --release \
        --manifest-path net/quic/provider/Cargo.toml \
        --target-dir build/quic/cargo
