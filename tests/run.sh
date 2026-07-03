#!/usr/bin/env bash
set -euo pipefail

# tests/run.sh — end-to-end test harness for the beads-sync `br` wrapper.
#
# Everything happens inside a throwaway `mktemp -d` directory, cleaned up on
# exit via trap. Nothing here touches the user's real ~/.local/share/beads-sync
# checkout, the user's real beads data, or any real git remote.
#
# What gets exercised:
#   - A bare git repo stands in for the "central" sync remote.
#   - A fresh CLONE of this repo (the one under test) points at that bare
#     remote. The clone's bin/br is the wrapper under test: its SYNC_REPO
#     resolves via `bin/..` to the clone, not to the real checkout.
#   - The REAL br binary (found on the invoking user's PATH, e.g.
#     ~/.local/bin/br) is used for actual issue-tracker behavior; no fake.
#   - Throwaway "project" repos exercise `br init` / `br push` / `br restore`.
#
# Run: tests/run.sh   (from anywhere; resolves its own path)

# --- Locate repo under test ---------------------------------------------------

SELF=$(readlink -f "${BASH_SOURCE[0]}")
TESTS_DIR=$(cd "$(dirname "${SELF}")" && pwd)
REPO_UNDER_TEST=$(cd "${TESTS_DIR}/.." && pwd)

# --- Sandbox: temp dir + trap cleanup -----------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/beads-sync-test.XXXXXX")

# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below, not called directly
cleanup() {
    local status=$?
    rm -rf "${WORK}"
    exit "${status}"
}
trap cleanup EXIT

# Fake HOME so the real br's user-level config
# (~/.config/beads/config.yaml, per `br config path`) never touches the
# invoking user's actual home directory.
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"
export HOME="${FAKE_HOME}"

# Committer identity for every git operation in this harness.
export GIT_AUTHOR_NAME=test
export GIT_AUTHOR_EMAIL=test@test.invalid
export GIT_COMMITTER_NAME=test
export GIT_COMMITTER_EMAIL=test@test.invalid

# --- Locate the REAL br binary on the invoker's PATH --------------------------
# (Same skip-self logic as bin/br, but we just need any real binary here;
# the actual skip-self behavior of the wrapper itself is exercised separately
# once PATH is rearranged to put the clone's bin/ first.)

find_real_br_on_path() {
    local dir cand
    local IFS=':'
    # shellcheck disable=SC2250 # deliberately unbraced/unquoted: word-splits PATH on the IFS=':' set above to scan each entry
    for dir in $PATH; do
        [[ -n "${dir}" ]] || continue
        cand="${dir}/br"
        [[ -x "${cand}" ]] && [[ -f "${cand}" ]] || continue
        printf '%s\n' "${cand}"
        return 0
    done
    return 1
}

# shellcheck disable=SC2310 # failure is handled explicitly by the || block below (exit 1); set -e need not apply here
REAL_BR=$(find_real_br_on_path) || {
    echo "FATAL: no real 'br' binary found on PATH; install beads_rust first." >&2
    exit 1
}
REAL_BR_RESOLVED=$(readlink -f "${REAL_BR}")
REAL_BR_DIR=$(dirname "${REAL_BR_RESOLVED}")

# --- Pass/fail bookkeeping -----------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0

section() {
    printf '\n=== %s ===\n' "$1"
}

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
    if [[ -f "${path}" ]]; then
        pass "${desc}"
    else
        fail "${desc} (missing file: ${path})"
    fi
}

assert_file_absent() {
    local desc="$1" path="$2"
    if [[ ! -e "${path}" ]]; then
        pass "${desc}"
    else
        fail "${desc} (file unexpectedly present: ${path})"
    fi
}

assert_dir_exists() {
    local desc="$1" path="$2"
    if [[ -d "${path}" ]]; then
        pass "${desc}"
    else
        fail "${desc} (missing directory: ${path})"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass "${desc}"
    else
        fail "${desc} (did not find '${needle}' in output)"
    fi
}

