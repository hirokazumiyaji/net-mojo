#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/sanitize
args=(--Werror --sanitize address -g1 -I . tests/websocket_fixture.mojo -Xlinker -ldl -o build/sanitize/websocket_fixture)
if [ "$(uname -s)" = "Darwin" ]; then
  args+=(--external-libasan "$CONDA_PREFIX/lib/libclang_rt.asan_osx_dynamic.dylib" -Xlinker -rpath -Xlinker "$CONDA_PREFIX/lib")
fi
mojo build "${args[@]}"
