#!/usr/bin/env bash
set -euo pipefail

# install.sh — Beads Orphanage installer.
#
# Normal install (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/happycollision/br-orphanage/master/install.sh | bash
#
# Local dev mode: when run from a checkout of this repo (bin/br-orphanage sits next to
# this script), the local wrapper is copied instead of downloaded, so
# contributors and the test harness exercise the local source.
#
# There is NO auto-update. To update the wrapper, re-run this installer.

RAW_BASE="https://raw.githubusercontent.com/happycollision/br-orphanage/master"
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/br-orphanage"
BIN_DIR="${DATA_DIR}/bin"
WRAPPER="${BIN_DIR}/br-orphanage"
SHADOW="${BIN_DIR}/br"

wrapper_version() {
    sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1" | head -n 1
}

old_version=""
if [[ -f "${WRAPPER}" ]]; then
    old_version=$(wrapper_version "${WRAPPER}")
fi

mkdir -p "${BIN_DIR}"

# Local dev mode detection: BASH_SOURCE is unset when piped via `curl | bash`.
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]:-}" ]]; then
    script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
fi

if [[ -n "${script_dir}" && -f "${script_dir}/bin/br-orphanage" ]]; then
    cp "${script_dir}/bin/br-orphanage" "${WRAPPER}"
    echo "installed from local checkout: ${script_dir}/bin/br-orphanage"
else
    curl -fsSL "${RAW_BASE}/bin/br-orphanage" -o "${WRAPPER}"
    echo "downloaded wrapper from ${RAW_BASE}/bin/br-orphanage"
fi
chmod +x "${WRAPPER}"

new_version=$(wrapper_version "${WRAPPER}")
if [[ -n "${old_version}" && "${old_version}" != "${new_version}" ]]; then
    echo "br-orphanage: updated ${old_version} -> ${new_version}"
else
    echo "br-orphanage: installed version ${new_version}"
fi

# The inert shadow: a 'br' symlink beside the canonical wrapper. Harmless until
# the user prepends BIN_DIR to PATH — see 'br-orphanage shell-intercept'. The
# target is relative so the link survives the data dir being moved.
ln -sf "br-orphanage" "${SHADOW}"

# Make 'br-orphanage' callable by name with no shell edit: symlink it into the
# first writable directory already on PATH (skipping our own BIN_DIR).
find_writable_path_dir() {
    local dir
    local IFS=':'
    # shellcheck disable=SC2250,SC2312 # deliberately unbraced/unquoted: word-splits PATH on IFS=':'
    for dir in $PATH; do
        [[ -n "${dir}" ]] || continue
        [[ "${dir}" == "${BIN_DIR}" ]] && continue
        [[ -d "${dir}" && -w "${dir}" ]] || continue
        printf '%s\n' "${dir}"
        return 0
    done
    return 1
}

callable_by_name=0
# shellcheck disable=SC2310 # failure handled by the if
if target_dir=$(find_writable_path_dir); then
    ln -sf "${WRAPPER}" "${target_dir}/br-orphanage"
    echo "linked: ${target_dir}/br-orphanage -> ${WRAPPER}"
    callable_by_name=1
fi

# Warn (don't fail) if the real br isn't installed yet.
found_real=0
IFS=':' read -ra dirs <<< "${PATH}"
for d in "${dirs[@]}"; do
    [[ -x "${d}/br" ]] || continue
    # shellcheck disable=SC2312 # readlink failure just falls through to "not real"
    [[ "$(readlink -f "${d}/br")" = "$(readlink -f "${WRAPPER}")" ]] && continue
    found_real=1
    break
done
if [[ "${found_real}" -eq 0 ]]; then
    echo "warning: real 'br' binary not found in PATH."
    echo "         Install it: https://github.com/Dicklesworthstone/beads_rust"
fi

echo
if [[ "${callable_by_name}" -eq 1 ]]; then
    echo "Installed. 'br-orphanage' is callable now (no shell changes were made)."
else
    echo "Installed. No writable PATH directory was found, so call it by full path:"
    echo "  ${WRAPPER}"
fi
echo
echo "To make the real 'br' route through this wrapper (optional), run:"
echo "  br-orphanage shell-intercept"
echo "It prints exactly what to add to your shell config and changes nothing on its own."
