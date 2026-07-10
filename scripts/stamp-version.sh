#!/usr/bin/env bash
set -euo pipefail
# stamp-version.sh <target-file> <version-string>
# Rewrites the VERSION="..." line of <target-file> in place.
target="$1"
version="$2"
# sed -i.bak for BSD(macOS)/GNU portability, matching repo convention.
sed -i.bak "s|^VERSION=.*|VERSION=\"${version}\"|" "${target}"
rm -f "${target}.bak"
