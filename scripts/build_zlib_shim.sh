#!/usr/bin/env bash
set -euo pipefail
set -f

pkg-config --exists zlib
read -r -a compression_cflags <<<"$(pkg-config --cflags zlib)"
read -r -a compression_libs <<<"$(pkg-config --libs zlib)"
compression_libdir="$(pkg-config --variable=libdir zlib)"
mkdir -p build/compression

if [ "$(uname -s)" = "Darwin" ]; then
    cc -dynamiclib -fPIC -O2 -Wall -Wextra -Werror \
        ${compression_cflags[@]-} net/compress/zlib/zlib_shim.c \
        -Wl,-rpath,"$compression_libdir" ${compression_libs[@]-} \
        -o build/compression/libnet_zlib
else
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
        ${compression_cflags[@]-} net/compress/zlib/zlib_shim.c \
        -Wl,-rpath,"$compression_libdir" ${compression_libs[@]-} \
        -o build/compression/libnet_zlib
fi

cc -O2 -Wall -Wextra -Werror -I. ${compression_cflags[@]-} \
    tests/test_zlib_shim.c net/compress/zlib/zlib_shim.c \
    -Wl,-rpath,"$compression_libdir" ${compression_libs[@]-} \
    -o build/compression/test_zlib_shim
build/compression/test_zlib_shim
