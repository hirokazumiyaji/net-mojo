#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/conformance
h2spec_commit=70ac2294010887f48b18e2d64f5cccd48421fad1
gh api "repos/summerwind/h2spec/tarball/$h2spec_commit" > build/conformance/h2spec.tar.gz
rm -rf build/conformance/h2spec-source
mkdir -p build/conformance/h2spec-source
tar -xzf build/conformance/h2spec.tar.gz --strip-components=1 -C build/conformance/h2spec-source
GOTOOLCHAIN=local go -C build/conformance/h2spec-source build -mod=readonly -trimpath \
    -ldflags "-X main.VERSION=2.6.0 -X main.COMMIT=$h2spec_commit" \
    -o "$PWD/build/conformance/h2spec" ./cmd/h2spec
build/conformance/h2spec --version
