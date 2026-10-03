#!/usr/bin/env bash
set -euo pipefail

test_source=$1
binary="build/sanitize/${test_source##*/}"
binary="${binary%.mojo}"
mkdir -p build/sanitize

build_args=(--Werror --sanitize address -g1 -I . "$test_source" -o "$binary")
if [ "$(uname -s)" = "Darwin" ]; then
    build_args+=(
        --external-libasan "$CONDA_PREFIX/lib/libclang_rt.asan_osx_dynamic.dylib"
        -Xlinker -rpath -Xlinker "$CONDA_PREFIX/lib"
    )
fi

mojo build "${build_args[@]}"
"$binary"
