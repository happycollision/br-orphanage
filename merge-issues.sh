#!/usr/bin/env bash
set -euo pipefail

# merge-issues.sh — resolve a conflicted issues.jsonl via the real `br`.
#
# Run from anywhere in the parent repo while a `git nook beads pull
# --no-rebase` merge conflict on issues.jsonl is in progress. Do NOT
# hand-resolve JSONL conflict markers: br's import is per-issue,
# newest-wins, and tombstone-protected (deletions are records, not
# absences, so they propagate and never resurrect).
#
# Ported from the retired br-orphanage's merge_inbound, empirically
# validated against br 0.2.16. This script lives on the beads nook itself
# (shadow-tracked; invisible on master).

cd "$(git rev-parse --show-toplevel)"

nook() { git nook beads "$@"; }

if ! nook rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    echo "merge-issues: no merge in progress on the beads nook" >&2
    echo "merge-issues: run this during a conflicted 'git nook beads pull --no-rebase'" >&2
    exit 1
fi
if ! nook ls-files -u -- issues.jsonl | grep -q .; then
    echo "merge-issues: issues.jsonl is not conflicted; nothing to do here." >&2
    echo "merge-issues: resolve remaining conflicts normally, then commit --no-edit and push." >&2
    exit 1
fi

# Take THEIRS (the remote side, index stage 3) as the import source.
nook show :3:issues.jsonl > .beads/issues.jsonl

# Import is per-issue, newest-wins, tombstone-protected; the forced flush
# then exports the FULL post-merge DB (union of both sides) regardless of
# dirty-tracking.
import_out=$(br sync --import-only 2>&1)
printf '%s\n' "${import_out}"
br sync --flush-only --force

# Byte-convergence adoption: br's serialization is not byte-stable across
# machines (e.g. tombstone closed_at back-filling). When the import changed
# nothing in the DB and both files carry the same issue-id set, the two
# files are semantically identical — adopt the remote bytes verbatim so
# both machines publish identical trees instead of ping-ponging.
if ! grep -qE 'Created: [1-9]' <<< "${import_out}" \
    && ! grep -qE 'Updated: [1-9]' <<< "${import_out}"; then
    local_ids=$(sed -n 's/^{"id":"\([^"]*\)".*/\1/p' .beads/issues.jsonl 2>/dev/null | sort) || local_ids=""
    remote_ids=$(nook show :3:issues.jsonl 2>/dev/null | sed -n 's/^{"id":"\([^"]*\)".*/\1/p' | sort) || remote_ids=""
    if [[ -n "${local_ids}" && "${local_ids}" == "${remote_ids}" ]]; then
        nook show :3:issues.jsonl > .beads/issues.jsonl
        echo "merge-issues: adopted remote serialization (no content changes)"
    fi
fi

nook add issues.jsonl
echo "merge-issues: issues.jsonl resolved and staged."
echo "merge-issues: if other files are still conflicted, resolve them normally, then:"
echo "merge-issues:   git nook beads commit --no-edit && git nook beads push"
