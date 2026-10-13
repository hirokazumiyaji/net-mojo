#!/usr/bin/env bash
set -euo pipefail
set -f

mkdir -p build/fuzz
pkg-config --exists libnghttp2
hpack_cflags=()
hpack_libs=()
read -r -a hpack_cflags <<<"$(pkg-config --cflags libnghttp2)"
read -r -a hpack_libs <<<"$(pkg-config --libs libnghttp2)"
hpack_includedir="$(pkg-config --variable=includedir libnghttp2)"
hpack_libdir="$(pkg-config --variable=libdir libnghttp2)"

hpack_flags=(-O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer
    -fsanitize=address,undefined -fno-sanitize-recover=all
    -I. -I"$hpack_includedir" -Wl,-rpath,"$hpack_libdir" -L"$hpack_libdir")
clang "${hpack_flags[@]}" ${hpack_cflags[@]-} -fsanitize=fuzzer \
    tests/fuzz/hpack.c net/http/_http2/hpack_shim.c ${hpack_libs[@]-} \
    -o build/fuzz/hpack
clang "${hpack_flags[@]}" ${hpack_cflags[@]-} \
    tests/fuzz/test_hpack.c net/http/_http2/hpack_shim.c ${hpack_libs[@]-} \
    -o build/fuzz/test_hpack
build/fuzz/test_hpack

build_args=(--Werror --sanitize address -g1 -I . tests/fuzz/parser.mojo -o build/fuzz/parser)
if [ "$(uname -s)" = "Darwin" ]; then
    build_args+=(
        --external-libasan "$CONDA_PREFIX/lib/libclang_rt.asan_osx_dynamic.dylib"
        -Xlinker -rpath -Xlinker "$CONDA_PREFIX/lib"
    )
fi
mojo build "${build_args[@]}"
