#!/usr/bin/env bash
set -euo pipefail

# tests/run.sh — end-to-end harness for git-nook.
#
# Everything runs inside a throwaway `mktemp -d`, cleaned up on exit via
# trap. Nothing touches the invoking user's real home directory, git
# config, or any real remote. git-nook depends only on git — no br needed.
#
# Run: tests/run.sh   (from anywhere; resolves its own path)

SELF=$(readlink -f "${BASH_SOURCE[0]}")
TESTS_DIR=$(cd "$(dirname "${SELF}")" && pwd)
REPO_UNDER_TEST=$(cd "${TESTS_DIR}/.." && pwd)
NOOK="${REPO_UNDER_TEST}/bin/git-nook"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-nook-test.XXXXXX")
# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${desc}"
    else
        fail "${desc} (expected: '${expected}', actual: '${actual}')"
    fi
}

# shellcheck disable=SC2329 # reserved for later-task assertions
assert_true() {
    local desc="$1"
    shift
    if "$@"; then
        pass "${desc}"
    else
        fail "${desc} (command failed: $*)"
    fi
}

# shellcheck disable=SC2329 # reserved for later-task assertions
assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "${path}" ]]; then pass "${desc}"; else fail "${desc} (missing file: ${path})"; fi
}

# shellcheck disable=SC2329 # reserved for later-task assertions
assert_file_absent() {
    local desc="$1" path="$2"
    if [[ ! -e "${path}" ]]; then pass "${desc}"; else fail "${desc} (file unexpectedly present: ${path})"; fi
}

# shellcheck disable=SC2329 # reserved for later-task assertions
assert_dir_exists() {
    local desc="$1" path="$2"
    if [[ -d "${path}" ]]; then pass "${desc}"; else fail "${desc} (missing directory: ${path})"; fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass "${desc}"
    else
        fail "${desc} (did not find '${needle}' in output; got: '${haystack}')"
    fi
}

# Run a command expected to FAIL; captures RUN_OUT / RUN_EXIT for assertions.
RUN_OUT=""
RUN_EXIT=0
run_cmd() {
    set +e
    RUN_OUT=$("$@" 2>&1)
    RUN_EXIT=$?
    set -e
}

# Same, but run from a directory (macOS env has no -C; use a subshell cd).
run_cmd_in() {
    local dir="$1"
    shift
    set +e
    RUN_OUT=$(cd "${dir}" && "$@" 2>&1)
    RUN_EXIT=$?
    set -e
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

# `git rev-parse --git-path <p>` is relative from a normal repo but absolute
# from a linked worktree. Normalize to always-absolute.
# shellcheck disable=SC2329 # reserved for later-task assertions
abs_git_path() {
    local repo_dir="$1" rel_path="$2" out
    out=$(cd "${repo_dir}" && git rev-parse --git-path "${rel_path}")
    case "${out}" in
        /*) printf '%s\n' "${out}" ;;
        *)  printf '%s/%s\n' "${repo_dir}" "${out}" ;;
    esac
}

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

# --- Command surface: version, help, unknown commands ---------------------------

section "command surface: version, help, unknown commands"

SRC_VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${NOOK}" | head -n 1)
if [[ -n "${SRC_VERSION}" ]]; then
    pass "bin/git-nook declares a VERSION (${SRC_VERSION})"
else
    fail "bin/git-nook has no VERSION= line"
fi

assert_eq "git-nook --version prints its version" \
    "git-nook ${SRC_VERSION}" "$("${NOOK}" --version)"

NOOK_HELP=$("${NOOK}" --help)
assert_contains "--help shows the add surface" "${NOOK_HELP}" "git nook add <name>"
assert_contains "--help shows the passthrough surface" "${NOOK_HELP}" "<git-args...>"

# Unknown flags fail loudly.
run_cmd "${NOOK}" --frobnicate
assert_exit_nonzero "unknown option exits nonzero"
assert_contains "unknown option names the offender" "${RUN_OUT}" "--frobnicate"

# Unknown bare word outside any repo: still a clean error (not a git crash).
run_cmd_in "${WORK}" "${NOOK}" frobnicate
assert_exit_nonzero "unknown command outside a repo exits nonzero"

# Unknown bare word inside a repo with no nooks: names the problem + the fix.
UNK_PROJ="${WORK}/proj-unknown"
make_project_repo "${UNK_PROJ}" no
run_cmd_in "${UNK_PROJ}" "${NOOK}" frobnicate status
assert_exit_nonzero "unknown nook name exits nonzero"
assert_contains "unknown nook error names the offender" "${RUN_OUT}" "frobnicate"
assert_contains "unknown nook error points at 'git nook add'" "${RUN_OUT}" "git nook add"

# --- Regression: executable bits tracked in git ----------------------------------

section "regression: executable bits tracked in git (mode 100755)"

BIN_MODE=$(git -C "${REPO_UNDER_TEST}" ls-files -s bin/git-nook | awk '{print $1}')
assert_eq "bin/git-nook tracked as 100755" "100755" "${BIN_MODE}"
INSTALL_MODE=$(git -C "${REPO_UNDER_TEST}" ls-files -s install.sh | awk '{print $1}')
assert_eq "install.sh tracked as 100755" "100755" "${INSTALL_MODE}"

# --- shellcheck (optional, skipped gracefully if unavailable) --------------------

section "shellcheck (optional, skipped gracefully if unavailable)"

if command -v shellcheck >/dev/null 2>&1; then
    for f in "${REPO_UNDER_TEST}/bin/git-nook" "${REPO_UNDER_TEST}/install.sh" "${TESTS_DIR}/run.sh"; do
        if shellcheck "${f}"; then
            pass "shellcheck clean: ${f#"${REPO_UNDER_TEST}"/}"
        else
            fail "shellcheck reported issues: ${f#"${REPO_UNDER_TEST}"/}"
        fi
    done
else
    echo "  shellcheck not installed; skipping."
fi

# --- Summary ---------------------------------------------------------------------

section "Summary"
echo "  passed: ${PASS_COUNT}"
echo "  failed: ${FAIL_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    echo
    echo "FAILED"
    exit 1
fi

echo
echo "ALL PASSED"
exit 0
