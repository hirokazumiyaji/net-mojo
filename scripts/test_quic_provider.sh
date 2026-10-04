#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" = "Linux" ]; then
    export CMAKE_TOOLCHAIN_FILE="$PWD/net/quic/provider/toolchain.cmake"
    quic_gcc_target="$(cc -dumpmachine)"
    quic_gcc_include="$(printf '%s\n' "$CONDA_PREFIX"/lib/gcc/"$quic_gcc_target"/*/include | tail -n 1)"
    export LIBCLANG_PATH="$CONDA_PREFIX/lib"
    export BINDGEN_EXTRA_CLANG_ARGS="-isystem $quic_gcc_include -isystem $CONDA_PREFIX/$quic_gcc_target/sysroot/usr/include"
fi

task_quiche_source=$(bash scripts/prepare_quiche_source.sh)
NET_HTTP_TEST_CERT="$PWD/build/tls/test-cert.pem" \
NET_HTTP_TEST_KEY="$PWD/build/tls/test-key.pem" \
    cargo test --locked --release \
        --config "paths=[\"$task_quiche_source\"]" \
        --manifest-path net/quic/provider/Cargo.toml \
        --target-dir build/quic/cargo

cargo test --locked --release \
    --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/cargo request_cancellation

cargo test --locked --release \
    --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/cargo ranges::tests
cargo test --locked --release \
    --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/cargo collected_streams
cargo test --locked --release \
    --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/cargo stream_limit_does_not_collect

cargo test --locked --release \
    --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/cargo locally_drained
cargo test --locked --release \
    --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/cargo unknown_retirement
