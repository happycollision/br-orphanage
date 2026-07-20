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
# SC2329/SC2317: this function is reached only via the EXIT trap below, which
# newer shellcheck (CI) can't see, so it reports the body as unreachable.
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

# Modern git (>=2.27) refuses a plain `pull` on diverged branches unless a
# reconcile strategy is configured, even with --no-edit --allow-unrelated-histories
# on the command line. Pin the merge strategy globally in FAKE_HOME so the
# bootstrap reconcile test (and any other bare `pull`) behaves deterministically
# regardless of the host's git version or global config.
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

assert_file_absent() {
    local desc="$1" path="$2"
    if [[ ! -e "${path}" ]]; then pass "${desc}"; else fail "${desc} (file unexpectedly present: ${path})"; fi
}

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

assert_exit_zero() {
    local desc="$1"
    if [[ "${RUN_EXIT}" -eq 0 ]]; then
        pass "${desc}"
    else
        fail "${desc} (exited ${RUN_EXIT}; output: '${RUN_OUT}')"
    fi
}

# --- Shared helpers -------------------------------------------------------------

# `git rev-parse --git-path <p>` is relative from a normal repo but absolute
# from a linked worktree. Normalize to always-absolute.
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

# --- install.sh (local dev mode into the fake HOME) --------------------------------

section "install.sh: local dev mode"

LOCALBIN="${FAKE_HOME}/.local/bin"
INSTALL_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "installer reports local-checkout install" "${INSTALL_OUT}" "installed from local checkout"
assert_file_exists "git-nook installed at the default user-bin path" "${LOCALBIN}/git-nook"
assert_true "installed git-nook is executable" test -x "${LOCALBIN}/git-nook"
assert_contains "installer reports the installed version" "${INSTALL_OUT}" "installed version"
if [[ "${INSTALL_OUT}" == *"br-orphanage"* || "${INSTALL_OUT}" == *" br "* ]]; then
    fail "installer output still mentions br-orphanage or a br dependency"
else
    pass "installer output has no br-orphanage/br references"
fi

section "install.sh: override path, PATH guidance, upgrade reporting"

FB_HOME="${WORK}/fallback-home"
mkdir -p "${FB_HOME}"
FB_INSTALL="${FB_HOME}/tools/git-nook"
FB_OUT=$(env HOME="${FB_HOME}" GIT_NOOK_INSTALL_PATH="${FB_INSTALL}" PATH="/usr/bin:/bin" \
    "${REPO_UNDER_TEST}/install.sh")
assert_contains "override install names the selected path" "${FB_OUT}" "${FB_INSTALL}"
assert_contains "override install prints PATH guidance" "${FB_OUT}" "${FB_HOME}/tools"
assert_file_exists "override install wrote the selected executable" "${FB_INSTALL}"

sed -i.bak 's/^VERSION=".*"$/VERSION="0.0.0"/' "${LOCALBIN}/git-nook" && rm -f "${LOCALBIN}/git-nook.bak"
UPGRADE_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "upgrade reports old -> new version" "${UPGRADE_OUT}" "updated 0.0.0 ->"

section "install.sh: notes a leftover br-orphanage binary"

touch "${LOCALBIN}/br-orphanage"
OLDBIN_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "installer flags the old binary for removal" "${OLDBIN_OUT}" "br-orphanage"
rm -f "${LOCALBIN}/br-orphanage"

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
# Under the new grammar, an unrecognized LEADING token (not add/list/materialize/
# -n/--name/-h/--help/--version) always falls into the dispatcher's final
# catch-all, regardless of whether a nook by that name exists.
UNK_PROJ="${WORK}/proj-unknown"
make_project_repo "${UNK_PROJ}" no
run_cmd_in "${UNK_PROJ}" "${NOOK}" frobnicate status
assert_exit_nonzero "unknown command exits nonzero"
assert_contains "unknown command error names the offender" "${RUN_OUT}" "frobnicate"
assert_contains "unknown command error points at 'git nook add'" "${RUN_OUT}" "git nook add"

# --- Regression (br-orphanage-jhz): commands run inside a bare repo git-dir ------
#
# Inside a bare repo, `git rev-parse --is-inside-work-tree` prints "false" but
# still EXITS 0, and `git rev-parse --show-toplevel` fails to stderr while its
# command substitution collapses to "" (so `cd "$(...)"` is a no-op that also
# exits 0). Both slip past `set -e`, so subcommands used to continue against a
# stale cwd and print misleading success ("no nooks configured", exit 0).
# Every subcommand that requires a work tree must instead error cleanly + nonzero.
section "regression: subcommands refuse a bare repo work-tree cleanly (br-orphanage-jhz)"

BARE_REPO="${WORK}/bare-jhz.git"
git init -q --bare "${BARE_REPO}"

for sub in list materialize add; do
    run_cmd_in "${BARE_REPO}" "${NOOK}" "${sub}"
    assert_exit_nonzero "'git nook ${sub}' inside a bare repo exits nonzero"
    # The misleading success message must never appear on any of these paths.
    if [[ "${RUN_OUT}" == *"no nooks configured"* ]]; then
        fail "'git nook ${sub}' inside a bare repo must not print 'no nooks configured' (got: '${RUN_OUT}')"
    else
        pass "'git nook ${sub}' inside a bare repo suppresses the misleading 'no nooks configured' message"
    fi
done

# show/remove now require a selector (`-n <name> show|remove`); exercise them
# with the new grammar so they actually reach cmd_show/cmd_remove (which call
# require_work_tree) instead of tripping the dispatcher's unrelated
# unknown-command catch-all for a bare 'show'/'remove' token.
for sub in show remove; do
    run_cmd_in "${BARE_REPO}" "${NOOK}" -n anyname "${sub}"
    assert_exit_nonzero "'git nook -n anyname ${sub}' inside a bare repo exits nonzero"
    if [[ "${RUN_OUT}" == *"no nooks configured"* ]]; then
        fail "'git nook -n anyname ${sub}' inside a bare repo must not print 'no nooks configured' (got: '${RUN_OUT}')"
    else
        pass "'git nook -n anyname ${sub}' inside a bare repo suppresses the misleading 'no nooks configured' message"
    fi
done

# --- Version stamping (scripts/stamp-version.sh + install.sh -dev suffix) --------

section "version stamping"

VERSION_FILE_VALUE=$(cat "${REPO_UNDER_TEST}/VERSION")

# Fresh local-checkout install into a brand-new HOME/path (independent of the
# earlier install/upgrade tests above, so ordering there can't affect this).
STAMP_HOME="${WORK}/stamp-home"
mkdir -p "${STAMP_HOME}"
STAMP_BIN="${STAMP_HOME}/git-nook"
env HOME="${STAMP_HOME}" GIT_NOOK_INSTALL_PATH="${STAMP_BIN}" "${REPO_UNDER_TEST}/install.sh" >/dev/null
assert_eq "local-checkout install stamps post-v<VERSION>-dev" \
    "git-nook post-v${VERSION_FILE_VALUE}-dev" "$("${STAMP_BIN}" --version)"

# Release stamp: a clean vX.Y.Z with no -dev/post- suffix.
REL_BIN="${WORK}/release-git-nook"
cp "${NOOK}" "${REL_BIN}"
"${REPO_UNDER_TEST}/scripts/stamp-version.sh" "${REL_BIN}" "v${VERSION_FILE_VALUE}"
assert_eq "release stamp yields clean vX.Y.Z" \
    "git-nook v${VERSION_FILE_VALUE}" "$("${REL_BIN}" --version)"
assert_eq "release stamp leaves exactly one VERSION= line" \
    "1" "$(grep -c '^VERSION=' "${REL_BIN}")"

# Stamp overwrite: second stamp wins, no leftover placeholder.
"${REPO_UNDER_TEST}/scripts/stamp-version.sh" "${REL_BIN}" "v9.9.9"
assert_eq "second stamp overwrites the version" \
    "git-nook v9.9.9" "$("${REL_BIN}" --version)"
assert_eq "stamp overwrite leaves exactly one VERSION= line" \
    "1" "$(grep -c '^VERSION=' "${REL_BIN}")"
if grep -q 'v0.0.0-dev' "${REL_BIN}"; then
    fail "leftover placeholder v0.0.0-dev found in stamped file after overwrite"
else
    pass "no leftover placeholder after stamp"
fi

# Helper guards (from Task 2 hardening): bad arg count and missing VERSION= line.
run_cmd "${REPO_UNDER_TEST}/scripts/stamp-version.sh" "onlyonearg"
assert_exit_nonzero "stamp-version.sh rejects wrong arg count"

