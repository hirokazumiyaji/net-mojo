#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/conformance
build_args=(--Werror --sanitize address -g1 -I . tests/http2_integration_fixture.mojo
    -Xlinker -ldl -o build/conformance/http2-server)
if [ "$(uname -s)" = "Darwin" ]; then
    build_args+=(
        --external-libasan "$CONDA_PREFIX/lib/libclang_rt.asan_osx_dynamic.dylib"
        -Xlinker -rpath -Xlinker "$CONDA_PREFIX/lib"
    )
fi
mojo build "${build_args[@]}"
