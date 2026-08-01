#!/usr/bin/env bash
# Copies the cmux extension SDK into vendor/.
#
# The SDK lives inside the cmux monorepo, which has no package manifest at its
# root, so SwiftPM cannot fetch it as a remote dependency. This clones cmux into
# a temporary directory and keeps only the SDK.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/vendor/CmuxExtensionKit"
ref="${1:-main}"

if [ -d "$dest" ]; then
    echo "SDK already present at $dest. Delete it to refetch."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Cloning manaflow-ai/cmux ($ref)"
git clone --depth 1 --branch "$ref" https://github.com/manaflow-ai/cmux.git "$work/cmux"

mkdir -p "$root/vendor"
cp -R "$work/cmux/Packages/macOS/CmuxExtensionKit" "$dest"
echo "==> Vendored SDK at $dest"
