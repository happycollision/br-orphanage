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

# --- add / list / show: inner repo creation and wiring ---------------------------

section "add: creates a wired hidden inner repo"

ADD_PROJ="${WORK}/proj-add"
make_project_repo "${ADD_PROJ}" yes "add-demo"

ADD_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" add notes origin)
assert_contains "add reports the new nook" "${ADD_OUT}" "added nook 'notes'"

assert_dir_exists "content dir created with default name" "${ADD_PROJ}/.notes"
assert_file_absent "content dir contains NO .git entry" "${ADD_PROJ}/.notes/.git"
ADD_GITDIR="${ADD_PROJ}/.git/nook/notes.git"
assert_dir_exists "inner git dir hidden under parent .git" "${ADD_GITDIR}"

assert_eq "parent config maps name -> dir" \
    ".notes" "$(git -C "${ADD_PROJ}" config --get nook.notes.dir)"
ADD_EXCLUDE=$(abs_git_path "${ADD_PROJ}" info/exclude)
assert_true "content dir excluded (anchored) in parent info/exclude" \
    grep -qxF '/.notes/' "${ADD_EXCLUDE}"

inner_cfg() { git --git-dir="${ADD_GITDIR}" config --get "$1"; }
ADD_ORIGIN_URL=$(git -C "${ADD_PROJ}" remote get-url origin)
# origin URL is $WORK/origins/add-demo.git -> owner=origins project=add-demo
ADD_REF="refs/nook/origins/add-demo/notes"
assert_eq "inner core.bare false" "false" "$(inner_cfg core.bare)"
assert_eq "inner autocrlf pinned off" "false" "$(inner_cfg core.autocrlf)"
assert_eq "inner remote url resolved from parent remote" "${ADD_ORIGIN_URL}" "$(inner_cfg remote.origin.url)"
assert_eq "inner fetch refspec targets the custom ref" \
    "+${ADD_REF}:refs/remotes/origin/main" "$(inner_cfg remote.origin.fetch)"
assert_eq "inner push refspec publishes main to the custom ref" \
    "refs/heads/main:${ADD_REF}" "$(inner_cfg remote.origin.push)"
assert_eq "branch.main.remote wired" "origin" "$(inner_cfg branch.main.remote)"
assert_eq "branch.main.merge wired to the custom ref" "${ADD_REF}" "$(inner_cfg branch.main.merge)"
assert_eq "inner HEAD is main regardless of init.defaultBranch" \
    "refs/heads/main" "$(git --git-dir="${ADD_GITDIR}" symbolic-ref HEAD)"

assert_eq "parent git status stays clean after add" \
    "" "$(git -C "${ADD_PROJ}" status --porcelain)"

section "add: --dir and --ref overrides; URL targets"

ADD_TGT_BARE="${WORK}/targets/add-ext.git"
mkdir -p "$(dirname "${ADD_TGT_BARE}")"
git init -q --bare "${ADD_TGT_BARE}"
(cd "${ADD_PROJ}" && "${NOOK}" add scratch "${ADD_TGT_BARE}" --dir tmp/scratch --ref 'my-nooks/<name>')
SCRATCH_GITDIR="${ADD_PROJ}/.git/nook/scratch.git"
assert_eq "URL target stored literally on the inner remote" \
    "${ADD_TGT_BARE}" "$(git --git-dir="${SCRATCH_GITDIR}" config --get remote.origin.url)"
assert_eq "non-refs/ template lands under refs/heads/" \
    "refs/heads/main:refs/heads/my-nooks/scratch" \
    "$(git --git-dir="${SCRATCH_GITDIR}" config --get remote.origin.push)"
assert_dir_exists "custom --dir honored" "${ADD_PROJ}/tmp/scratch"
assert_true "custom dir excluded" grep -qxF '/tmp/scratch/' "${ADD_EXCLUDE}"

# Names differing only by case would collide on case-insensitive filesystems.
CASE_PROJ="${WORK}/proj-case-collide"
make_project_repo "${CASE_PROJ}" yes "case-collide"
(cd "${CASE_PROJ}" && "${NOOK}" add Casey origin >/dev/null)
run_cmd_in "${CASE_PROJ}" "${NOOK}" add casey origin
assert_exit_nonzero "case-colliding nook name refused"
assert_contains "case-collision error names the existing nook" "${RUN_OUT}" "Casey"

section "list / show"

LIST_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" list)
assert_contains "list shows notes" "${LIST_OUT}" "notes"
assert_contains "list shows scratch's dir" "${LIST_OUT}" "tmp/scratch/"

SHOW_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" show notes)
assert_contains "show prints the dir" "${SHOW_OUT}" "dir:     .notes/"
assert_contains "show prints the url" "${SHOW_OUT}" "url:     ${ADD_ORIGIN_URL}"
assert_contains "show prints the push refspec" "${SHOW_OUT}" "refs/heads/main:${ADD_REF}"
assert_contains "show prints branch state" "${SHOW_OUT}" "state:"

run_cmd_in "${ADD_PROJ}" "${NOOK}" show nope
assert_exit_nonzero "show of unknown nook exits nonzero"

