#!/usr/bin/env bash
set -euo pipefail
# check-tag-version.sh <tag> [version-file]
# Exits 0 iff <tag> equals "v<contents-of-version-file>". Default file: VERSION.
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: check-tag-version.sh <tag> [version-file]" >&2
    exit 2
fi
tag="$1"
version_file="${2:-VERSION}"
expected="v$(cat "${version_file}")"
if [[ "${tag}" != "${expected}" ]]; then
    echo "check-tag-version.sh: tag ${tag} != ${expected} (from ${version_file})" >&2
    exit 1
fi
