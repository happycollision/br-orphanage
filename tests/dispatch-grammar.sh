#!/usr/bin/env bash
set -euo pipefail

# tests/dispatch-grammar.sh — targeted, self-contained test for the new
# `-n <name>`/`--name <name>` selector grammar in bin/git-nook's dispatcher.
#
# Everything runs inside a throwaway `mktemp -d`, cleaned up on exit via
# trap. Nothing touches the invoking user's real home directory, git
# config, or any real remote. This script invokes ONLY the repo copy of
# git-nook (never the machine's installed copy, never bare `git nook`).
#
# Run: tests/dispatch-grammar.sh   (from anywhere; resolves its own path)

SELF=$(readlink -f "${BASH_SOURCE[0]}")
TESTS_DIR=$(cd "$(dirname "${SELF}")" && pwd)
REPO_UNDER_TEST=$(cd "${TESTS_DIR}/.." && pwd)
NOOK="${REPO_UNDER_TEST}/bin/git-nook"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-nook-dispatch-test.XXXXXX")
# shellcheck disable=SC2329,SC2317 # invoked indirectly via the EXIT trap below
cleanup() {
    local status=$?
    rm -rf "${WORK}"
    exit "${status}"
}
trap cleanup EXIT

# Fake HOME + no system config: the user's real gitconfig (aliases,
# autocrlf, excludesFile) must never leak into test behavior.
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"
export HOME="${FAKE_HOME}"
export XDG_DATA_HOME="${FAKE_HOME}/.local/share"
export XDG_CONFIG_HOME="${FAKE_HOME}/.config"
export GIT_CONFIG_NOSYSTEM=1

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test.invalid

git config --global pull.rebase false

# --- Pass/fail bookkeeping -----------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0

section() { printf '\n=== %s ===\n' "$1"; }

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  [PASS] %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  [FAIL] %s\n' "$1" >&2
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass "${desc}"
    else
        fail "${desc} (did not find '${needle}' in output; got: '${haystack}')"
    fi
}

# Run a command from a directory (macOS env has no -C; use a subshell cd);
# captures RUN_OUT / RUN_EXIT for assertions. Never fails the script itself
# even if the command exits nonzero.
RUN_OUT=""
RUN_EXIT=0
run_cmd_in() {
    local dir="$1"
    shift
    set +e
    RUN_OUT=$(cd "${dir}" && "$@" 2>&1)
    RUN_EXIT=$?
    set -e
}

assert_exit_zero() {
    local desc="$1"
    if [[ "${RUN_EXIT}" -eq 0 ]]; then
        pass "${desc}"
    else
        fail "${desc} (exited ${RUN_EXIT}; output: '${RUN_OUT}')"
    fi
}

assert_exit_nonzero() {
    local desc="$1"
    if [[ "${RUN_EXIT}" -ne 0 ]]; then
        pass "${desc} (${RUN_EXIT})"
    else
        fail "${desc} (unexpectedly exited 0; output: '${RUN_OUT}')"
    fi
}

# --- Shared helpers -------------------------------------------------------------

# Fresh git repo at $1 with an initial commit; optionally a fake bare origin
# at $WORK/origins/<name>.git (which doubles as an own-repo publish target).
make_project_repo() {
    local dir="$1" want_origin="${2:-yes}" name="${3:-}"
    mkdir -p "${dir}"
    git init -q "${dir}"
    git -C "${dir}" commit -q --allow-empty -m "initial commit"
    if [[ "${want_origin}" == "yes" ]]; then
        local origin_bare="${WORK}/origins/${name}.git"
        mkdir -p "$(dirname "${origin_bare}")"
        git init -q --bare "${origin_bare}"
        git -C "${dir}" remote add origin "${origin_bare}"
    fi
}

# --- Setup ------------------------------------------------------------------

PROJECT="${WORK}/project"
make_project_repo "${PROJECT}" yes proj

# --- 1. Former reserved word / git verb is now a valid, usable nook name ------

section "1. nook named after a former reserved word / git verb"

run_cmd_in "${PROJECT}" "${NOOK}" init push origin
assert_exit_zero "init nook named 'push'"

run_cmd_in "${PROJECT}" "${NOOK}" -n push run status
assert_exit_zero "'-n push run status' reaches the nook"

run_cmd_in "${PROJECT}" "${NOOK}" -n push show
assert_exit_zero "'-n push show' succeeds"
assert_contains "'-n push show' prints the nook name" "${RUN_OUT}" "name:     push"

run_cmd_in "${PROJECT}" "${NOOK}" -n push remove
assert_exit_zero "'-n push remove' succeeds"

# --- 2. `-n <n>` before `run` is git-nook's; anything after `run` is git's verbatim ---

section "2. 'run' is a hard boundary — git-nook does no further option parsing after it"

run_cmd_in "${PROJECT}" "${NOOK}" init notes origin
assert_exit_zero "init nook 'notes'"

