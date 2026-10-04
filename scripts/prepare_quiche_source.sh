#!/usr/bin/env bash
set -euo pipefail

cargo fetch --locked --manifest-path net/quic/provider/Cargo.toml

task_quiche_archive=$(python3 - <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import tomllib

lock = tomllib.loads(Path("net/quic/provider/Cargo.lock").read_text())
package = next(p for p in lock["package"] if p["name"] == "quiche")
expected = "61166d27591eb7cb1310eec2b8fc6ae0e0686e9e4ed742a3ffc6317171175e7d"
if package["version"] != "0.29.3" or package["checksum"] != expected:
    raise RuntimeError("quiche version or lockfile checksum does not match the pinned patch")
metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--offline", "--locked", "--format-version", "1",
     "--manifest-path", "net/quic/provider/Cargo.toml"], text=True
))
quiche = next(p for p in metadata["packages"] if p["name"] == "quiche")
source = Path(quiche["manifest_path"]).parent
archive = source.parents[2] / "cache" / source.parent.name / "quiche-0.29.3.crate"
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise RuntimeError("quiche 0.29.3 archive checksum mismatch")
print(archive)
PY
)

mkdir -p build/quic
task_quiche_stage=$(mktemp -d "$PWD/build/quic/quiche-stage.XXXXXX")
trap 'rm -rf "$task_quiche_stage"' EXIT
tar -xzf "$task_quiche_archive" -C "$task_quiche_stage"
task_quiche_patches=(
    quiche-0.29.3-cancel-request.patch
    quiche-0.29.3-collected-stream-ranges.patch
    quiche-0.29.3-unknown-stream-retirement.patch
    quiche-0.29.3-receive-view-compaction.patch
    quiche-0.29.3-receive-budget.patch
    quiche-0.29.3-empty-stream-horizon.patch
    quiche-0.29.3-send-budget.patch
)
for task_quiche_patch in "${task_quiche_patches[@]}"; do
    GIT_CEILING_DIRECTORIES="$task_quiche_stage" \
        git -C "$task_quiche_stage/quiche-0.29.3" apply --whitespace=nowarn \
        "$PWD/net/quic/provider/patches/$task_quiche_patch"
done
rm -rf build/quic/quiche-0.29.3
mv "$task_quiche_stage/quiche-0.29.3" build/quic/quiche-0.29.3
printf '%s\n' "$PWD/build/quic/quiche-0.29.3"