# Regression: show/list must degrade gracefully (not crash with git's raw
# 128 under pipefail) when a nook's inner git-dir is missing or broken.
# Throwaway repo: rm -rf'ing the inner git-dir corrupts state for reuse.
BROKEN_PROJ="${WORK}/proj-broken-show"
make_project_repo "${BROKEN_PROJ}" yes "broken-show"
(cd "${BROKEN_PROJ}" && "${NOOK}" add wrecked origin >/dev/null)
rm -rf "${BROKEN_PROJ}/.git/nook/wrecked.git"
run_cmd_in "${BROKEN_PROJ}" "${NOOK}" show wrecked
assert_eq "show of nook with missing inner git-dir exits 0" "0" "${RUN_EXIT}"
assert_contains "show of broken nook prints url (none)" "${RUN_OUT}" "url:     (none)"
BROKEN_LIST=$(cd "${BROKEN_PROJ}" && "${NOOK}" list)
assert_contains "list flags the missing inner repo" "${BROKEN_LIST}" "(no inner repo)"

EMPTY_PROJ="${WORK}/proj-empty-list"
make_project_repo "${EMPTY_PROJ}" no
EMPTY_LIST=$(cd "${EMPTY_PROJ}" && "${NOOK}" list)
assert_contains "empty list explains how to create one" "${EMPTY_LIST}" "git nook add"

# --- passthrough: full git against the inner repo --------------------------------

section "passthrough: status/add/commit/log round trip"

PT_PROJ="${WORK}/proj-passthrough"
make_project_repo "${PT_PROJ}" yes "pt-demo"
(cd "${PT_PROJ}" && "${NOOK}" add notes origin)

printf 'hello nook\n' > "${PT_PROJ}/.notes/first.md"
mkdir -p "${PT_PROJ}/.notes/deep/nested"
printf 'nested content\n' > "${PT_PROJ}/.notes/deep/nested/leaf.txt"

PT_STATUS=$(cd "${PT_PROJ}" && "${NOOK}" notes status --porcelain)
assert_contains "status sees the new file" "${PT_STATUS}" "first.md"
# Untracked dirs collapse in porcelain status (vanilla git behavior); use -u
# to confirm the passthrough's git actually walks into nested content.
PT_STATUS_U=$(cd "${PT_PROJ}" && "${NOOK}" notes status --porcelain -uall)
assert_contains "status -uall sees nested files" "${PT_STATUS_U}" "deep/nested/leaf.txt"

(cd "${PT_PROJ}" && "${NOOK}" notes add --all)
(cd "${PT_PROJ}" && "${NOOK}" notes commit -q -m "first nook commit")
PT_LOG=$(cd "${PT_PROJ}" && "${NOOK}" notes log --oneline)
assert_contains "log shows the commit" "${PT_LOG}" "first nook commit"
assert_eq "clean after commit" "" "$(cd "${PT_PROJ}" && "${NOOK}" notes status --porcelain)"

assert_file_absent "still no .git entry in the content dir" "${PT_PROJ}/.notes/.git"
assert_eq "parent status still clean" "" "$(git -C "${PT_PROJ}" status --porcelain)"

section "passthrough: works from a subdirectory and from inside the nook"

mkdir -p "${PT_PROJ}/src"
PT_SUB_LOG=$(cd "${PT_PROJ}/src" && "${NOOK}" notes log --oneline)
assert_contains "passthrough works from a parent subdir" "${PT_SUB_LOG}" "first nook commit"

# From inside the nook dir, relative pathspecs resolve as expected.
printf 'more\n' >> "${PT_PROJ}/.notes/first.md"
(cd "${PT_PROJ}/.notes" && "${NOOK}" notes add first.md)
PT_STAGED=$(cd "${PT_PROJ}" && "${NOOK}" notes diff --cached --name-only)
assert_contains "relative pathspec staged from inside the nook" "${PT_STAGED}" "first.md"
(cd "${PT_PROJ}" && "${NOOK}" notes commit -q -m "second")

section "passthrough: local branches work (single-ref publication is the only limit)"

(cd "${PT_PROJ}" && "${NOOK}" notes checkout -q -b experiment)
printf 'branchy\n' > "${PT_PROJ}/.notes/branch-file.txt"
(cd "${PT_PROJ}" && "${NOOK}" notes add --all && "${NOOK}" notes commit -q -m "on a branch")
(cd "${PT_PROJ}" && "${NOOK}" notes checkout -q main)
assert_file_absent "branch switch updates the nook worktree" "${PT_PROJ}/.notes/branch-file.txt"
assert_eq "parent status STILL clean after branch dance" "" "$(git -C "${PT_PROJ}" status --porcelain)"

section "passthrough: missing content dir fails cleanly and is recoverable"

# Throwaway repo: we rm -rf the content dir while the inner git-dir survives.
GONE_PROJ="${WORK}/proj-gone-worktree"
make_project_repo "${GONE_PROJ}" yes "gone-worktree"
(cd "${GONE_PROJ}" && "${NOOK}" add stash origin >/dev/null)
printf 'keep me\n' > "${GONE_PROJ}/.stash/keeper.txt"
(cd "${GONE_PROJ}" && "${NOOK}" stash add --all && "${NOOK}" stash commit -q -m "keeper")
rm -rf "${GONE_PROJ}/.stash"

run_cmd_in "${GONE_PROJ}" "${NOOK}" stash status
assert_exit_nonzero "passthrough with missing content dir exits nonzero"
assert_contains "missing content dir error is a clean err()" "${RUN_OUT}" "no content dir"

# The recovery procedure the error message prints actually works.
mkdir -p "${GONE_PROJ}/.stash"
(cd "${GONE_PROJ}" && "${NOOK}" stash checkout -- .)
assert_file_exists "recovery hint restores the nook's files" "${GONE_PROJ}/.stash/keeper.txt"

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
