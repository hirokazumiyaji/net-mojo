#!/usr/bin/env bash
# Fails unless the release tag, pixi.toml, the conda recipe and CHANGELOG.md agree.
set -euo pipefail

tag="${1:?usage: check_release_version.sh vX.Y.Z}"
version="${tag#v}"

pixi_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' pixi.toml | head -n 1)"
recipe_version="$(sed -n 's/^  version: "\([^"]*\)"/\1/p' conda.recipe/recipe.yaml | head -n 1)"

status=0
[ "$pixi_version" = "$version" ] || { echo "pixi.toml version $pixi_version != $version" >&2; status=1; }
[ "$recipe_version" = "$version" ] || { echo "conda.recipe/recipe.yaml version $recipe_version != $version" >&2; status=1; }
grep -q "^## \[$version\] - " CHANGELOG.md || { echo "CHANGELOG.md has no '## [$version] - <date>' heading" >&2; status=1; }
exit $status
