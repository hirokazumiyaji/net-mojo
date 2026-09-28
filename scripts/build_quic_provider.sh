#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/quic

CMAKE_TOOLCHAIN_FILE="$PWD/net/quic/provider/toolchain.cmake"
export CMAKE_TOOLCHAIN_FILE
LIBCLANG_PATH="$CONDA_PREFIX/lib"
export LIBCLANG_PATH
if [ "$(uname -s)" = "Linux" ]; then
    quic_gcc_target="$(cc -dumpmachine)"
    quic_gcc_include="$(printf '%s\n' "$CONDA_PREFIX"/lib/gcc/"$quic_gcc_target"/*/include | tail -n 1)"
    BINDGEN_EXTRA_CLANG_ARGS="-isystem $quic_gcc_include -isystem $CONDA_PREFIX/$quic_gcc_target/sysroot/usr/include"
    export BINDGEN_EXTRA_CLANG_ARGS
fi

cargo build --locked --release \
    --manifest-path net/quic/provider/Cargo.toml \
    --target-dir build/quic/cargo

if [ "$(uname -s)" = "Darwin" ]; then
    quic_system_libs=(-lpthread -ldl -framework Security -framework CoreFoundation)
    cc -dynamiclib -fPIC -O2 -Wall -Wextra -Werror \
        -Inet/quic/provider \
        net/quic/provider/shim.c \
        build/quic/cargo/release/libnet_quic_provider.a \
        "${quic_system_libs[@]}" \
        -o build/quic/libnet_quic_provider
else
    quic_system_libs=(-lpthread -ldl -lm)
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
        -Inet/quic/provider \
        net/quic/provider/shim.c \
        build/quic/cargo/release/libnet_quic_provider.a \
        "${quic_system_libs[@]}" \
        -o build/quic/libnet_quic_provider
fi

cc -O2 -Wall -Wextra -Werror \
    -Inet/quic/provider \
    tests/test_quic_provider.c \
    net/quic/provider/shim.c \
    build/quic/cargo/release/libnet_quic_provider.a \
    "${quic_system_libs[@]}" \
    -o build/quic/test_quic_provider
