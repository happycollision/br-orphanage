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

# Add the PATH line to the user's shell startup files.
#
#   bash -> ~/.bashrc  (interactive shells)
#   zsh  -> ~/.zshenv  (EVERY zsh: interactive, non-interactive, login, script)
#
# zsh only sources ~/.zshrc for interactive shells. Non-interactive zsh — agent
# tool calls, scripts, cron, CI — sources ~/.zshenv instead, so the PATH line
# must live there or the real 'br' binary shadows the wrapper everywhere but an
# interactive prompt (br-orphanage-t9m).
updated=0

append_marked_line() {
    local rc="$1"
    if grep -qF "${MARKER}" "${rc}" 2>/dev/null; then
        echo "already configured: ${rc}"
    else
        printf '\n%s\n' "${LINE}" >> "${rc}"
        echo "updated: ${rc}"
        updated=1
    fi
}

# bash: only touch an rc that already exists.
if [[ -f "${HOME}/.bashrc" ]]; then
    append_marked_line "${HOME}/.bashrc"
fi

# zsh: ensure ~/.zshenv carries the line whenever the user uses zsh — detected
# by an existing ~/.zshenv or ~/.zshrc, or a zsh login shell. Create ~/.zshenv
# if needed; it is the only file guaranteed to load for non-interactive zsh.
if [[ -f "${HOME}/.zshenv" || -f "${HOME}/.zshrc" || "${SHELL:-}" == *zsh ]]; then
    append_marked_line "${HOME}/.zshenv"
fi

# Setup guidance. bash's interactive rc and zsh's ~/.zshenv are the only files
# this installer edits; other shells (fish, nushell, ...) and non-interactive
# bash have no startup file we can safely configure for every invocation. So we
# always print the manual PATH line and a full-path fallback that needs no PATH
# edit at all, and we name the shell when it is not one we auto-configure.
user_shell=$(basename "${SHELL:-}" 2>/dev/null || true)

echo
if [[ "${updated}" -eq 1 ]]; then
    echo "Added the PATH line to your shell startup file(s); open a new shell (or 'source' them)."
else
    echo "No shell startup file was auto-configured."
fi
case "${user_shell}" in
    bash | zsh | "") ;;
    *) echo "Your shell (${user_shell}) is not one this installer configures automatically." ;;
esac

echo
echo "Make sure this directory comes first on PATH — add to your shell's config if needed:"
echo "  ${BIN_DIR}"
echo "  # bash/zsh:  export PATH=\"${BIN_DIR}:\$PATH\""
echo
echo "Verify:"
echo "  command -v br              # should print ${WRAPPER}"
echo "  br orphanage --version     # wrapper version"
echo
echo "No PATH changes needed if you invoke the wrapper by full path:"
echo "  ${WRAPPER} orphanage --version"
