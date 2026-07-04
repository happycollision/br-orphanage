#!/usr/bin/env bash
set -euo pipefail

# install.sh — Beads Orphanage installer.
#
# Normal install:
#   curl -fsSL https://raw.githubusercontent.com/happycollision/br-orphanage/master/install.sh | bash
#
# Local dev mode: when run from a checkout of this repo, the local
# bin/br-orphanage is copied instead of downloading release assets.

RELEASE_BASE="${BR_ORPHANAGE_RELEASE_BASE:-https://github.com/happycollision/br-orphanage/releases/latest/download}"
INSTALL_PATH="${BR_ORPHANAGE_INSTALL_PATH:-${HOME}/.local/bin/br-orphanage}"

wrapper_version() {
    sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1" | head -n 1
}

path_contains_dir() {
    local wanted="$1" dir
    local IFS=':'
    # shellcheck disable=SC2250 # deliberately unbraced/unquoted: word-splits PATH on IFS=':'
    for dir in $PATH; do
        [[ -n "${dir}" ]] || continue
        [[ "${dir}" == "${wanted}" ]] && return 0
    done
    return 1
}

find_real_br() {
    local dir cand
    local IFS=':'
    # shellcheck disable=SC2250 # deliberately unbraced/unquoted: word-splits PATH on IFS=':'
    for dir in $PATH; do
        [[ -n "${dir}" ]] || continue
        cand="${dir}/br"
        [[ -x "${cand}" ]] && [[ -f "${cand}" ]] || continue
        printf '%s\n' "${cand}"
        return 0
    done
    return 1
}

verify_checksum() {
    local file="$1" sums="$2" base actual expected
    base=$(basename "${file}")
    expected=$(awk -v b="${base}" '$2 == b { print $1; found=1 } END { exit(found ? 0 : 1) }' "${sums}") || {
        echo "br-orphanage: error: checksum file does not contain ${base}" >&2
        return 1
    }

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        echo "br-orphanage: error: need sha256sum or shasum to verify release asset" >&2
        return 1
    fi

    if [[ "${actual}" != "${expected}" ]]; then
        echo "br-orphanage: error: checksum mismatch for ${base}" >&2
        echo "br-orphanage: expected ${expected}" >&2
        echo "br-orphanage: actual   ${actual}" >&2
        return 1
    fi
}

install_dir=$(dirname "${INSTALL_PATH}")
mkdir -p "${install_dir}"

old_version=""
if [[ -f "${INSTALL_PATH}" ]]; then
    old_version=$(wrapper_version "${INSTALL_PATH}")
fi

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]:-}" ]]; then
    script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
fi

tmp_dir=""
cleanup() {
    [[ -n "${tmp_dir}" ]] && rm -rf "${tmp_dir}"
    return 0
}
trap cleanup EXIT

if [[ -n "${script_dir}" && -f "${script_dir}/bin/br-orphanage" ]]; then
    cp "${script_dir}/bin/br-orphanage" "${INSTALL_PATH}"
    echo "installed from local checkout: ${script_dir}/bin/br-orphanage"
else
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/br-orphanage-install.XXXXXX")
    curl -fsSL "${RELEASE_BASE}/br-orphanage" -o "${tmp_dir}/br-orphanage"
    curl -fsSL "${RELEASE_BASE}/br-orphanage.sha256" -o "${tmp_dir}/br-orphanage.sha256"
    verify_checksum "${tmp_dir}/br-orphanage" "${tmp_dir}/br-orphanage.sha256"
    cp "${tmp_dir}/br-orphanage" "${INSTALL_PATH}"
    echo "downloaded and verified: ${RELEASE_BASE}/br-orphanage"
fi
chmod +x "${INSTALL_PATH}"

new_version=$(wrapper_version "${INSTALL_PATH}")
if [[ -n "${old_version}" && "${old_version}" != "${new_version}" ]]; then
    echo "br-orphanage: updated ${old_version} -> ${new_version}"
else
    echo "br-orphanage: installed version ${new_version}"
fi

if ! find_real_br >/dev/null 2>&1; then
    echo "warning: real 'br' binary not found in PATH."
    echo "         Install it: https://github.com/Dicklesworthstone/beads_rust"
fi

echo
echo "Installed: ${INSTALL_PATH}"
if path_contains_dir "${install_dir}"; then
    echo "'br-orphanage' is callable now."
else
    echo "Add this directory to PATH to call 'br-orphanage' by name:"
    echo "  ${install_dir}"
    echo
    echo "Or run it directly:"
    echo "  ${INSTALL_PATH}"
fi