NOVER="${WORK}/no-version.txt"
printf 'hello\n' > "${NOVER}"
run_cmd "${REPO_UNDER_TEST}/scripts/stamp-version.sh" "${NOVER}" "v1.2.3"
assert_exit_nonzero "stamp-version.sh rejects target with no VERSION= line"

# Tag-version guard: exercise the real scripts/check-tag-version.sh (not a
# self-comparison). Use a fixture version-file so we control both sides.
TAG_FIXTURE="${WORK}/tag-version-fixture"
printf '1.2.3\n' > "${TAG_FIXTURE}"

run_cmd "${REPO_UNDER_TEST}/scripts/check-tag-version.sh" "v1.2.3" "${TAG_FIXTURE}"
assert_eq "check-tag-version accepts a matching tag" "0" "${RUN_EXIT}"

run_cmd "${REPO_UNDER_TEST}/scripts/check-tag-version.sh" "v9.9.9" "${TAG_FIXTURE}"
assert_eq "check-tag-version rejects a mismatched tag (exit 1)" "1" "${RUN_EXIT}"

run_cmd "${REPO_UNDER_TEST}/scripts/check-tag-version.sh"
assert_eq "check-tag-version reports a usage error (exit 2)" "2" "${RUN_EXIT}"

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

assert_dir_exists "content dir created with default name" "${ADD_PROJ}/notes"
assert_file_absent "content dir contains NO .git entry" "${ADD_PROJ}/notes/.git"
ADD_GITDIR="${ADD_PROJ}/.git/nook/notes.git"
assert_dir_exists "inner git dir hidden under parent .git" "${ADD_GITDIR}"

assert_eq "parent config maps name -> dir" \
    "notes" "$(git -C "${ADD_PROJ}" config --get nook.notes.dir)"
ADD_EXCLUDE=$(abs_git_path "${ADD_PROJ}" info/exclude)
assert_true "content dir excluded (anchored, no trailing slash: it is a symlink) in parent info/exclude" \
    grep -qxF '/notes' "${ADD_EXCLUDE}"

assert_true "content path is a symlink" test -L "${ADD_PROJ}/notes"
ADD_CANON=$(cd "${ADD_PROJ}" && git rev-parse --git-common-dir)
ADD_CANON="$(cd "${ADD_PROJ}/${ADD_CANON}" && pwd)/nook/notes.nook/notes"
assert_dir_exists "nested work-tree dir exists" "${ADD_CANON}"
assert_eq "symlink points at nested work-tree" \
    "$(cd "${ADD_PROJ}/notes" && pwd -P)" "$(cd "${ADD_CANON}" && pwd -P)"

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
assert_true "custom dir excluded" grep -qxF '/tmp/scratch' "${ADD_EXCLUDE}"

section "add: explicit dotted --dir is still honored"

(cd "${ADD_PROJ}" && "${NOOK}" add secret "${ADD_TGT_BARE}" --dir .secret)
assert_dir_exists "explicit dotted --dir honored" "${ADD_PROJ}/.secret"
assert_true "explicit dotted dir excluded" grep -qxF '/.secret' "${ADD_EXCLUDE}"
assert_true "explicit dotted dir is a symlink" test -L "${ADD_PROJ}/.secret"
SECRET_CANON=$(cd "${ADD_PROJ}" && git rev-parse --git-common-dir)
SECRET_CANON="$(cd "${ADD_PROJ}/${SECRET_CANON}" && pwd)/nook/secret.nook/.secret"
assert_dir_exists "nested work-tree dir exists" "${SECRET_CANON}"
assert_eq "symlink points at nested work-tree" \
    "$(cd "${ADD_PROJ}/.secret" && pwd -P)" "$(cd "${SECRET_CANON}" && pwd -P)"

section "exclude: entry has no trailing slash and remove cleans legacy forms"
EX=${WORK}/proj-exclude
make_project_repo "${EX}" yes excl-demo
(cd "${EX}" && "${NOOK}" add data origin --dir .data >/dev/null)
EX_FILE=$(abs_git_path "${EX}" info/exclude)
assert_true "exclude has the no-slash entry" grep -qxF "/.data" "${EX_FILE}"
if grep -qxF "/.data/" "${EX_FILE}" 2>/dev/null; then fail "exclude unexpectedly has trailing-slash form"; else pass "exclude has no trailing-slash form"; fi
# simulate a legacy trailing-slash line also being present, then remove
printf '/.data/\n' >> "${EX_FILE}"
# unrelated entries must survive a nook remove
printf '/build\n' >> "${EX_FILE}"
(cd "${EX}" && "${NOOK}" -n data remove >/dev/null)
if grep -qxF "/.data" "${EX_FILE}" 2>/dev/null || grep -qxF "/.data/" "${EX_FILE}" 2>/dev/null; then
    fail "remove left a stale exclude entry (either form)"
else
    pass "remove cleaned both exclude forms"
fi
assert_true "unrelated exclude entry preserved across remove" grep -qxF "/build" "${EX_FILE}"

# A --dir that exists but is not a directory (here: a dangling symlink, which
# even fails -e) must be refused cleanly, not crash with a raw mkdir error.
ln -s /nonexistent-target "${ADD_PROJ}/badlink"
run_cmd_in "${ADD_PROJ}" "${NOOK}" add badnook origin --dir badlink
assert_exit_nonzero "--dir pointing at a non-directory refused"
assert_contains "non-directory --dir error is a clean err()" "${RUN_OUT}" "not a directory"
rm "${ADD_PROJ}/badlink"

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

SHOW_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" -n notes show)
assert_contains "show prints the dir" "${SHOW_OUT}" "dir:      notes/"
assert_contains "show prints the url" "${SHOW_OUT}" "url:      ${ADD_ORIGIN_URL}"
assert_contains "show prints the push refspec" "${SHOW_OUT}" "refs/heads/main:${ADD_REF}"
assert_contains "show prints branch state" "${SHOW_OUT}" "state:"

run_cmd_in "${ADD_PROJ}" "${NOOK}" -n nope show
assert_exit_nonzero "show of unknown nook exits nonzero"

# Regression: show/list must degrade gracefully (not crash with git's raw
# 128 under pipefail) when a nook's inner git-dir is missing or broken.
# Throwaway repo: rm -rf'ing the inner git-dir corrupts state for reuse.
BROKEN_PROJ="${WORK}/proj-broken-show"
make_project_repo "${BROKEN_PROJ}" yes "broken-show"
(cd "${BROKEN_PROJ}" && "${NOOK}" add wrecked origin >/dev/null)
rm -rf "${BROKEN_PROJ}/.git/nook/wrecked.git"
run_cmd_in "${BROKEN_PROJ}" "${NOOK}" -n wrecked show
assert_eq "show of nook with missing inner git-dir exits 0" "0" "${RUN_EXIT}"
assert_contains "show of broken nook prints url (none)" "${RUN_OUT}" "url:      (none)"
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

assert_true "content path is a symlink" test -L "${PT_PROJ}/notes"
PT_CANON=$(cd "${PT_PROJ}" && git rev-parse --git-common-dir)
PT_CANON="$(cd "${PT_PROJ}/${PT_CANON}" && pwd)/nook/notes.nook/notes"
assert_dir_exists "nested work-tree dir exists" "${PT_CANON}"
assert_eq "symlink points at nested work-tree" \
    "$(cd "${PT_PROJ}/notes" && pwd -P)" "$(cd "${PT_CANON}" && pwd -P)"

printf 'hello nook\n' > "${PT_PROJ}/notes/first.md"
mkdir -p "${PT_PROJ}/notes/deep/nested"
printf 'nested content\n' > "${PT_PROJ}/notes/deep/nested/leaf.txt"

PT_STATUS=$(cd "${PT_PROJ}" && "${NOOK}" -n notes run status --porcelain)
assert_contains "status sees the new file" "${PT_STATUS}" "first.md"
# Untracked dirs collapse in porcelain status (vanilla git behavior); use -u
# to confirm the passthrough's git actually walks into nested content.
PT_STATUS_U=$(cd "${PT_PROJ}" && "${NOOK}" -n notes run status --porcelain -uall)
assert_contains "status -uall sees nested files" "${PT_STATUS_U}" "deep/nested/leaf.txt"

(cd "${PT_PROJ}" && "${NOOK}" -n notes run add --all)
(cd "${PT_PROJ}" && "${NOOK}" -n notes run commit -q -m "first nook commit")
PT_LOG=$(cd "${PT_PROJ}" && "${NOOK}" -n notes run log --oneline)
assert_contains "log shows the commit" "${PT_LOG}" "first nook commit"
assert_eq "clean after commit" "" "$(cd "${PT_PROJ}" && "${NOOK}" -n notes run status --porcelain)"

