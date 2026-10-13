#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/fuzz
build_args=(--Werror --sanitize address -g1 -I . tests/fuzz/parser.mojo -o build/fuzz/parser)
if [ "$(uname -s)" = "Darwin" ]; then
    build_args+=(
        --external-libasan "$CONDA_PREFIX/lib/libclang_rt.asan_osx_dynamic.dylib"
        -Xlinker -rpath -Xlinker "$CONDA_PREFIX/lib"
    )
fi
mojo build "${build_args[@]}"
