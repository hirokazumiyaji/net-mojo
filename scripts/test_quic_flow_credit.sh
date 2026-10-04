#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" = "Linux" ]; then
    export CMAKE_TOOLCHAIN_FILE="$PWD/net/quic/provider/toolchain.cmake"
    task_quic_gcc_target="$(cc -dumpmachine)"
    task_quic_gcc_include="$(printf '%s\n' "$CONDA_PREFIX"/lib/gcc/"$task_quic_gcc_target"/*/include | tail -n 1)"
    export LIBCLANG_PATH="$CONDA_PREFIX/lib"
    export BINDGEN_EXTRA_CLANG_ARGS="-isystem $task_quic_gcc_include -isystem $CONDA_PREFIX/$task_quic_gcc_target/sysroot/usr/include"
fi

task_quiche_source=$(bash scripts/prepare_quiche_source.sh)
python3 - "$task_quiche_source" <<'PY'
import hashlib
from pathlib import Path
import re
import sys

source = Path("net/quic/provider/src/lib.rs").read_text()
selected = re.findall(r"^const PROVIDER_[A-Z_]+:[\s\S]*?;", source, re.MULTILINE)
for name in ("disable_quic_early_data", "apply_provider_quic_transport_settings", "default_receive_limits"):
    start = source.index(f"fn {name}(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    selected.append(source[start:end])
settings = "\n\n".join(selected) + "\n"
stage = Path(sys.argv[1]) / "src"
(stage / "http3_flow_credit_settings.rs").write_text(settings)
(stage / "http3_flow_credit_transport_settings.rs").write_text("\n\n".join(selected[:-1]) + "\n")
(stage / "http3_flow_credit.rs").write_text("\n".join(
    Path("tests/quic_flow_credit", name).read_text()
    for name in ("held_bodies.rs", "algebra.rs", "recovery.rs")
))
with (stage / "h3/mod.rs").open("a") as output:
    output.write("\n" + Path("tests/quic_flow_credit/qpack_peer.rs").read_text())
with (stage / "lib.rs").open("a") as output:
    output.write('\n#[cfg(test)]\ninclude!("http3_flow_credit.rs");\n')
print("provider_source_sha256=" + hashlib.sha256(source.encode()).hexdigest())
print("provider_settings_sha256=" + hashlib.sha256(settings.encode()).hexdigest())
PY

cargo test --locked --release --manifest-path "$task_quiche_source/Cargo.toml" \
    --target-dir build/quic/flow-credit-cargo http3_independent_control_credit \
    -- --nocapture --test-threads=1
