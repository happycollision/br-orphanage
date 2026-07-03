#!/usr/bin/env bash
set -euo pipefail

# tests/run.sh — end-to-end harness for the Beads Orphanage `br` wrapper.
#
# Everything runs inside a throwaway `mktemp -d`, cleaned up on exit via
# trap. Nothing touches the invoking user's real home directory, data dir,
# beads data, shell rc files, or any real remote.
#
#   - install.sh runs in LOCAL DEV MODE into a fake HOME; the INSTALLED
#     wrapper (never the checkout's bin/br directly) is what tests exercise.
#   - The REAL br binary from the invoker's PATH provides issue-tracker
#     behavior; no fakes.
#   - Bare repos under $WORK stand in for every remote (project origins and
#     orphan-branch sync targets).
#
# Run: tests/run.sh   (from anywhere; resolves its own path)

SELF=$(readlink -f "${BASH_SOURCE[0]}")
TESTS_DIR=$(cd "$(dirname "${SELF}")" && pwd)
REPO_UNDER_TEST=$(cd "${TESTS_DIR}/.." && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/br-orphanage-test.XXXXXX")
# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
cleanup() {
    local status=$?
    rm -rf "${WORK}"
    exit "${status}"
}
trap cleanup EXIT

# Fake HOME so the real br's user-level config, the installer's rc edits,
# and the wrapper's data dir never touch the invoking user's real files.
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"
export HOME="${FAKE_HOME}"
# Pin the data-dir derivation: installer and wrapper honor XDG_DATA_HOME,
# and the invoking user may have it set to a real location.
export XDG_DATA_HOME="${FAKE_HOME}/.local/share"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test.invalid

# --- Locate the REAL br binary on the invoker's PATH --------------------------

find_real_br_on_path() {
    local dir cand
    local IFS=':'
    # shellcheck disable=SC2250 # deliberately unbraced/unquoted: word-splits PATH on the IFS=':' set above
    for dir in $PATH; do
        [[ -n "${dir}" ]] || continue
        cand="${dir}/br"
        [[ -x "${cand}" ]] && [[ -f "${cand}" ]] || continue
        printf '%s\n' "${cand}"
        return 0
    done
    return 1
}

# shellcheck disable=SC2310 # failure handled explicitly by the || block
REAL_BR=$(find_real_br_on_path) || {
    echo "FATAL: no real 'br' binary found on PATH; install beads_rust first." >&2
    exit 1
}
REAL_BR_RESOLVED=$(readlink -f "${REAL_BR}")
REAL_BR_DIR=$(dirname "${REAL_BR_RESOLVED}")

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

assert_true() {
    local desc="$1"
    shift
    if "$@"; then
        pass "${desc}"
    else
        fail "${desc} (command failed: $*)"
    fi
}

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
        fail "${desc} (did not find '${needle}' in output)"
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
# at $WORK/origins/<name>.git (which doubles as an own-repo sync target).
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

# --- Setup: run install.sh in local dev mode ------------------------------------

section "Setup: install.sh (local dev mode) into fake HOME"

INSTALL_DIR="${XDG_DATA_HOME}/br-orphanage"
INSTALLED_BR="${INSTALL_DIR}/bin/br"

touch "${FAKE_HOME}/.bashrc"

INSTALL_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "installer reports local-checkout install" "${INSTALL_OUT}" "installed from local checkout"
assert_file_exists "wrapper installed at data dir" "${INSTALLED_BR}"
assert_true "installed wrapper is executable" test -x "${INSTALLED_BR}"
assert_contains "installer reports the installed version" "${INSTALL_OUT}" "installed version"
assert_true "rc file got the marked PATH line" grep -qF "# br-orphanage" "${FAKE_HOME}/.bashrc"

REINSTALL_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "re-install does not duplicate the rc line" "${REINSTALL_OUT}" "already configured"
RC_LINE_COUNT=$(grep -cF "# br-orphanage" "${FAKE_HOME}/.bashrc" || true)
assert_eq "exactly one marked PATH line after two installs" "1" "${RC_LINE_COUNT}"

# Upgrade reporting: fake an older installed version, re-run installer.
if grep -q '^VERSION=' "${INSTALLED_BR}"; then
    sed -i.bak 's/^VERSION=".*"$/VERSION="0.0.0"/' "${INSTALLED_BR}" && rm -f "${INSTALLED_BR}.bak"
else
    printf 'VERSION="0.0.0"\n' >> "${INSTALLED_BR}"
fi
UPGRADE_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "upgrade reports old -> new version" "${UPGRADE_OUT}" "updated 0.0.0 ->"

# The wrapper under test comes FIRST on PATH; real binary's dir next so the
# wrapper's own PATH scan (skipping itself) finds the real one.
export PATH="${INSTALL_DIR}/bin:${REAL_BR_DIR}:${PATH}"
assert_eq "PATH resolves 'br' to the installed wrapper" \
    "$(readlink -f "${INSTALLED_BR}")" "$(readlink -f "$(command -v br)")"

# --- Regression: executable bits tracked in git ----------------------------------

section "Regression: executable bits tracked in git (mode 100755)"

BIN_MODE=$(git -C "${REPO_UNDER_TEST}" ls-files -s bin/br | awk '{print $1}')
assert_eq "bin/br tracked as 100755" "100755" "${BIN_MODE}"
INSTALL_MODE=$(git -C "${REPO_UNDER_TEST}" ls-files -s install.sh | awk '{print $1}')
assert_eq "install.sh tracked as 100755" "100755" "${INSTALL_MODE}"

# --- Passthrough: real commands reach the real binary transparently --------------

section "Passthrough: real commands reach the real br binary transparently"

# Fixture initialized with the REAL binary directly, so passthrough tests do
# not depend on any wrapper init behavior.
PASSTHRU_PROJ="${WORK}/proj-passthrough"
make_project_repo "${PASSTHRU_PROJ}" yes "passthrough-demo"
(cd "${PASSTHRU_PROJ}" && "${REAL_BR_RESOLVED}" init -q)

WRAPPER_VERSION_OUT=$(br --version)
REAL_VERSION_OUT=$("${REAL_BR_RESOLVED}" --version)
assert_eq "'br --version' matches real binary output" "${REAL_VERSION_OUT}" "${WRAPPER_VERSION_OUT}"

(cd "${PASSTHRU_PROJ}" && br list >/dev/null)
pass "'br list' passes through without error"

(cd "${PASSTHRU_PROJ}" && br ready >/dev/null)
pass "'br ready' passes through without error"

JSON_OUT=$(cd "${PASSTHRU_PROJ}" && br list --json)
if command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # deliberately single-quoted: $1 expands in the inner bash
    assert_true "'br list --json' output parses as JSON" \
        bash -c 'printf "%s" "$1" | jq empty' _ "${JSON_OUT}"
elif command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # deliberately single-quoted: $1 expands in the inner bash
    assert_true "'br list --json' output parses as JSON" \
        bash -c 'printf "%s" "$1" | python3 -m json.tool >/dev/null' _ "${JSON_OUT}"
else
    echo "  jq/python3 not installed; skipping JSON parse check."
fi

set +e
(cd "${PASSTHRU_PROJ}" && br show definitely-not-a-real-id >/dev/null 2>&1)
WRAPPER_EXIT=$?
(cd "${PASSTHRU_PROJ}" && "${REAL_BR_RESOLVED}" show definitely-not-a-real-id >/dev/null 2>&1)
REAL_EXIT=$?
set -e
if [[ "${WRAPPER_EXIT}" -ne 0 ]]; then
    pass "failing command's exit code is nonzero through the wrapper (${WRAPPER_EXIT})"
else
    fail "failing command unexpectedly exited 0 through the wrapper"
fi
assert_eq "wrapper exit code matches real binary's for same failing invocation" "${REAL_EXIT}" "${WRAPPER_EXIT}"

# --- shellcheck (optional, skipped gracefully if unavailable) --------------------

section "shellcheck (optional, skipped gracefully if unavailable)"

if command -v shellcheck >/dev/null 2>&1; then
    for f in "${REPO_UNDER_TEST}/bin/br" "${REPO_UNDER_TEST}/install.sh" "${TESTS_DIR}/run.sh"; do
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
