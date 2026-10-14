#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
exec rattler-build build --recipe conda.recipe/recipe.yaml \
    -c conda-forge -c https://conda.modular.com/max "$@"