assert_file_absent "still no .git entry in the content dir" "${PT_PROJ}/notes/.git"
assert_eq "parent status still clean" "" "$(git -C "${PT_PROJ}" status --porcelain)"

section "passthrough: works from a subdirectory and from inside the nook"

mkdir -p "${PT_PROJ}/src"
PT_SUB_LOG=$(cd "${PT_PROJ}/src" && "${NOOK}" -n notes run log --oneline)
assert_contains "passthrough works from a parent subdir" "${PT_SUB_LOG}" "first nook commit"

# From inside the nook dir, relative pathspecs resolve as expected. The
# configured path is a symlink into the canonical checkout under .git/, so
# cwd here is PHYSICALLY inside the parent's .git/ directory. This works
# because run_passthrough never calls `git rev-parse --show-toplevel` (which
# refuses from inside .git — no work tree there); it derives the inner
# git-dir and canonical checkout from git-common-dir, which ambient discovery
# still resolves correctly even from inside .git, then runs git against
# explicit --git-dir/--work-tree.
printf 'more\n' >> "${PT_PROJ}/notes/first.md"
run_cmd_in "${PT_PROJ}/notes" "${NOOK}" -n notes run add first.md
assert_eq "relative pathspec add from inside the nook succeeded" "0" "${RUN_EXIT}"
PT_STAGED=$(cd "${PT_PROJ}" && "${NOOK}" -n notes run diff --cached --name-only)
assert_contains "relative pathspec staged from inside the nook" "${PT_STAGED}" "first.md"
(cd "${PT_PROJ}" && "${NOOK}" -n notes run commit -q -m "second")

section "passthrough: local branches work (single-ref publication is the only limit)"