# --- Step 1: bare "central" remote + clone of this repo -----------------------

section "Setup: bare remote + clone of beads-sync under test"

BARE_REMOTE="${WORK}/central-beads-sync.git"
git init -q --bare "${BARE_REMOTE}"

SYNC_CLONE="${WORK}/beads-sync-clone"
# Clone from the real repo under test, then re-point origin at the bare repo
# and push, so the clone (and the bare remote) reflect exactly the commit
# under test without ever touching a real network remote.
git clone -q --no-hardlinks "${REPO_UNDER_TEST}" "${SYNC_CLONE}"
git -C "${SYNC_CLONE}" remote set-url origin "${BARE_REMOTE}"
git -C "${SYNC_CLONE}" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "${SYNC_CLONE}" checkout -q -B main
git -C "${SYNC_CLONE}" branch -q --set-upstream-to=origin/main main

WRAPPER_BR="${SYNC_CLONE}/bin/br"

assert_file_exists "clone contains bin/br" "${WRAPPER_BR}"

# PATH: clone's bin/ first (the wrapper under test), then the real binary's
# dir, so the wrapper's own find_real_br() skips itself and finds the real
# one. We deliberately do NOT add REPO_UNDER_TEST/bin — tests must exercise
# the CLONE's wrapper, never the live checkout's.
export PATH="${SYNC_CLONE}/bin:${REAL_BR_DIR}:${PATH}"

BR_RESOLVED=$(command -v br)
WRAPPER_BR_CANON=$(readlink -f "${WRAPPER_BR}")
BR_RESOLVED_CANON=$(readlink -f "${BR_RESOLVED}")
assert_eq "PATH resolves 'br' to the clone's wrapper" "${WRAPPER_BR_CANON}" "${BR_RESOLVED_CANON}"

# --- Regression check (Task 1): executable bits survive a fresh clone --------

section "Regression: executable bits survive fresh clone (no chmod)"

if [[ -x "${SYNC_CLONE}/bin/br" ]]; then
    pass "bin/br is executable post-clone with no chmod"
else
    fail "bin/br is NOT executable post-clone (Task 1 regression!)"
fi

if [[ -x "${SYNC_CLONE}/install.sh" ]]; then
    pass "install.sh is executable post-clone with no chmod"
else
    fail "install.sh is NOT executable post-clone (Task 1 regression!)"
fi

# --- Helpers for project repos -------------------------------------------------