NOTES_DIR="${PROJECT}/notes"
echo "hello" > "${NOTES_DIR}/hello.txt"
run_cmd_in "${NOTES_DIR}" "${NOOK}" -n notes run add hello.txt
assert_exit_zero "'-n notes run add hello.txt' succeeds"
run_cmd_in "${NOTES_DIR}" "${NOOK}" -n notes run commit -m "add hello"
assert_exit_zero "'-n notes run commit' succeeds"

run_cmd_in "${PROJECT}" "${NOOK}" -n notes run log -n 1
assert_exit_zero "'-n notes run log -n 1' succeeds (git's -n, not git-nook's)"
COMMIT_COUNT=$(printf '%s\n' "${RUN_OUT}" | grep -c '^commit ' || true)
assert_contains "log -n 1 output contains exactly one commit" "${COMMIT_COUNT}" "1"

# --- 3. Error cases -----------------------------------------------------------

section "3. error cases"

run_cmd_in "${PROJECT}" "${NOOK}" -n
assert_exit_nonzero "'-n' with no following token fails"
assert_contains "'-n' error message" "${RUN_OUT}" "missing value for -n/--name"

# The -n dispatch resolves a bare/partial name to its full slug before
# printing these messages (e.g. "notes" -> "notes.<id3>.<owner>.<repo>"), so
# the error text names the resolved slug, not the bare name typed on the CLI.
run_cmd_in "${PROJECT}" "${NOOK}" -n notes
assert_exit_nonzero "'-n notes' with no verb fails"
assert_contains "'-n notes' error message" "${RUN_OUT}" "no command given for nook 'notes."

run_cmd_in "${PROJECT}" "${NOOK}" -n notes bogus
assert_exit_nonzero "'-n notes bogus' fails (unknown verb)"
assert_contains "'-n notes bogus' error message" "${RUN_OUT}" "unknown command 'bogus' for nook 'notes."

run_cmd_in "${PROJECT}" "${NOOK}" beads status
assert_exit_nonzero "old bare-name shorthand 'beads status' fails (regression guard)"
assert_contains "bare-name shorthand error message" "${RUN_OUT}" "unknown command 'beads'"

# The -n value is validated (ref-format/shape only) before dispatching. A
# name shaped like a flag, empty, or containing '/' is rejected with the same
# clear message `init`/`clone` give — NOT confused for a nook or a verb.
run_cmd_in "${PROJECT}" "${NOOK}" -n -x run status
assert_exit_nonzero "'-n -x run status' fails (flag-shaped name rejected)"
assert_contains "'-n -x' error message" "${RUN_OUT}" "not a valid nook name"

run_cmd_in "${PROJECT}" "${NOOK}" -n '' show
assert_exit_nonzero "'-n \"\" show' fails (empty name rejected)"
assert_contains "'-n \"\"' error message" "${RUN_OUT}" "not a valid nook name"

run_cmd_in "${PROJECT}" "${NOOK}" -n 'bad/name' show
assert_exit_nonzero "'-n bad/name show' fails (slash in name rejected)"
assert_contains "'-n bad/name' error message" "${RUN_OUT}" "not a valid nook name"

# --- 4. --name long form works everywhere -n does -----------------------------

section "4. '--name' long form"

run_cmd_in "${PROJECT}" "${NOOK}" init pull origin
assert_exit_zero "init nook 'pull'"

run_cmd_in "${PROJECT}" "${NOOK}" --name pull run status
assert_exit_zero "'--name pull run status' works"

run_cmd_in "${PROJECT}" "${NOOK}" --name pull show
assert_exit_zero "'--name pull show' works"
assert_contains "'--name pull show' prints the nook name" "${RUN_OUT}" "name:     pull"

# --- 5. 'run' requires a CONFIGURED nook (respect the 'remove' contract) -----
#
# `-n <name> remove` is config-only: it deletes the config entry but
# deliberately KEEPS the inner git-dir and checkout on disk. `run` must not
# be fooled by that leftover state into treating the name as still valid.

section "5. 'run' requires a configured nook"

run_cmd_in "${PROJECT}" "${NOOK}" init gone origin
assert_exit_zero "init nook 'gone'"

run_cmd_in "${PROJECT}" "${NOOK}" -n gone remove
assert_exit_zero "'-n gone remove' succeeds"

run_cmd_in "${PROJECT}" "${NOOK}" -n gone run status
assert_exit_nonzero "'-n gone run status' fails after remove (config gone, disk state left behind)"
assert_contains "'-n gone run status' error message" "${RUN_OUT}" "no nook named"

# A name that was never configured at all in this repo.
GHOST_PROJ="${WORK}/proj-ghost"
make_project_repo "${GHOST_PROJ}" no
run_cmd_in "${GHOST_PROJ}" "${NOOK}" -n ghost run status
assert_exit_nonzero "'-n ghost run status' fails for a never-configured name"
assert_contains "'-n ghost run status' error message" "${RUN_OUT}" "no nook named"

# Regression: a normally-added, still-configured nook remains runnable.
run_cmd_in "${PROJECT}" "${NOOK}" -n notes run status
assert_exit_zero "'-n notes run status' still works for a configured nook"

# --- Summary ------------------------------------------------------------------

section "Summary"
printf 'PASS: %d, FAIL: %d\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