(cd "${PT_PROJ}" && "${NOOK}" -n notes run checkout -q -b experiment)
printf 'branchy\n' > "${PT_PROJ}/notes/branch-file.txt"
(cd "${PT_PROJ}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m "on a branch")
(cd "${PT_PROJ}" && "${NOOK}" -n notes run checkout -q main)
assert_file_absent "branch switch updates the nook worktree" "${PT_PROJ}/notes/branch-file.txt"
assert_eq "parent status STILL clean after branch dance" "" "$(git -C "${PT_PROJ}" status --porcelain)"

section "passthrough: works without a materialized symlink; missing checkout points at materialize"

GONE=${WORK}/proj-gone; make_project_repo "${GONE}" yes gone
(cd "${GONE}" && "${NOOK}" add stash origin >/dev/null)
printf 'keep\n' > "${GONE}/stash/keeper.txt"
(cd "${GONE}" && "${NOOK}" -n stash run add --all && "${NOOK}" -n stash run commit -q -m keeper)
# remove the worktree SYMLINK but not the canonical checkout
rm "${GONE}/stash"
# passthrough still works (targets the canonical checkout directly)
GONE_LOG=$(cd "${GONE}" && "${NOOK}" -n stash run log --oneline)
assert_contains "passthrough works without symlink (targets canonical checkout)" "${GONE_LOG}" "keeper"
# now remove the canonical checkout -> clean error at materialize, NO mkdir footgun
CGONE=$(cd "${GONE}" && git rev-parse --git-common-dir); CGONE="$(cd "${GONE}/${CGONE}" && pwd)/nook/stash.nook"
rm -rf "${CGONE}"
run_cmd_in "${GONE}" "${NOOK}" -n stash run status
assert_exit_nonzero "missing canonical checkout exits nonzero"
assert_contains "error points at materialize" "${RUN_OUT}" "git nook materialize"
if [[ "${RUN_OUT}" == *"mkdir"* ]]; then fail "error still suggests the mkdir footgun"; else pass "no mkdir footgun in error"; fi
# recovery via materialize works
(cd "${GONE}" && "${NOOK}" materialize >/dev/null)
assert_file_exists "materialize restored the checkout content" "${GONE}/stash/keeper.txt"

SHOW=$(cd "${GONE}" && "${NOOK}" -n stash show)
assert_contains "show reports the canonical checkout" "${SHOW}" "checkout:"
assert_contains "show reports linked state" "${SHOW}" "linked:"

section "passthrough: ambient git env vars are ignored"

# Wrapper scripts, hooks, and shell prompts export GIT_DIR/GIT_WORK_TREE;
# git-nook must resolve the parent repo from $PWD regardless.
ENVLEAK_OUT=$(cd "${PT_PROJ}" && GIT_DIR=/nonexistent "${NOOK}" -n notes run log --oneline)
assert_contains "exported GIT_DIR is ignored" "${ENVLEAK_OUT}" "first nook commit"
ENVLEAK_WT_OUT=$(cd "${PT_PROJ}" && GIT_WORK_TREE="${WORK}/bogus-worktree" "${NOOK}" -n notes run log --oneline)
assert_contains "exported GIT_WORK_TREE is ignored" "${ENVLEAK_WT_OUT}" "first nook commit"

section "regression: the old bare passthrough form ('git nook <name> <verb>') is gone"

# Guards this suite's own environment (not just tests/dispatch-grammar.sh):
# a bare leading nook name with no -n/run is now just an unrecognized leading
# token, dispatched to the same 'unknown command' catch-all as any other
# unknown word -- there is no more implicit name-then-verb passthrough.
run_cmd_in "${PT_PROJ}" "${NOOK}" notes status
assert_exit_nonzero "old bare form 'notes status' (no -n/run) exits nonzero"
assert_contains "old bare form error names the unrecognized token" "${RUN_OUT}" "unknown command 'notes'"

# --- publish: push/pull through the baked refspecs --------------------------------

section "publish: push lands on the custom ref, nothing else"

PUB_PROJ="${WORK}/proj-publish"
make_project_repo "${PUB_PROJ}" yes "pub-demo"
PUB_BARE="${WORK}/origins/pub-demo.git"
(cd "${PUB_PROJ}" && "${NOOK}" add beads origin --dir .beads)
printf '{"id":"pub-1"}\n' > "${PUB_PROJ}/.beads/issues.jsonl"
(cd "${PUB_PROJ}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m "issues")
(cd "${PUB_PROJ}" && "${NOOK}" -n beads run push -q)

PUB_REF="refs/nook/origins/pub-demo/beads"
PUB_TIP=$(git -C "${PUB_BARE}" rev-parse "${PUB_REF}")
if [[ -n "${PUB_TIP}" ]]; then
    pass "custom ref exists at the target"
else
    fail "custom ref missing at the target"
fi
assert_contains "published tree holds the file" \
    "$(git -C "${PUB_BARE}" show "${PUB_TIP}:issues.jsonl")" "pub-1"

PUB_BRANCHES=$(git -C "${PUB_BARE}" for-each-ref --format='%(refname)' refs/heads)
assert_eq "no branch appeared at the target (hidden ref only)" "" "${PUB_BRANCHES}"

section "publish: tracking state and pull"

PUB_AHEAD=$(cd "${PUB_PROJ}" && "${NOOK}" -n beads run status -sb | head -n 1)
assert_contains "status shows up-to-date tracking after push" "${PUB_AHEAD}" "main"

printf 'change behind their back\n' > "${PUB_PROJ}/.beads/note.txt"
(cd "${PUB_PROJ}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m "second")
PUB_AHEAD2=$(cd "${PUB_PROJ}" && "${NOOK}" -n beads run status -sb | head -n 1)
assert_contains "status reports ahead of tracking" "${PUB_AHEAD2}" "ahead 1"
(cd "${PUB_PROJ}" && "${NOOK}" -n beads run push -q)

section "publish: --ref refs/heads/... publishes a visible branch instead"

BR_PROJ="${WORK}/proj-branch-ref"
make_project_repo "${BR_PROJ}" yes "branch-ref-demo"
BR_BARE="${WORK}/origins/branch-ref-demo.git"
(cd "${BR_PROJ}" && "${NOOK}" add docs origin --ref 'refs/heads/shadow/<name>')
printf 'visible\n' > "${BR_PROJ}/docs/readme.txt"
(cd "${BR_PROJ}" && "${NOOK}" -n docs run add --all && "${NOOK}" -n docs run commit -q -m "docs" && "${NOOK}" -n docs run push -q)
assert_true "branch override published under refs/heads/" \
    git -C "${BR_BARE}" rev-parse --verify -q refs/heads/shadow/docs

# --- bootstrap: add on a machine where the ref already exists ---------------------

section "bootstrap: fresh clone materializes the nook on add"

# Publisher machine.
BS_A="${WORK}/proj-bs-a"
make_project_repo "${BS_A}" yes "bs-demo"
BS_BARE="${WORK}/origins/bs-demo.git"
git -C "${BS_A}" push -q origin HEAD:refs/heads/main
(cd "${BS_A}" && "${NOOK}" add notes origin)
printf 'from machine A\n' > "${BS_A}/notes/shared.md"
mkdir -p "${BS_A}/notes/sub"
printf 'nested\n' > "${BS_A}/notes/sub/inner.md"
(cd "${BS_A}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m "A1" && "${NOOK}" -n notes run push -q)

# Fresh clone = second machine.
BS_B="${WORK}/proj-bs-b"
git clone -q "${BS_BARE}" "${BS_B}"
BS_B_OUT=$(cd "${BS_B}" && "${NOOK}" add notes origin)
assert_contains "add reports the bootstrap" "${BS_B_OUT}" "bootstrapped"
assert_file_exists "content materialized" "${BS_B}/notes/shared.md"
assert_file_exists "nested content materialized" "${BS_B}/notes/sub/inner.md"
assert_true "bootstrap left a symlink" test -L "${BS_B}/notes"
assert_eq "nook clean right after bootstrap" \
    "" "$(cd "${BS_B}" && "${NOOK}" -n notes run status --porcelain)"
BS_B_LOG=$(cd "${BS_B}" && "${NOOK}" -n notes run log --oneline)
assert_contains "history came along" "${BS_B_LOG}" "A1"
assert_eq "parent clone status stays clean" "" "$(git -C "${BS_B}" status --porcelain)"

section "bootstrap: both-sides-exist refuses to touch local files"

BS_C="${WORK}/proj-bs-c"
git clone -q "${BS_BARE}" "${BS_C}"
mkdir -p "${BS_C}/notes"
printf 'precious local-only work\n' > "${BS_C}/notes/local.md"
BS_C_OUT=$(cd "${BS_C}" && "${NOOK}" add notes origin)
assert_contains "add warns about the existing remote ref" "${BS_C_OUT}" "not empty"
assert_contains "add names the reconcile command" "${BS_C_OUT}" "--allow-unrelated-histories"
# The hint must specify --no-rebase: without it, users lacking a configured
# pull.rebase get "Need to specify how to reconcile divergent branches"
# (git >= 2.27) from the exact command we told them to run.
assert_contains "reconcile hint pins the merge strategy" "${BS_C_OUT}" "--no-rebase"
# ...and --no-edit, so interactive users aren't dropped into an editor.
assert_contains "reconcile hint skips the merge-message editor" "${BS_C_OUT}" "--no-edit"
# Pin the NEW -n/run grammar: the hint must be copy-pasteable, and the old bare
# `git nook <name> <subcommand>` form fails with "unknown command '<name>'".
assert_contains "reconcile hint uses -n/run grammar" "${BS_C_OUT}" "git nook -n"
assert_contains "reconcile hint uses run pull" "${BS_C_OUT}" "run pull"
if [[ "${BS_C_OUT}" == *"git nook notes "* ]]; then
    fail "reconcile hint regressed to the old bare 'git nook notes ...' grammar"
else
    pass "reconcile hint does not use the old bare 'git nook notes ...' grammar"
fi
assert_eq "local file untouched" \
    "precious local-only work" "$(cat "${BS_C}/notes/local.md")"

# The printed procedure actually works (same flags as the printed hint, plus
# -q for harness quietness; the explicit flags validate the hint as printed
# rather than leaning on the harness's global pull.rebase pin):
(cd "${BS_C}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m "local files")
(cd "${BS_C}" && "${NOOK}" -n notes run pull -q --no-rebase --no-edit --allow-unrelated-histories)
assert_file_exists "remote content merged in" "${BS_C}/notes/shared.md"
assert_file_exists "local content survived" "${BS_C}/notes/local.md"
(cd "${BS_C}" && "${NOOK}" -n notes run push -q)

section "bootstrap: failure rolls the add back cleanly"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "  [SKIP] running as root; permission-based failure injection unavailable"
else
    # Deterministic failure AFTER ls-remote succeeds: publish real data to the
    # target, then make the canonical checkout dir (where the bootstrap
    # reset --hard now writes) read-only so that write fails. (Root ignores
    # permissions, hence the skip above.)
    BS_D="${WORK}/proj-bs-d"
    make_project_repo "${BS_D}" yes "bs-fail"
    git -C "${BS_D}" push -q origin HEAD:refs/heads/main
    BS_D_SEED="${WORK}/proj-bs-d-seed"
    git clone -q "${WORK}/origins/bs-fail.git" "${BS_D_SEED}"
    (cd "${BS_D_SEED}" && "${NOOK}" add notes origin >/dev/null)
    printf 'seeded\n' > "${BS_D_SEED}/notes/seed.md"
    (cd "${BS_D_SEED}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m seed && "${NOOK}" -n notes run push -q)

    BS_D_CANON=$(cd "${BS_D}" && git rev-parse --git-common-dir); BS_D_CANON="$(cd "${BS_D}/${BS_D_CANON}" && pwd)/nook/notes.nook"
    mkdir -p "${BS_D}/notes"
    mkdir -p "${BS_D_CANON}"
    chmod 555 "${BS_D_CANON}"
    run_cmd_in "${BS_D}" "${NOOK}" add notes origin
    chmod 755 "${BS_D_CANON}" 2>/dev/null || true
    assert_exit_nonzero "bootstrap materialize failure exits nonzero"
    assert_contains "failure says it rolled back" "${RUN_OUT}" "rolled back"
    if git -C "${BS_D}" config --get nook.notes.dir >/dev/null 2>&1; then
        fail "config not rolled back after bootstrap failure"
    else
        pass "config rolled back after bootstrap failure"
    fi
    assert_file_absent "inner repo rolled back" "${BS_D}/.git/nook/notes.git"
    BS_D_EXCLUDE=$(abs_git_path "${BS_D}" info/exclude)
    if grep -qxF '/notes' "${BS_D_EXCLUDE}" 2>/dev/null; then
        fail "exclude entry not rolled back after bootstrap failure"
    else
        pass "exclude entry rolled back after bootstrap failure"
    fi
    # The read-only canonical container makes materialize_one fail at its
    # very first write (creating the nested work-tree dir), before it ever
    # touches ${BS_D}/notes. So the pre-created empty dir is left exactly as
    # it was -- untouched real estate, never folded into a symlink -- and
    # rollback's job is just to remove the (never-populated) canonical
    # checkout. Assert nothing of value was lost, not that a symlink got
    # cleaned up.
    assert_true "empty pre-add dir left untouched (not converted to a symlink)" \
        test -d "${BS_D}/notes" -a ! -L "${BS_D}/notes"
    assert_file_absent "canonical checkout removed by rollback" "${BS_D_CANON}"

    # Once writable again, the same add succeeds (nothing stale left behind).
    BS_D_OUT2=$(cd "${BS_D}" && "${NOOK}" add notes origin)
    assert_contains "re-add after repair bootstraps" "${BS_D_OUT2}" "bootstrapped"
    assert_file_exists "content materialized on retry" "${BS_D}/notes/seed.md"
fi

section "bootstrap: nested --dir rollback removes the symlink and canonical checkout"

# Publisher for a distinct nook name/target so its ref (derived from the
# origin URL) differs from the ones above; seed real published data so
# ls-remote succeeds and the code proceeds to the materialize step.
BS_E_PUB="${WORK}/proj-bs-e-pub"
make_project_repo "${BS_E_PUB}" yes "bs-nested"
git -C "${BS_E_PUB}" push -q origin HEAD:refs/heads/main
(cd "${BS_E_PUB}" && "${NOOK}" add deep origin --dir deep/nested/path >/dev/null)
printf 'nested seed\n' > "${BS_E_PUB}/deep/nested/path/seed.md"
(cd "${BS_E_PUB}" && "${NOOK}" -n deep run add --all && "${NOOK}" -n deep run commit -q -m seed && "${NOOK}" -n deep run push -q)

# Second machine: none of deep/, deep/nested/, deep/nested/path/ exist yet.
# Force materialize (fetch) to fail deterministically by making the target's
# objects unreadable after ls-remote would already see the ref (ls-remote
# only needs refs, not object data). On failure, rollback must remove the
# per-worktree symlink (deep/nested/path, never created as a real dir here)
# and the canonical checkout under the common git dir -- not a nested real
# dir tree, since cmd_add no longer creates one.
BS_E="${WORK}/proj-bs-e"
git clone -q "${WORK}/origins/bs-nested.git" "${BS_E}"
BS_E_BARE="${WORK}/origins/bs-nested.git"
BS_E_REF="refs/nook/origins/bs-nested/deep"
BS_E_TIP=$(git -C "${BS_E_BARE}" rev-parse "${BS_E_REF}")
BS_E_CANON=$(cd "${BS_E}" && git rev-parse --git-common-dir)
BS_E_CANON="$(cd "${BS_E}/${BS_E_CANON}" && pwd)/nook/deep.nook"
# ls-remote only lists refs (succeeds even if the object is unreadable), but
# fetch must actually transfer the commit object, so making just that one
# loose object unreadable fails fetch specifically, after ls-remote passed.
BS_E_OBJPATH="${BS_E_BARE}/objects/${BS_E_TIP:0:2}/${BS_E_TIP:2}"
if [[ -f "${BS_E_OBJPATH}" ]]; then
    chmod 000 "${BS_E_OBJPATH}"
    run_cmd_in "${BS_E}" "${NOOK}" add deep origin --dir deep/nested/path
    chmod 644 "${BS_E_OBJPATH}"
    if [[ "${RUN_EXIT}" -ne 0 ]] && [[ "${RUN_OUT}" == *"rolled back"* ]]; then
        pass "nested --dir bootstrap failure rolls back"
        # cmd_add no longer tracks a "created_root" ancestor to rm -rf: the
        # per-worktree path is a symlink (materialize_one's mkdir -p only
        # creates the ANCESTOR dirs of the symlink, e.g. deep/nested/, as a
        # side effect of `ln -s`), and rollback removes the symlink leaf
        # itself plus the canonical checkout -- not the ancestor directory
        # tree. Assert the leaf symlink and the checkout are gone (the
        # rollback's actual job), not that the whole deep/ tree vanished.
        assert_file_absent "nested symlink leaf removed" "${BS_E}/deep/nested/path"
        assert_file_absent "canonical checkout removed" "${BS_E_CANON}"
    else
        echo "  [SKIP] nested --dir rollback test: could not force a deterministic fetch failure in this environment (exit=${RUN_EXIT}, out='${RUN_OUT}')"
    fi
else
    echo "  [SKIP] nested --dir rollback test: tip commit is not a loose object (already packed) in this environment"
fi

section "add: migrates a pre-existing untracked dir into the canonical checkout"
AM=${WORK}/proj-add-migrate; make_project_repo "${AM}" yes addmig
mkdir -p "${AM}/.data"; printf 'pre\n' > "${AM}/.data/pre.txt"
(cd "${AM}" && "${NOOK}" add data origin --dir .data >/dev/null)
assert_true "add migrated pre-existing dir to a symlink" test -L "${AM}/.data"
AM_CANON=$(cd "${AM}" && git rev-parse --git-common-dir); AM_CANON="$(cd "${AM}/${AM_CANON}" && pwd)/nook/data.nook/.data"
assert_file_exists "pre-existing content moved into nested work-tree" "${AM_CANON}/pre.txt"
assert_file_exists "pre-existing content reachable via symlink" "${AM}/.data/pre.txt"

# --- two clones: concurrency and conflicts ----------------------------------------

section "two clones: non-fast-forward push rejected, then pull/push succeeds"

TC_A="${WORK}/proj-tc-a"
make_project_repo "${TC_A}" yes "tc-demo"
TC_BARE="${WORK}/origins/tc-demo.git"
git -C "${TC_A}" push -q origin HEAD:refs/heads/main
(cd "${TC_A}" && "${NOOK}" add notes origin)
printf 'base\n' > "${TC_A}/notes/doc.md"
(cd "${TC_A}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m base && "${NOOK}" -n notes run push -q)

TC_B="${WORK}/proj-tc-b"
git clone -q "${TC_BARE}" "${TC_B}"
(cd "${TC_B}" && "${NOOK}" add notes origin >/dev/null)

# A pushes a new commit; B commits independently -> B's push must be rejected.
printf 'from A\n' > "${TC_A}/notes/a-only.md"
(cd "${TC_A}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m from-a && "${NOOK}" -n notes run push -q)
printf 'from B\n' > "${TC_B}/notes/b-only.md"
(cd "${TC_B}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m from-b)
run_cmd_in "${TC_B}" "${NOOK}" -n notes run push
assert_exit_nonzero "non-fast-forward push rejected"

(cd "${TC_B}" && "${NOOK}" -n notes run pull -q --no-edit --no-rebase)
(cd "${TC_B}" && "${NOOK}" -n notes run push -q)
TC_TIP=$(git -C "${TC_BARE}" rev-parse refs/nook/origins/tc-demo/notes)
assert_contains "merged tree holds A's file" "$(git -C "${TC_BARE}" ls-tree -r --name-only "${TC_TIP}")" "a-only.md"
assert_contains "merged tree holds B's file" "$(git -C "${TC_BARE}" ls-tree -r --name-only "${TC_TIP}")" "b-only.md"

section "two clones: conflicting edits produce real conflict markers"

(cd "${TC_A}" && "${NOOK}" -n notes run pull -q --no-edit --no-rebase)
printf 'line edited by A\n' > "${TC_A}/notes/doc.md"
(cd "${TC_A}" && "${NOOK}" -n notes run commit -q -am edit-a && "${NOOK}" -n notes run push -q)
printf 'line edited by B\n' > "${TC_B}/notes/doc.md"
(cd "${TC_B}" && "${NOOK}" -n notes run commit -q -am edit-b)
run_cmd_in "${TC_B}" "${NOOK}" -n notes run pull --no-edit --no-rebase
assert_exit_nonzero "conflicting pull exits nonzero"
assert_true "conflict markers present in the working file" \
    grep -q '^<<<<<<<' "${TC_B}/notes/doc.md"

# Resolve like any git repo: pick a merged line, commit, push.
printf 'line edited by A and B\n' > "${TC_B}/notes/doc.md"
(cd "${TC_B}" && "${NOOK}" -n notes run add doc.md && "${NOOK}" -n notes run commit -q --no-edit)
(cd "${TC_B}" && "${NOOK}" -n notes run push -q)
assert_contains "resolution published" \
    "$(git -C "${TC_BARE}" show 'refs/nook/origins/tc-demo/notes:doc.md')" "A and B"
assert_eq "parent repos stayed clean through all of it" \
    "" "$(git -C "${TC_A}" status --porcelain)$(git -C "${TC_B}" status --porcelain)"

# --- add refusals ------------------------------------------------------------------

section "add: a nook may be named after a subcommand (no reserved names)"

REF_PROJ="${WORK}/proj-refusals"
make_project_repo "${REF_PROJ}" yes "refusals-demo"

# RESERVED_NAMES is gone: a nook can be named after any subcommand, including
# 'list', 'add', 'show', 'remove', 'materialize'. It must be creatable AND
# reachable end-to-end through the new -n/run grammar.
run_cmd_in "${REF_PROJ}" "${NOOK}" add list origin
assert_exit_zero "creating a nook named 'list' succeeds"
assert_contains "add reports the new nook named 'list'" "${RUN_OUT}" "added nook 'list'"
run_cmd_in "${REF_PROJ}" "${NOOK}" -n list run status
assert_exit_zero "'-n list run status' reaches the nook named 'list'"

section "add refusals: names"

run_cmd_in "${REF_PROJ}" "${NOOK}" add 'bad/name' origin
assert_exit_nonzero "slash in name refused"

run_cmd_in "${REF_PROJ}" "${NOOK}" add 'bad..name' origin
assert_exit_nonzero "invalid ref component refused"

run_cmd_in "${REF_PROJ}" "${NOOK}" add -leading origin
assert_exit_nonzero "leading dash refused"

section "add refusals: targets and dirs"

run_cmd_in "${REF_PROJ}" "${NOOK}" add notes bogusremote
assert_exit_nonzero "nonexistent remote name refused"
assert_contains "bad target error names the offender" "${RUN_OUT}" "bogusremote"

run_cmd_in "${REF_PROJ}" "${NOOK}" add notes origin --dir ../outside
assert_exit_nonzero "dir escaping the repo refused"
run_cmd_in "${REF_PROJ}" "${NOOK}" add notes origin --dir /abs/path
assert_exit_nonzero "absolute dir refused"
run_cmd_in "${REF_PROJ}" "${NOOK}" add notes origin --dir .git/sneaky
assert_exit_nonzero "dir under .git refused"

# Tracked files: docs/ is committed in the parent.
mkdir -p "${REF_PROJ}/docs"
printf 'tracked\n' > "${REF_PROJ}/docs/real.md"
git -C "${REF_PROJ}" add docs/real.md
git -C "${REF_PROJ}" commit -q -m "tracked docs"
run_cmd_in "${REF_PROJ}" "${NOOK}" add docs origin --dir docs
assert_exit_nonzero "dir with parent-tracked files refused"
assert_contains "tracked-files error explains" "${RUN_OUT}" "tracked"

section "add refusals: duplicates and overlap"

(cd "${REF_PROJ}" && "${NOOK}" add notes origin >/dev/null)
run_cmd_in "${REF_PROJ}" "${NOOK}" add notes origin
assert_exit_nonzero "duplicate nook name refused"
assert_contains "duplicate error points at show" "${RUN_OUT}" "already exists"

run_cmd_in "${REF_PROJ}" "${NOOK}" add nested origin --dir notes/nested
assert_exit_nonzero "dir nesting inside another nook refused"
assert_contains "overlap error names the other nook" "${RUN_OUT}" "notes"
run_cmd_in "${REF_PROJ}" "${NOOK}" add umbrella origin --dir .
assert_exit_nonzero "dir '.' refused"

run_cmd_in "${REF_PROJ}" "${NOOK}" add sub2 origin --dir 'sub/.git/evil'
assert_exit_nonzero "nested .git dir refused"

# A failed add leaves no debris behind.
if git -C "${REF_PROJ}" config --get nook.nested.dir >/dev/null 2>&1; then
    fail "failed add leaked config for 'nested'"
else
    pass "failed add leaked no config"
fi
assert_file_absent "failed add leaked no inner repo" "${REF_PROJ}/.git/nook/nested.git"

# --- remove -------------------------------------------------------------------------

section "remove: config-only, never destroys files or history"

RM_PROJ="${WORK}/proj-remove"
make_project_repo "${RM_PROJ}" yes "remove-demo"
(cd "${RM_PROJ}" && "${NOOK}" add notes origin >/dev/null)
printf 'unpushed work\n' > "${RM_PROJ}/notes/keep.md"
(cd "${RM_PROJ}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m keep)

RM_OUT=$(cd "${RM_PROJ}" && "${NOOK}" -n notes remove)
assert_contains "remove says what it kept" "${RM_OUT}" "kept"
assert_contains "remove prints the manual deletion command" "${RM_OUT}" "rm -rf"

if git -C "${RM_PROJ}" config --get nook.notes.dir >/dev/null 2>&1; then
    fail "config still present after remove"
else
    pass "config gone after remove"
fi
RM_EXCLUDE=$(abs_git_path "${RM_PROJ}" info/exclude)
if grep -qxF '/notes' "${RM_EXCLUDE}" 2>/dev/null || grep -qxF '/notes/' "${RM_EXCLUDE}" 2>/dev/null; then
    fail "remove left a stale exclude entry"
else
    pass "remove cleaned both exclude entry forms"
fi
assert_file_exists "content untouched" "${RM_PROJ}/notes/keep.md"
assert_dir_exists "inner repo (history) untouched" "${RM_PROJ}/.git/nook/notes.git"

run_cmd_in "${RM_PROJ}" "${NOOK}" -n notes run status
assert_exit_nonzero "passthrough for a removed nook fails cleanly"

run_cmd_in "${RM_PROJ}" "${NOOK}" -n notes remove
assert_exit_nonzero "removing a nonexistent nook fails cleanly"

section "remove then re-add: stale inner repo is refused with a hint, then works"

run_cmd_in "${RM_PROJ}" "${NOOK}" add notes origin
assert_exit_nonzero "re-add with stale inner repo refused (history is never silently adopted or destroyed)"
assert_contains "refusal names the stale path" "${RUN_OUT}" ".git/nook/notes.git"

rm -rf "${RM_PROJ}/.git/nook/notes.git" "${RM_PROJ}/notes"
RM_READD=$(cd "${RM_PROJ}" && "${NOOK}" add notes origin)
assert_contains "re-add succeeds after manual cleanup" "${RM_READD}" "added nook 'notes'"

section "add argument parsing: missing values and extra args"

run_cmd_in "${RM_PROJ}" "${NOOK}" add other origin --dir
assert_exit_nonzero "--dir without a value refused"
assert_contains "--dir error names the flag" "${RUN_OUT}" "--dir requires a value"
run_cmd_in "${RM_PROJ}" "${NOOK}" add other origin --ref
assert_exit_nonzero "--ref without a value refused"
run_cmd_in "${RM_PROJ}" "${NOOK}" add other origin surplus
assert_exit_nonzero "extra positional argument refused"
assert_contains "extra positional named" "${RUN_OUT}" "surplus"
run_cmd_in "${RM_PROJ}" "${NOOK}" add
assert_exit_nonzero "missing name/target shows usage error"
assert_contains "usage error printed" "${RUN_OUT}" "usage: git nook add"

# --- isolation: ignore machinery and byte identity ---------------------------------

section "isolation: the nook's own .gitignore filters; the host's never does"

ISO_PROJ="${WORK}/proj-isolation"
make_project_repo "${ISO_PROJ}" yes "iso-demo"
(cd "${ISO_PROJ}" && "${NOOK}" add data origin >/dev/null)

# Host-side ignore machinery that must NOT leak into the nook:
printf '*.kept\n' >> "$(abs_git_path "${ISO_PROJ}" info/exclude)"
printf '*.kept\n' > "${ISO_PROJ}/.gitignore"

# The nook's own .gitignore is authoritative:
printf '*.local\n' > "${ISO_PROJ}/data/.gitignore"
printf 'keep me\n' > "${ISO_PROJ}/data/file.kept"
printf 'never publish\n' > "${ISO_PROJ}/data/state.local"

(cd "${ISO_PROJ}" && "${NOOK}" -n data run add --all && "${NOOK}" -n data run commit -q -m files)
ISO_TRACKED=$(cd "${ISO_PROJ}" && "${NOOK}" -n data run ls-files)
assert_contains "host-excluded pattern still committed in the nook" "${ISO_TRACKED}" "file.kept"
assert_contains "the nook's .gitignore itself is tracked" "${ISO_TRACKED}" ".gitignore"
if [[ "${ISO_TRACKED}" == *"state.local"* ]]; then
    fail "nook .gitignore was not honored"
else
    pass "nook .gitignore honored"
fi
rm -f "${ISO_PROJ}/.gitignore"

section "isolation: byte identity under hostile autocrlf"

# Hostile conversion settings everywhere git would look — except the inner
# repo, whose add-time core.autocrlf=false must win.
git config --global core.autocrlf true
git -C "${ISO_PROJ}" config core.autocrlf true

printf 'crlf line one\r\ncrlf line two\r\n' > "${ISO_PROJ}/data/windows.txt"
CRLF_HASH_BEFORE=$(shasum "${ISO_PROJ}/data/windows.txt" | awk '{print $1}')
(cd "${ISO_PROJ}" && "${NOOK}" -n data run add --all && "${NOOK}" -n data run commit -q -m crlf && "${NOOK}" -n data run push -q)

# Round trip on a second machine (also with hostile global config).
git -C "${ISO_PROJ}" push -q origin HEAD:refs/heads/main
ISO_B="${WORK}/proj-isolation-b"
git clone -q "${WORK}/origins/iso-demo.git" "${ISO_B}"
(cd "${ISO_B}" && "${NOOK}" add data origin >/dev/null)
CRLF_HASH_AFTER=$(shasum "${ISO_B}/data/windows.txt" | awk '{print $1}')
assert_eq "CRLF file round-trips byte-identically despite global autocrlf=true" \
    "${CRLF_HASH_BEFORE}" "${CRLF_HASH_AFTER}"

git config --global --unset core.autocrlf

# --- materialize: linking configured nooks into other worktrees -------------------

section "materialize: linked worktree gets its own symlink"
MZ=${WORK}/proj-materialize; make_project_repo "${MZ}" yes materialize-demo
(cd "${MZ}" && "${NOOK}" add beads origin --dir .beads)
printf 'x\n' > "${MZ}/.beads/f.txt"
(cd "${MZ}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
# linked worktree (sibling dir), new branch
WT=${WORK}/proj-materialize-wt
git -C "${MZ}" worktree add -q "${WT}" -b feat
assert_file_absent "linked worktree has no nook symlink before materialize" "${WT}/.beads"
MZ_OUT=$(cd "${WT}" && "${NOOK}" materialize)
assert_contains "materialize reports the nook" "${MZ_OUT}" "materialized beads"
assert_true "symlink created in linked worktree" test -L "${WT}/.beads"
MZ_LOG=$(cd "${WT}" && "${NOOK}" -n beads run log --oneline)
assert_contains "passthrough works from linked worktree after materialize" "${MZ_LOG}" "c1"
assert_file_exists "content visible through the symlink" "${WT}/.beads/f.txt"
assert_eq "linked worktree parent status clean" "" "$(git -C "${WT}" status --porcelain)"
# idempotent
(cd "${WT}" && "${NOOK}" materialize >/dev/null)
assert_true "second materialize is a no-op (still a symlink)" test -L "${WT}/.beads"

section "materialize: refuses when both real dir and checkout have content"
# Legacy-style real dir at the configured path in the MAIN tree, while the
# canonical checkout already has committed content -> ambiguous -> refuse.
rm "${MZ}/.beads"                       # remove the main-tree symlink from add
mkdir -p "${MZ}/.beads"; printf 'legacy\n' > "${MZ}/.beads/old.txt"
run_cmd_in "${MZ}" "${NOOK}" materialize
assert_exit_nonzero "materialize refuses when both real dir and checkout have content"
assert_contains "refusal explains the conflict" "${RUN_OUT}" "reconcile manually"

section "materialize: migrates a legacy real dir when the checkout is empty"
MZ2=${WORK}/proj-migrate-ok; make_project_repo "${MZ2}" yes migrate-ok
(cd "${MZ2}" && "${NOOK}" add docs origin --dir docsdir)   # no leading period on purpose
rm "${MZ2}/docsdir"                     # remove the symlink add created
CDIR=$(cd "${MZ2}" && git rev-parse --git-common-dir); CDIR="$(cd "${MZ2}/${CDIR}" && pwd)/nook/docs.nook/docsdir"
rm -rf "${CDIR:?}/"* 2>/dev/null || true  # ensure nested work-tree is empty
mkdir -p "${MZ2}/docsdir"; printf 'legacy\n' > "${MZ2}/docsdir/old.txt"
(cd "${MZ2}" && "${NOOK}" materialize >/dev/null)
assert_true "migrated real dir becomes a symlink" test -L "${MZ2}/docsdir"
assert_file_exists "legacy content moved into nested work-tree" "${CDIR}/old.txt"
assert_file_exists "legacy content reachable via symlink" "${MZ2}/docsdir/old.txt"

section "materialize: upgrades a legacy real-dir nook that has commit history"
# The realistic upgrade case every prior test missed: an OLD-layout nook is a
# real content dir with COMMITTED history and NO symlink. materialize must
# migrate it, not refuse -- the real dir IS the authoritative content, and the
# inner repo's HEAD already points at that same committed history.
UP=${WORK}/proj-upgrade; make_project_repo "${UP}" yes upgrade-demo
# Build the OLD layout by hand: inner bare repo with history, real content dir,
# config + exclude, NO symlink.
UP_GITDIR="${UP}/.git/nook/legacy.git"
mkdir -p "${UP}/.git/nook"
git init -q --bare "${UP_GITDIR}"
git --git-dir="${UP_GITDIR}" symbolic-ref HEAD refs/heads/main
git --git-dir="${UP_GITDIR}" config core.bare false
mkdir -p "${UP}/.legacy"; printf 'issue-1\n' > "${UP}/.legacy/data.txt"
git --git-dir="${UP_GITDIR}" --work-tree="${UP}/.legacy" add data.txt
git --git-dir="${UP_GITDIR}" --work-tree="${UP}/.legacy" -c user.email=t@t -c user.name=t commit -q -m "legacy history"
git -C "${UP}" config nook.legacy.dir .legacy
printf '/.legacy/\n' >> "$(abs_git_path "${UP}" info/exclude)"
# sanity: it's a real dir, not a symlink, with content + history
assert_true "precondition: legacy content dir is a real dir" test -d "${UP}/.legacy"
assert_true "precondition: not a symlink yet" bash -c '[ ! -L "'"${UP}"'/.legacy" ]'
# UPGRADE: materialize must migrate it, not refuse
UP_OUT=$(cd "${UP}" && "${NOOK}" materialize 2>&1); UP_RC=$?
assert_eq "materialize succeeds on a legacy nook with history (out: ${UP_OUT})" "0" "${UP_RC}"
assert_true "legacy dir became a symlink" test -L "${UP}/.legacy"
UP_CANON=$(cd "${UP}" && git rev-parse --git-common-dir); UP_CANON="$(cd "${UP}/${UP_CANON}" && pwd)/nook/legacy.nook/.legacy"
assert_file_exists "legacy content migrated into nested work-tree" "${UP_CANON}/data.txt"
assert_file_exists "legacy content reachable via symlink" "${UP}/.legacy/data.txt"
# passthrough works and history is intact
UP_LOG=$(cd "${UP}" && "${NOOK}" -n legacy run log --oneline)
assert_contains "committed history preserved after upgrade" "${UP_LOG}" "legacy history"
UP_STATUS=$(cd "${UP}" && "${NOOK}" -n legacy run status --porcelain)
assert_eq "clean working tree after upgrade migration" "" "${UP_STATUS}"
assert_eq "host status clean (symlink excluded)" "" "$(git -C "${UP}" status --porcelain -- .legacy)"

section "materialize: no nooks configured prints guidance"
MZE=${WORK}/proj-mz-empty; make_project_repo "${MZE}" no mzempty
MZE_OUT=$(cd "${MZE}" && "${NOOK}" materialize)
assert_contains "materialize with no nooks names the add command" "${MZE_OUT}" "git nook add"

section "add: a nook may be named 'materialize' (no reserved names)"
MZR=${WORK}/proj-mz-reserved; make_project_repo "${MZR}" yes mzr
run_cmd_in "${MZR}" "${NOOK}" add materialize origin
assert_exit_zero "creating a nook named 'materialize' succeeds"
assert_contains "add reports the new nook named 'materialize'" "${RUN_OUT}" "added nook 'materialize'"
run_cmd_in "${MZR}" "${NOOK}" -n materialize run status
assert_exit_zero "'-n materialize run status' reaches the nook named 'materialize'"

# --- list: unmaterialized marker ---------------------------------------------------

section "list: flags a nook not materialized in this worktree"
LM=${WORK}/proj-listmark; make_project_repo "${LM}" yes listmark
(cd "${LM}" && "${NOOK}" add data origin --dir .data >/dev/null)
LM_OK=$(cd "${LM}" && "${NOOK}" list)
if [[ "${LM_OK}" == *"not linked here"* ]]; then fail "materialized nook wrongly flagged"; else pass "materialized nook not flagged"; fi
# Remove the symlink to simulate an unmaterialized worktree; list must flag it.
rm "${LM}/.data"
LM_FLAG=$(cd "${LM}" && "${NOOK}" list)
assert_contains "unmaterialized nook is flagged" "${LM_FLAG}" "not linked here"

# --- bare/all-worktrees layout: no originating work tree ---------------------------

section "bare layout: add + materialize across peer worktrees (no main work tree)"
# Seed a repo, push it to its origin so the bare clone has a main branch.
BL_SEED=${WORK}/bl-seed; make_project_repo "${BL_SEED}" yes bare-demo
git -C "${BL_SEED}" push -q origin HEAD:refs/heads/main
BL_ORIGIN=${WORK}/origins/bare-demo.git
# Bare clone: its ONLY checkouts will be linked worktrees.
BL_BARE=${WORK}/bl-repo.git
git clone -q --bare "${BL_ORIGIN}" "${BL_BARE}"
WA=${WORK}/bl-wt-a; WB=${WORK}/bl-wt-b
git -C "${BL_BARE}" worktree add -q "${WA}" main
git -C "${BL_BARE}" worktree add -q -b other "${WB}" main
# Add a nook FROM a linked worktree (there is no main work tree).
(cd "${WA}" && "${NOOK}" add beads origin --dir .beads)
assert_true "nook symlink created in the adding worktree" test -L "${WA}/.beads"
printf 'y\n' > "${WA}/.beads/f.txt"
(cd "${WA}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
# Peer worktree: list flags it unmaterialized; materialize links it.
LIST_B=$(cd "${WB}" && "${NOOK}" list)
assert_contains "list flags unmaterialized nook in peer worktree" "${LIST_B}" "not linked here"
(cd "${WB}" && "${NOOK}" materialize >/dev/null)
assert_true "peer worktree now has the symlink" test -L "${WB}/.beads"
assert_file_exists "peer worktree sees the shared content" "${WB}/.beads/f.txt"
# Both symlinks resolve to the SAME canonical checkout under the bare common dir.
RA=$(cd "${WA}/.beads" && pwd -P); RB=$(cd "${WB}/.beads" && pwd -P)
assert_eq "both worktrees share one canonical checkout" "${RA}" "${RB}"
# After materialize, list no longer flags it.
LIST_B2=$(cd "${WB}" && "${NOOK}" list)
if [[ "${LIST_B2}" == *"not linked here"* ]]; then fail "list still flags a materialized nook"; else pass "list no longer flags materialized nook"; fi
# A commit from one peer is visible to the other (shared refs+objects).
printf 'z\n' > "${WA}/.beads/g.txt"
(cd "${WA}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c2)
LOG_B=$(cd "${WB}" && "${NOOK}" -n beads run log --oneline)
assert_contains "commit from peer A visible from peer B" "${LOG_B}" "c2"

section "nested: show reports the nested work-tree path (not the container)"
NEST=${WORK}/proj-nested
make_project_repo "${NEST}" yes nested-demo
(cd "${NEST}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
NEST_SHOW=$(cd "${NEST}" && "${NOOK}" -n beads show)
NEST_COMMON=$(cd "${NEST}" && git rev-parse --git-common-dir)
NEST_WT="$(cd "${NEST}/${NEST_COMMON}" && pwd -P)/nook/beads.nook/.beads"
assert_contains "show checkout: is the nested work-tree" "${NEST_SHOW}" "checkout: ${NEST_WT}/"

section "nested: passthrough commits tracked paths bare (no basename prefix)"
NESTPT=${WORK}/proj-nested-pt
make_project_repo "${NESTPT}" yes nested-pt-demo
(cd "${NESTPT}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
echo '{"id":"x1"}' > "${NESTPT}/.beads/issues.jsonl"
(cd "${NESTPT}" && "${NOOK}" -n beads run add --all >/dev/null)
(cd "${NESTPT}" && "${NOOK}" -n beads run commit -q -m "seed" >/dev/null)
NESTPT_TREE=$(cd "${NESTPT}" && "${NOOK}" -n beads run ls-tree --name-only -r HEAD)
assert_eq "tracked path is bare issues.jsonl (no .beads/ prefix)" \
    "issues.jsonl" "${NESTPT_TREE}"

section "nested: add materializes symlink to the nested work-tree"
NESTM=${WORK}/proj-nested-mat
make_project_repo "${NESTM}" yes nested-mat-demo
(cd "${NESTM}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
assert_true "content path is a symlink" test -L "${NESTM}/.beads"
NESTM_COMMON=$(cd "${NESTM}" && git rev-parse --git-common-dir)
NESTM_WT="$(cd "${NESTM}/${NESTM_COMMON}" && pwd)/nook/beads.nook/.beads"
assert_dir_exists "nested work-tree dir exists" "${NESTM_WT}"
assert_eq "symlink target basename is .beads" ".beads" "$(basename "$(cd "${NESTM}/.beads" && pwd -P)")"
assert_eq "symlink resolves to the nested work-tree" \
    "$(cd "${NESTM}/.beads" && pwd -P)" "$(cd "${NESTM_WT}" && pwd -P)"

section "nested: materialize migrates an old flat checkout to nested layout"
MIG=${WORK}/proj-migrate-nested
make_project_repo "${MIG}" yes migrate-nested-demo
(cd "${MIG}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
MIG_COMMON=$(cd "${MIG}" && git rev-parse --git-common-dir)
MIG_CONTAINER="$(cd "${MIG}/${MIG_COMMON}" && pwd)/nook/beads.nook"
MIG_WT="${MIG_CONTAINER}/.beads"
# Simulate the OLD flat layout: content directly in the container, symlink -> container.
rm "${MIG}/.beads"
( shopt -s dotglob nullglob; for e in "${MIG_WT}"/*; do mv "${e}" "${MIG_CONTAINER}/"; done )
rmdir "${MIG_WT}"
ln -s "${MIG_CONTAINER}" "${MIG}/.beads"
echo '{"id":"mig1"}' > "${MIG_CONTAINER}/issues.jsonl"
mkdir -p "${MIG_CONTAINER}/.br_history"; echo hist > "${MIG_CONTAINER}/.br_history/h1"
(cd "${MIG}" && "${NOOK}" materialize >/dev/null)
assert_true "post-migration content path is a symlink" test -L "${MIG}/.beads"
assert_eq "symlink now resolves to the nested work-tree" \
    "$(cd "${MIG}/.beads" && pwd -P)" "$(cd "${MIG_WT}" && pwd -P)"
assert_file_exists "flat file migrated into nested work-tree" "${MIG_WT}/issues.jsonl"
assert_file_exists "flat subdir file migrated too" "${MIG_WT}/.br_history/h1"
assert_file_absent "no leftover issues.jsonl at container top level" "${MIG_CONTAINER}/issues.jsonl"
(cd "${MIG}" && "${NOOK}" materialize >/dev/null)
assert_eq "second materialize keeps nested target" \
    "$(cd "${MIG}/.beads" && pwd -P)" "$(cd "${MIG_WT}" && pwd -P)"
assert_file_exists "content still present after idempotent re-run" "${MIG_WT}/issues.jsonl"

section "nested: migration handles a tracked entry named basename(dir)"
COL=${WORK}/proj-migrate-collision
make_project_repo "${COL}" yes migrate-collision-demo
(cd "${COL}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
COL_COMMON=$(cd "${COL}" && git rev-parse --git-common-dir)
COL_CONTAINER="$(cd "${COL}/${COL_COMMON}" && pwd)/nook/beads.nook"
COL_WT="${COL_CONTAINER}/.beads"
rm "${COL}/.beads"
( shopt -s dotglob nullglob; for e in "${COL_WT}"/*; do mv "${e}" "${COL_CONTAINER}/"; done )
rmdir "${COL_WT}"
ln -s "${COL_CONTAINER}" "${COL}/.beads"
# tracked content includes a dir literally named .beads (same as basename(dir))
mkdir -p "${COL_CONTAINER}/.beads"; echo inner > "${COL_CONTAINER}/.beads/nested.txt"
echo top > "${COL_CONTAINER}/top.txt"
(cd "${COL}" && "${NOOK}" materialize >/dev/null)
assert_true "collision: content path is a symlink" test -L "${COL}/.beads"
assert_file_exists "collision: top-level tracked file migrated" "${COL_WT}/top.txt"
assert_file_exists "collision: same-named tracked dir migrated intact" "${COL_WT}/.beads/nested.txt"

section "nested: interrupted migration re-run preserves staged data"
INTR=${WORK}/proj-migrate-interrupted
make_project_repo "${INTR}" yes migrate-intr-demo
(cd "${INTR}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
INTR_COMMON=$(cd "${INTR}" && git rev-parse --git-common-dir)
INTR_CONTAINER="$(cd "${INTR}/${INTR_COMMON}" && pwd)/nook/beads.nook"
INTR_WT="${INTR_CONTAINER}/.beads"
INTR_STAGE="${INTR_CONTAINER}/.git-nook-migrate"
# Simulate a migration interrupted BETWEEN the two move loops:
# stage populated with UNTRACKED content, work-tree dir created, symlink still -> container.
rm "${INTR}/.beads"
( shopt -s dotglob nullglob; for e in "${INTR_WT}"/*; do mv "${e}" "${INTR_CONTAINER}/"; done )
rmdir "${INTR_WT}"
ln -s "${INTR_CONTAINER}" "${INTR}/.beads"
mkdir -p "${INTR_STAGE}"
printf 'uncommitted-precious\n' > "${INTR_STAGE}/issues.jsonl"   # untracked, only in the stage
# Re-run materialize: it must NOT delete the staged file; it must land in the work-tree.
(cd "${INTR}" && "${NOOK}" materialize >/dev/null)
assert_file_exists "interrupted-migration: staged untracked file preserved into work-tree" "${INTR_WT}/issues.jsonl"
assert_eq "interrupted-migration: staged content intact" \
    "uncommitted-precious" "$(cat "${INTR_WT}/issues.jsonl")"
assert_true "interrupted-migration: symlink resolves to nested work-tree" \
    test "$(cd "${INTR}/.beads" && pwd -P)" = "$(cd "${INTR_WT}" && pwd -P)"

# --- shellcheck (optional, skipped gracefully if unavailable) --------------------

section "shellcheck (optional, skipped gracefully if unavailable)"

if command -v shellcheck >/dev/null 2>&1; then
    for f in "${REPO_UNDER_TEST}/bin/git-nook" "${REPO_UNDER_TEST}/install.sh" "${REPO_UNDER_TEST}/scripts/stamp-version.sh" "${REPO_UNDER_TEST}/scripts/check-tag-version.sh" "${TESTS_DIR}/run.sh" "${TESTS_DIR}/dispatch-grammar.sh"; do
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
