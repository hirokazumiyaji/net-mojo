#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: check_release_version.sh vX.Y.Z}"
if [[ $# != 1 || ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "expected release tag vX.Y.Z, got: $tag" >&2
    exit 1
fi
version="${tag#v}"

pixi_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' pixi.toml | head -n 1)"
recipe_version="$(sed -n 's/^  version: "\([^"]*\)"/\1/p' conda.recipe/recipe.yaml | head -n 1)"

status=0
[ "$pixi_version" = "$version" ] || { echo "pixi.toml version $pixi_version != $version" >&2; status=1; }
[ "$recipe_version" = "$version" ] || { echo "conda.recipe/recipe.yaml version $recipe_version != $version" >&2; status=1; }
exit $status