# `git rev-parse --git-path <p>` returns a path relative to the CURRENT repo
# root when run from a normal repo, but an ABSOLUTE path when run from a
# linked worktree (since the common git dir lives elsewhere). Normalize to
# always-absolute so callers don't have to care which case they're in.
abs_git_path() {
    local repo_dir="$1" rel_path="$2" out
    out=$(cd "${repo_dir}" && git rev-parse --git-path "${rel_path}")
    case "${out}" in
        /*) printf '%s\n' "${out}" ;;
        *)  printf '%s/%s\n' "${repo_dir}" "${out}" ;;
    esac
}

# Creates a fresh git repo at $1, with an initial commit, optionally with a
# fake origin remote pointed at a throwaway bare repo (so project_name()'s
# `git remote get-url origin` path is exercised without touching any real
# remote host).
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

# --- Scenario: br init with a pre-existing .gitignore --------------------------

section "br init: pre-existing .gitignore is byte-identical afterward"

PROJ1="${WORK}/proj-with-gitignore"
make_project_repo "${PROJ1}" yes "proj-with-gitignore"
printf 'node_modules/\n*.log\n' > "${PROJ1}/.gitignore"
cp "${PROJ1}/.gitignore" "${WORK}/gitignore-snapshot"

(cd "${PROJ1}" && br init -q)

if cmp -s "${WORK}/gitignore-snapshot" "${PROJ1}/.gitignore"; then
    pass ".gitignore byte-identical after 'br init' (cmp)"
else
    fail ".gitignore CHANGED after 'br init' (cmp mismatch)"
fi

# --- Scenario: br init without a pre-existing .gitignore -----------------------

section "br init: no .gitignore before -> no .gitignore after"

PROJ2="${WORK}/proj-without-gitignore"
make_project_repo "${PROJ2}" yes "proj-without-gitignore"
assert_file_absent "no .gitignore before init" "${PROJ2}/.gitignore"

(cd "${PROJ2}" && br init -q)

assert_file_absent "no .gitignore after init" "${PROJ2}/.gitignore"

# --- Scenario: .beads/ in exclude file exactly once, idempotent across reruns --

section "br init: .beads/ appears in info/exclude exactly once (idempotent)"

EXCLUDE_FILE=$(abs_git_path "${PROJ2}" info/exclude)
count_beads_lines() { grep -cxF '.beads/' "${EXCLUDE_FILE}" 2>/dev/null || true; }

BEADS_LINE_COUNT=$(count_beads_lines)
assert_eq "exclude has exactly one '.beads/' line after 1st init" "1" "${BEADS_LINE_COUNT}"

# NOTE: the real `br init` (v0.2.16) is NOT idempotent on an already-
# initialized .beads/ — it exits nonzero ("Already initialized ... Use
# --force to reinitialize") unless --force is passed. The wrapper does not
# paper over this (it just runs `"${REAL_BR}" init "$@"` and inherits
# whatever exit code that produces). So "running init repeatedly" is
# exercised here with --force, which is the realistic repeat-init path.
(cd "${PROJ2}" && br init -q --force)
(cd "${PROJ2}" && br init -q --force)

BEADS_LINE_COUNT=$(count_beads_lines)
assert_eq "exclude still has exactly one '.beads/' line after 3 total (forced) inits" "1" "${BEADS_LINE_COUNT}"

# Re-check gitignore damage didn't creep back in across repeated inits either.
assert_file_absent "still no .gitignore after repeated (forced) inits" "${PROJ2}/.gitignore"

# Separately: confirm a *bare* re-init (no --force) on an already-initialized
# workspace fails, and fails with the same exit code the real binary itself
# would produce for the same invocation -- i.e. the wrapper doesn't mask or
# alter that failure.
set +e
(cd "${PROJ2}" && br init -q >/dev/null 2>&1)
WRAPPER_REINIT_EXIT=$?
(cd "${PROJ2}" && "${REAL_BR_RESOLVED}" init -q >/dev/null 2>&1)
REAL_REINIT_EXIT=$?
set -e
if [[ "${WRAPPER_REINIT_EXIT}" -ne 0 ]]; then
    pass "bare re-init on already-initialized workspace fails through the wrapper (exit ${WRAPPER_REINIT_EXIT})"
else
    fail "bare re-init on already-initialized workspace unexpectedly succeeded through the wrapper"
fi
assert_eq "wrapper's re-init exit code matches real binary's for the same invocation" "${REAL_REINIT_EXIT}" "${WRAPPER_REINIT_EXIT}"
# And the exclude file must still be untouched/correct after that failed attempt.
BEADS_LINE_COUNT=$(count_beads_lines)
assert_eq "exclude line count unaffected by the failed bare re-init" "1" "${BEADS_LINE_COUNT}"

# --- Scenario: passthrough of real commands -------------------------------------

section "Passthrough: real commands reach the real br binary transparently"

WRAPPER_VERSION=$(br --version)
REAL_VERSION=$("${REAL_BR_RESOLVED}" --version)
assert_eq "'br --version' matches real binary output" "${REAL_VERSION}" "${WRAPPER_VERSION}"

(cd "${PROJ2}" && br list >/dev/null)
pass "'br list' passes through without error"

(cd "${PROJ2}" && br ready >/dev/null)
pass "'br ready' passes through without error"

# Pass JSON_OUT positionally ($1 via the "_" placeholder for $0) rather than
# splicing it into the -c string: embedding data as shell source would break
# on awkward quote sequences in the JSON.
JSON_OUT=$(cd "${PROJ2}" && br list --json)
if command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # deliberately single-quoted: $1 must be expanded by the inner bash, not spliced in as shell source here
    assert_true "'br list --json' output parses as JSON (jq)" \
        bash -c 'printf "%s" "$1" | jq . >/dev/null' _ "${JSON_OUT}"
else
    # shellcheck disable=SC2016 # deliberately single-quoted: $1 must be expanded by the inner bash, not spliced in as shell source here
    assert_true "'br list --json' output parses as JSON (python3 json.tool)" \
        bash -c 'printf "%s" "$1" | python3 -m json.tool >/dev/null' _ "${JSON_OUT}"
fi

# Exit-code transparency: a failing command's exit code passes through
# unchanged, and matches what the real binary produces for the same
# invocation.
set +e
(cd "${PROJ2}" && br show definitely-not-a-real-id >/dev/null 2>&1)
WRAPPER_EXIT=$?
(cd "${PROJ2}" && "${REAL_BR_RESOLVED}" show definitely-not-a-real-id >/dev/null 2>&1)
REAL_EXIT=$?
set -e

if [[ "${WRAPPER_EXIT}" -ne 0 ]]; then
    pass "failing command's exit code is nonzero through the wrapper (${WRAPPER_EXIT})"
else
    fail "failing command unexpectedly exited 0 through the wrapper"
fi
assert_eq "wrapper exit code matches real binary's exit code for same failing invocation" "${REAL_EXIT}" "${WRAPPER_EXIT}"

# --- Scenario: br push lands tracked files, scoped commit, reaches remote -----

section "br push: tracked files land in projects/<name>/, scoped commit, reaches remote"

PUSH_PROJ="${WORK}/proj-push"
make_project_repo "${PUSH_PROJ}" yes "push-demo"
(cd "${PUSH_PROJ}" && br init -q)

ISSUE_ID=$(cd "${PUSH_PROJ}" && br q "roundtrip test issue")
if [[ -n "${ISSUE_ID}" ]]; then
    pass "issue was created and 'br q' returned a nonempty id (${ISSUE_ID})"
else
    fail "issue creation via 'br q' returned an empty id"
fi

PRE_PUSH_HEAD=$(git -C "${SYNC_CLONE}" rev-parse HEAD)

PUSH_OUT=$(cd "${PUSH_PROJ}" && br push)
assert_contains "'br push' reports success" "${PUSH_OUT}" "Beads pushed for push-demo"

POST_PUSH_HEAD=$(git -C "${SYNC_CLONE}" rev-parse HEAD)
if [[ "${PRE_PUSH_HEAD}" != "${POST_PUSH_HEAD}" ]]; then
    pass "'br push' created a new commit in the sync clone"
else
    fail "'br push' did not create a new commit"
fi

PROJECT_DIR="${SYNC_CLONE}/projects/push-demo"
assert_file_exists "issues.jsonl landed in projects/push-demo/" "${PROJECT_DIR}/issues.jsonl"
assert_file_exists "config.yaml landed in projects/push-demo/" "${PROJECT_DIR}/config.yaml"
assert_file_exists "metadata.json landed in projects/push-demo/" "${PROJECT_DIR}/metadata.json"
assert_file_absent "beads.db did NOT land in projects/push-demo/ (local-only state)" "${PROJECT_DIR}/beads.db"

CHANGED_PATHS=$(git -C "${SYNC_CLONE}" show --name-only --format='' HEAD)
BAD_PATHS=$(printf '%s\n' "${CHANGED_PATHS}" | grep -v '^projects/push-demo/' || true)
if [[ -z "${BAD_PATHS}" ]]; then
    pass "push commit touches ONLY projects/push-demo/"
else
    fail "push commit touched paths outside projects/push-demo/: ${BAD_PATHS}"
fi

if grep -qF "roundtrip test issue" "${PROJECT_DIR}/issues.jsonl"; then
    pass "pushed issues.jsonl contains the created issue"
else
    fail "pushed issues.jsonl missing the created issue"
fi

# Did it reach the fake central bare remote?
BARE_HEAD=$(git -C "${BARE_REMOTE}" rev-parse main 2>/dev/null || git -C "${BARE_REMOTE}" rev-parse HEAD)
assert_eq "push reached the fake central bare remote" "${POST_PUSH_HEAD}" "${BARE_HEAD}"

# --- Scenario: br push again with no changes is a clean no-op -----------------

section "br push: second push with no changes is a clean no-op"

HEAD_BEFORE_NOOP=$(git -C "${SYNC_CLONE}" rev-parse HEAD)
set +e
NOOP_OUT=$(cd "${PUSH_PROJ}" && br push 2>&1)
NOOP_EXIT=$?
set -e
assert_eq "no-op push exits 0" "0" "${NOOP_EXIT}"
assert_contains "no-op push reports no changes" "${NOOP_OUT}" "No beads changes to commit"
HEAD_AFTER_NOOP=$(git -C "${SYNC_CLONE}" rev-parse HEAD)
assert_eq "no-op push does not create a new commit" "${HEAD_BEFORE_NOOP}" "${HEAD_AFTER_NOOP}"

# --- Scenario: br restore into a fresh clone (round-trip) ----------------------

section "br restore: fresh clone bootstraps workspace and round-trips issues"

# Clone the *project* repo fresh (simulating a new machine), with no .beads/.
RESTORE_PROJ="${WORK}/proj-push-restored"
git clone -q "${PUSH_PROJ}" "${RESTORE_PROJ}"
# The clone's origin now points at PUSH_PROJ's local path, not the fake
# "origin" bare repo PUSH_PROJ itself uses — reset it to the same origin
# PUSH_PROJ has, so project_name() resolves identically ("push-demo").
PUSH_PROJ_ORIGIN=$(git -C "${PUSH_PROJ}" remote get-url origin)
git -C "${RESTORE_PROJ}" remote set-url origin "${PUSH_PROJ_ORIGIN}"

assert_file_absent "fresh clone has no .beads/ before restore" "${RESTORE_PROJ}/.beads"

RESTORE_OUT=$(cd "${RESTORE_PROJ}" && br restore)
assert_contains "'br restore' reports files restored" "${RESTORE_OUT}" "Restored"

assert_dir_exists "workspace bootstrapped: .beads/ exists after restore" "${RESTORE_PROJ}/.beads"
assert_file_exists "issues.jsonl restored into .beads/" "${RESTORE_PROJ}/.beads/issues.jsonl"

RESTORE_EXCLUDE=$(abs_git_path "${RESTORE_PROJ}" info/exclude)
if grep -qxF '.beads/' "${RESTORE_EXCLUDE}" 2>/dev/null; then
    pass "restore's bootstrap init added '.beads/' to info/exclude"
else
    fail "restore's bootstrap init did NOT add '.beads/' to info/exclude"
fi
assert_file_absent "restore's bootstrap init did not create a stray .gitignore" "${RESTORE_PROJ}/.gitignore"

# The real payoff: does the issue survive the round trip?
RESTORED_LIST=$(cd "${RESTORE_PROJ}" && br list)
assert_contains "issue visible via 'br list' after restore" "${RESTORED_LIST}" "roundtrip test issue"

RESTORED_SHOW=$(cd "${RESTORE_PROJ}" && br show "${ISSUE_ID}")
assert_contains "issue visible via 'br show <id>' after restore" "${RESTORED_SHOW}" "roundtrip test issue"

# --- Scenario: project-name fallback (no origin remote) ------------------------

section "Project-name fallback: no origin remote -> projects/<dirname>/"

NOORIGIN_PROJ="${WORK}/proj-no-origin-fallback"
make_project_repo "${NOORIGIN_PROJ}" no
(cd "${NOORIGIN_PROJ}" && br init -q)
(cd "${NOORIGIN_PROJ}" && br q "fallback naming issue" >/dev/null)

DIRNAME=$(basename "${NOORIGIN_PROJ}")
PUSH_NOORIGIN_OUT=$(cd "${NOORIGIN_PROJ}" && br push)
assert_contains "push with no origin reports success under dirname" "${PUSH_NOORIGIN_OUT}" "Beads pushed for ${DIRNAME}"
assert_file_exists "data landed under projects/<dirname>/ (fallback)" "${SYNC_CLONE}/projects/${DIRNAME}/issues.jsonl"

# --- Scenario: git worktree — exclude file lands in the shared common git dir -

section "git worktree: br init resolves the common (shared) info/exclude"

WT_MAIN="${WORK}/proj-worktree-main"
make_project_repo "${WT_MAIN}" yes "worktree-demo"
WT_LINKED="${WORK}/proj-worktree-linked"
git -C "${WT_MAIN}" worktree add -q -b wt-feature-branch "${WT_LINKED}"

COMMON_EXCLUDE=$(abs_git_path "${WT_MAIN}" info/exclude)
LINKED_EXCLUDE_AS_SEEN=$(abs_git_path "${WT_LINKED}" info/exclude)
COMMON_EXCLUDE_CANON=$(readlink -f "${COMMON_EXCLUDE}")
LINKED_EXCLUDE_CANON=$(readlink -f "${LINKED_EXCLUDE_AS_SEEN}")
assert_eq "worktree's --git-path info/exclude resolves to the main repo's shared exclude file" "${COMMON_EXCLUDE_CANON}" "${LINKED_EXCLUDE_CANON}"

(cd "${WT_LINKED}" && br init -q)

if grep -qxF '.beads/' "${COMMON_EXCLUDE}" 2>/dev/null; then
    pass "'.beads/' landed in the shared/common info/exclude from inside the worktree"
else
    fail "'.beads/' did NOT land in the shared info/exclude (${COMMON_EXCLUDE})"
fi

# Make sure it did NOT create a separate, wrong exclude file under the
# worktree's own .git file location.
WT_GIT_FILE="${WT_LINKED}/.git"
if [[ -f "${WT_GIT_FILE}" ]]; then
    pass "worktree's .git is a file (linked worktree), confirming shared common dir setup"
else
    fail "expected ${WT_GIT_FILE} to be a file pointing at the common git dir"
fi

# --- Empirical check: does real br init touch a top-level .gitignore at all? --

section "Empirical: does real br init (v0.2.16) touch top-level .gitignore?"

EMPIRICAL_PROJ="${WORK}/proj-empirical-gitignore"
mkdir -p "${EMPIRICAL_PROJ}"
git init -q "${EMPIRICAL_PROJ}"
git -C "${EMPIRICAL_PROJ}" commit -q --allow-empty -m "initial commit"

if [[ -e "${EMPIRICAL_PROJ}/.gitignore" ]]; then
    fail "unexpected: .gitignore already present before init in pristine repo"
fi

(cd "${EMPIRICAL_PROJ}" && "${REAL_BR_RESOLVED}" init -q)

if [[ -e "${EMPIRICAL_PROJ}/.gitignore" ]]; then
    fail "EMPIRICAL FINDING CHANGED: real br init v0.2.16 now DOES create a top-level .gitignore -- update README/bin/br comments"
else
    pass "empirically confirmed: real br init v0.2.16 does NOT create/modify a top-level .gitignore (only .beads/ is created)"
fi

REAL_BR_VERSION_STR=$("${REAL_BR_RESOLVED}" --version)
printf '  (real binary under test: %s)\n' "${REAL_BR_VERSION_STR}"

# --- Optional: shellcheck on bin/br, install.sh, and this script --------------

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

# --- Summary --------------------------------------------------------------------

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
