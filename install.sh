#!/usr/bin/env bash
set -euo pipefail

# install.sh — Beads Orphanage installer.
#
# Normal install (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/happycollision/br-orphanage/master/install.sh | bash
#
# Local dev mode: when run from a checkout of this repo (bin/br sits next to
# this script), the local wrapper is copied instead of downloaded, so
# contributors and the test harness exercise the local source.
#
# There is NO auto-update. To update the wrapper, re-run this installer.

RAW_BASE="https://raw.githubusercontent.com/happycollision/br-orphanage/master"
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/br-orphanage"
BIN_DIR="${DATA_DIR}/bin"
WRAPPER="${BIN_DIR}/br"
MARKER="# br-orphanage"
LINE="export PATH=\"${BIN_DIR}:\$PATH\"  ${MARKER}"

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

if [[ -n "${script_dir}" && -f "${script_dir}/bin/br" ]]; then
    cp "${script_dir}/bin/br" "${WRAPPER}"
    echo "installed from local checkout: ${script_dir}/bin/br"
else
    curl -fsSL "${RAW_BASE}/bin/br" -o "${WRAPPER}"
    echo "downloaded wrapper from ${RAW_BASE}/bin/br"
fi
chmod +x "${WRAPPER}"

new_version=$(wrapper_version "${WRAPPER}")
if [[ -n "${old_version}" && "${old_version}" != "${new_version}" ]]; then
    echo "br-orphanage: updated ${old_version} -> ${new_version}"
else
    echo "br-orphanage: installed version ${new_version}"
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

# Add the PATH line to whichever shell rc files exist.
updated=0
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "${rc}" ]] || continue
    if grep -qF "${MARKER}" "${rc}"; then
        echo "already configured: ${rc}"
    else
        printf '\n%s\n' "${LINE}" >> "${rc}"
        echo "updated: ${rc}"
        updated=1
    fi
done

if [[ "${updated}" -eq 1 ]]; then
    echo
    echo "Open a new shell (or 'source' your rc file), then verify:"
    echo "  command -v br              # should print ${WRAPPER}"
    echo "  br orphanage --version     # wrapper version"
fi
