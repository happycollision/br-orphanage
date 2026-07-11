#!/usr/bin/env bash
set -euo pipefail

# install.sh — git-nook installer.
#
# Normal install:
#   curl -fsSL https://raw.githubusercontent.com/happycollision/git-nook/master/install.sh | bash
#
# Local dev mode: when run from a checkout of this repo, the local
# bin/git-nook is copied instead of downloading release assets.

RELEASE_BASE="${GIT_NOOK_RELEASE_BASE:-https://github.com/happycollision/git-nook/releases/latest/download}"
INSTALL_PATH="${GIT_NOOK_INSTALL_PATH:-${HOME}/.local/bin/git-nook}"

tool_version() {
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

verify_checksum() {
    local file="$1" sums="$2" base actual expected
    base=$(basename "${file}")
    expected=$(awk -v b="${base}" '$2 == b { print $1; found=1 } END { exit(found ? 0 : 1) }' "${sums}") || {
        echo "git-nook: error: checksum file does not contain ${base}" >&2
        return 1
    }

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        echo "git-nook: error: need sha256sum or shasum to verify release asset" >&2
        return 1
    fi

    if [[ "${actual}" != "${expected}" ]]; then
        echo "git-nook: error: checksum mismatch for ${base}" >&2
        echo "git-nook: expected ${expected}" >&2
        echo "git-nook: actual   ${actual}" >&2
        return 1
    fi
}

install_dir=$(dirname "${INSTALL_PATH}")
mkdir -p "${install_dir}"

old_version=""
if [[ -f "${INSTALL_PATH}" ]]; then
    old_version=$(tool_version "${INSTALL_PATH}")
fi

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]:-}" ]]; then
    script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
fi

tmp_dir=""
# SC2329/SC2317: reached only via the EXIT trap below, which newer shellcheck
# (CI) can't see, so it reports the body as unreachable.
# shellcheck disable=SC2329,SC2317 # invoked indirectly via the EXIT trap below
cleanup() {
    [[ -n "${tmp_dir}" ]] && rm -rf "${tmp_dir}"
    return 0
}
trap cleanup EXIT

if [[ -n "${script_dir}" && -f "${script_dir}/bin/git-nook" ]]; then
    src_version=$(cat "${script_dir}/VERSION")
    cp "${script_dir}/bin/git-nook" "${INSTALL_PATH}"
    "${script_dir}/scripts/stamp-version.sh" "${INSTALL_PATH}" "post-v${src_version}-dev"
    echo "installed from local checkout: ${script_dir}/bin/git-nook (post-v${src_version}-dev)"
else
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-nook-install.XXXXXX")
    curl -fsSL "${RELEASE_BASE}/git-nook" -o "${tmp_dir}/git-nook"
    curl -fsSL "${RELEASE_BASE}/git-nook.sha256" -o "${tmp_dir}/git-nook.sha256"
    verify_checksum "${tmp_dir}/git-nook" "${tmp_dir}/git-nook.sha256"
    cp "${tmp_dir}/git-nook" "${INSTALL_PATH}"
    echo "downloaded and verified: ${RELEASE_BASE}/git-nook"
fi
chmod +x "${INSTALL_PATH}"

new_version=$(tool_version "${INSTALL_PATH}")
if [[ -n "${old_version}" && "${old_version}" != "${new_version}" ]]; then
    echo "git-nook: updated ${old_version} -> ${new_version}"
else
    echo "git-nook: installed version ${new_version}"
fi

old_bin="${HOME}/.local/bin/br-orphanage"
if [[ -f "${old_bin}" ]]; then
    echo "note: the old 'br-orphanage' binary is still installed; remove it:"
    echo "  rm '${old_bin}'"
fi

echo
echo "Installed: ${INSTALL_PATH}"
if path_contains_dir "${install_dir}"; then
    echo "'git-nook' is callable now."
else
    echo "Add this directory to PATH to call 'git-nook' by name:"
    echo "  ${install_dir}"
    echo
    echo "Or run it directly:"
    echo "  ${INSTALL_PATH}"
fi
