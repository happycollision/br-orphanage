#!/usr/bin/env bash
set -euo pipefail

# install.sh — one-time setup after cloning the beads-sync repo.
#
#   git clone git@github.com:YOURUSER/beads-sync.git ~/.local/share/beads-sync
#   ~/.local/share/beads-sync/install.sh
#
# Puts this repo's bin/ at the FRONT of PATH so the `br` wrapper shadows the
# real binary. The wrapper finds the real binary at runtime by scanning PATH
# and skipping itself, so it keeps working when `br upgrade` replaces the
# real binary or you reinstall it elsewhere.

SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO=$(cd "$(dirname "${SELF}")" && pwd)
BIN_DIR="${REPO}/bin"
MARKER="# beads-sync wrapper"
LINE="export PATH=\"${BIN_DIR}:\$PATH\"  ${MARKER}"

chmod +x "${BIN_DIR}/br"

# Warn (don't fail) if the real br isn't installed yet.
found_real=0
IFS=':' read -ra dirs <<< "${PATH}"
for d in "${dirs[@]}"; do
    [[ -x "${d}/br" ]] || continue
    # shellcheck disable=SC2312 # readlink failure just falls through to "not real"; no return value worth capturing separately
    [[ "$(readlink -f "${d}/br")" = "$(readlink -f "${BIN_DIR}/br")" ]] && continue
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
    echo "  command -v br   # should print ${BIN_DIR}/br"
    echo "  br version      # should pass through to the real binary"
fi
