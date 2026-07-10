#!/usr/bin/env bash
set -euo pipefail
# stamp-version.sh <target-file> <version-string>
# Rewrites the VERSION="..." line of <target-file> in place.
if [[ $# -ne 2 ]]; then
    echo "usage: stamp-version.sh <target-file> <version-string>" >&2
    exit 1
fi
target="$1"
version="$2"
if ! grep -q '^VERSION=' "${target}"; then
    echo "stamp-version.sh: no VERSION= line in ${target}" >&2
    exit 1
fi
# sed -i.bak for BSD(macOS)/GNU portability, matching repo convention.
sed -i.bak "s|^VERSION=.*|VERSION=\"${version}\"|" "${target}"
rm -f "${target}.bak"
