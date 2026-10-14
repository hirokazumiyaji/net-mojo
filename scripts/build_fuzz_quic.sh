#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/fuzz
export CMAKE_TOOLCHAIN_FILE="$PWD/net/quic/provider/toolchain.cmake"
export LIBCLANG_PATH="$CONDA_PREFIX/lib"
if [ "$(uname -s)" = "Linux" ]; then
    task_quic_gcc_target="$(cc -dumpmachine)"
    task_quic_gcc_include="$(printf '%s\n' "$CONDA_PREFIX"/lib/gcc/"$task_quic_gcc_target"/*/include | tail -n 1)"
    export BINDGEN_EXTRA_CLANG_ARGS="-isystem $task_quic_gcc_include -isystem $CONDA_PREFIX/$task_quic_gcc_target/sysroot/usr/include"
fi

task_quiche_source=$(bash scripts/prepare_quiche_source.sh)
export RUSTUP_HOME="$PWD/build/fuzz/quic-rustup"
export CARGO_HOME="$PWD/build/fuzz/quic-cargo"
mkdir -p "$CARGO_HOME/bin"
ln -sf "$(command -v rustup)" "$CARGO_HOME/bin/rustup"
printf 'paths = ["%s"]\n' "$task_quiche_source" > "$CARGO_HOME/config.toml"
rustup toolchain install nightly-2026-10-01 --profile minimal
task_quic_cargo=$(rustup which --toolchain nightly-2026-10-01 cargo)
export PATH="$(dirname "$task_quic_cargo"):$PATH"
rustup run nightly-2026-10-01 cargo install --locked --version 0.13.2 \
    --root "$PWD/build/fuzz/quic-tools" cargo-fuzz
export PATH="$PWD/build/fuzz/quic-tools/bin:$PATH"
export NET_HTTP_TEST_CERT="$PWD/build/tls/test-cert.pem"
export NET_HTTP_TEST_KEY="$PWD/build/tls/test-key.pem"
rustup run nightly-2026-10-01 cargo test --locked \
    --manifest-path net/quic/provider/fuzz/Cargo.toml --lib \
    --target-dir build/fuzz/quic-tests
rustup run nightly-2026-10-01 cargo fuzz build --fuzz-dir net/quic/provider/fuzz \
    recv_packet --target-dir "$PWD/build/fuzz/quic-target"
task_quic_target=$(rustup run nightly-2026-10-01 rustc -vV | sed -n 's/^host: //p')
cp "build/fuzz/quic-target/$task_quic_target/release/recv_packet" build/fuzz/quic-recv
