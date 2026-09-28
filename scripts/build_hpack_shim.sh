#!/usr/bin/env bash
set -euo pipefail

pkg-config --exists libnghttp2 || {
    echo "libnghttp2 not found via pkg-config" >&2
    exit 1
}

read -r -a hpack_cflags <<<"$(pkg-config --cflags libnghttp2)"
read -r -a hpack_libs <<<"$(pkg-config --libs libnghttp2)"
hpack_includedir="$(pkg-config --variable=includedir libnghttp2)"
hpack_libdir="$(pkg-config --variable=libdir libnghttp2)"

mkdir -p build/http2

if [ "$(uname -s)" = "Darwin" ]; then
    cc -dynamiclib -fPIC -O2 -Wall -Wextra -Werror \
        -I"$hpack_includedir" "${hpack_cflags[@]}" \
        net/http/_http2/hpack_shim.c \
        -Wl,-rpath,"$hpack_libdir" -L"$hpack_libdir" "${hpack_libs[@]}" \
        -o build/http2/libnet_hpack
else
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
        -I"$hpack_includedir" "${hpack_cflags[@]}" \
        net/http/_http2/hpack_shim.c \
        -Wl,-rpath,"$hpack_libdir" -L"$hpack_libdir" "${hpack_libs[@]}" \
        -o build/http2/libnet_hpack
fi

cc -O2 -Wall -Wextra -Werror \
    -I. -I"$hpack_includedir" "${hpack_cflags[@]}" \
    tests/test_hpack_shim.c net/http/_http2/hpack_shim.c \
    -Wl,-rpath,"$hpack_libdir" -L"$hpack_libdir" "${hpack_libs[@]}" \
    -o build/http2/test_hpack_shim
build/http2/test_hpack_shim
