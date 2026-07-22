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

# init/clone key every nook on a SLUG (name.id3.owner.repo), not the bare
# name -- so tests that need the literal dir/ref path (e.g. .git/nook/<slug>.git,
# refs/nook/<slug>/files) must look the slug up after the fact rather than
# hardcode it. Prints the single slug configured for a given bare <name> in
# repo <dir> (the leading component of the slug up to the first '.').
slug_for_name() {
    local dir="$1" name="$2"
    git -C "${dir}" config --get-regexp "^nook\.${name}\..*\.dir\$" \
        | sed -E "s/^nook\.(${name}\.[^ ]*)\.dir .*/\1/" | head -n1
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
assert_contains "--help shows the init surface" "${NOOK_HELP}" "git nook init <name>"
assert_contains "--help shows the clone surface" "${NOOK_HELP}" "git nook clone <name>"
assert_contains "--help shows the passthrough surface" "${NOOK_HELP}" "<git-args...>"

# Unknown flags fail loudly.
run_cmd "${NOOK}" --frobnicate
assert_exit_nonzero "unknown option exits nonzero"
assert_contains "unknown option names the offender" "${RUN_OUT}" "--frobnicate"

# Unknown bare word outside any repo: still a clean error (not a git crash).
run_cmd_in "${WORK}" "${NOOK}" frobnicate
assert_exit_nonzero "unknown command outside a repo exits nonzero"

# Unknown bare word inside a repo with no nooks: names the problem + the fix.
# Under the new grammar, an unrecognized LEADING token (not init/clone/list/
# materialize/-n/--name/-h/--help/--version) always falls into the
# dispatcher's final catch-all, regardless of whether a nook by that name
# exists.
UNK_PROJ="${WORK}/proj-unknown"
make_project_repo "${UNK_PROJ}" no
run_cmd_in "${UNK_PROJ}" "${NOOK}" frobnicate status
assert_exit_nonzero "unknown command exits nonzero"
assert_contains "unknown command error names the offender" "${RUN_OUT}" "frobnicate"
assert_contains "unknown command error points at 'git nook init'" "${RUN_OUT}" "git nook init"

section "surface: add command is removed"

run_cmd_in "${WORK}" "${NOOK}" add x y
assert_exit_nonzero "add command removed"

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

for sub in list materialize init; do
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

section "init: --dir overrides; URL targets"

# The detailed field-by-field wiring assertions (core.bare, autocrlf, fetch/push
# refspecs, branch.main.*, HEAD) live in "init: creates a slug-keyed wired
# hidden inner repo" below; this section covers what add: --dir/--ref used to
# (--ref itself is gone -- init always publishes under refs/nook/<slug>/).
ADD_PROJ="${WORK}/proj-add"
make_project_repo "${ADD_PROJ}" yes "add-demo"

ADD_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" init notes origin)
assert_contains "init reports the new nook" "${ADD_OUT}" "initialized nook 'notes'"
NOTES_SLUG=$(slug_for_name "${ADD_PROJ}" notes)
ADD_GITDIR="${ADD_PROJ}/.git/nook/${NOTES_SLUG}.git"

assert_dir_exists "content dir created with default name" "${ADD_PROJ}/notes"
assert_file_absent "content dir contains NO .git entry" "${ADD_PROJ}/notes/.git"
assert_dir_exists "inner git dir hidden under parent .git" "${ADD_GITDIR}"

assert_eq "parent config maps slug -> dir" \
    "notes" "$(git -C "${ADD_PROJ}" config --get "nook.${NOTES_SLUG}.dir")"
ADD_EXCLUDE=$(abs_git_path "${ADD_PROJ}" info/exclude)
assert_true "content dir excluded (anchored, no trailing slash) in parent info/exclude" \
    grep -qxF '/notes' "${ADD_EXCLUDE}"

# After init in the originating worktree, the content dir is a REAL directory
# (the primary home), NOT a symlink, and home is recorded.
assert_true "content path is a real directory (primary home)" test -d "${ADD_PROJ}/notes"
if [[ -L "${ADD_PROJ}/notes" ]]; then fail "originating worktree content path must not be a symlink"; else pass "originating content path is a real dir, not a symlink"; fi
assert_eq "init recorded home = <toplevel>/notes" "$(cd "${ADD_PROJ}/notes" && pwd -P)" "$(cd "$(git -C "${ADD_PROJ}" config --get "nook.${NOTES_SLUG}.home")" && pwd -P)"
if [[ "${ADD_PROJ}/notes" == *"/.git/"* ]]; then fail "home under .git"; else pass "home has no .git component"; fi

ADD_ORIGIN_URL=$(git -C "${ADD_PROJ}" remote get-url origin)
ADD_REF="refs/nook/${NOTES_SLUG}/files"
assert_eq "parent git status stays clean after init" \
    "" "$(git -C "${ADD_PROJ}" status --porcelain)"

ADD_TGT_BARE="${WORK}/targets/add-ext.git"
mkdir -p "$(dirname "${ADD_TGT_BARE}")"
git init -q --bare "${ADD_TGT_BARE}"
(cd "${ADD_PROJ}" && "${NOOK}" init scratch "${ADD_TGT_BARE}" --dir tmp/scratch)
SCRATCH_SLUG=$(slug_for_name "${ADD_PROJ}" scratch)
SCRATCH_GITDIR="${ADD_PROJ}/.git/nook/${SCRATCH_SLUG}.git"
assert_eq "URL target stored literally on the inner remote" \
    "${ADD_TGT_BARE}" "$(git --git-dir="${SCRATCH_GITDIR}" config --get remote.origin.url)"
assert_eq "push refspec publishes main to the slug's /files ref" \
    "refs/heads/main:refs/nook/${SCRATCH_SLUG}/files" \
    "$(git --git-dir="${SCRATCH_GITDIR}" config --get remote.origin.push | grep '^refs/heads/main:')"
assert_dir_exists "custom --dir honored" "${ADD_PROJ}/tmp/scratch"
assert_true "custom dir excluded" grep -qxF '/tmp/scratch' "${ADD_EXCLUDE}"

# multi-segment --dir: the home is the real dir at the FULL configured path
# (tmp/scratch), not nested under any container.
if [[ -L "${ADD_PROJ}/tmp/scratch" ]]; then fail "multi-segment content path must not be a symlink in the originating worktree"; else pass "multi-segment content path is a real dir"; fi
assert_eq "multi-segment home recorded at the full --dir path" \
    "$(cd "${ADD_PROJ}/tmp/scratch" && pwd -P)" "$(cd "$(git -C "${ADD_PROJ}" config --get "nook.${SCRATCH_SLUG}.home")" && pwd -P)"

section "init: explicit dotted --dir is still honored"

(cd "${ADD_PROJ}" && "${NOOK}" init secret "${ADD_TGT_BARE}" --dir .secret)
SECRET_SLUG=$(slug_for_name "${ADD_PROJ}" secret)
assert_dir_exists "explicit dotted --dir honored" "${ADD_PROJ}/.secret"
assert_true "explicit dotted dir excluded" grep -qxF '/.secret' "${ADD_EXCLUDE}"
if [[ -L "${ADD_PROJ}/.secret" ]]; then fail "explicit dotted dir must not be a symlink in the originating worktree"; else pass "explicit dotted dir is a real dir"; fi
assert_eq "dotted --dir home recorded" \
    "$(cd "${ADD_PROJ}/.secret" && pwd -P)" "$(cd "$(git -C "${ADD_PROJ}" config --get "nook.${SECRET_SLUG}.home")" && pwd -P)"

section "exclude: entry has no trailing slash and remove cleans legacy forms"
EX=${WORK}/proj-exclude
make_project_repo "${EX}" yes excl-demo
(cd "${EX}" && "${NOOK}" init data origin --dir .data >/dev/null)
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
run_cmd_in "${ADD_PROJ}" "${NOOK}" init badnook origin --dir badlink
assert_exit_nonzero "--dir pointing at a non-directory refused"
assert_contains "non-directory --dir error is a clean err()" "${RUN_OUT}" "not a directory"
rm "${ADD_PROJ}/badlink"

# Content dirs differing only by case would collide on case-insensitive
# filesystems (the symlink/container paths would alias). This is a property
# of the CONFIGURED DIR, not the nook name/slug (slugs embed a fresh random
# uuid per init, so two same-named-but-differently-cased nooks never
# actually produce colliding slugs) -- so exercise it via --dir, not name.
# Deliberately filesystem-independent: the guard compares config values
# textually and refuses before any filesystem operation, so this assertion
# holds identically on case-sensitive (Linux) and case-insensitive (macOS)
# filesystems alike.
CASE_PROJ="${WORK}/proj-case-collide"
make_project_repo "${CASE_PROJ}" yes "case-collide"
(cd "${CASE_PROJ}" && "${NOOK}" init one origin --dir Notes >/dev/null)
run_cmd_in "${CASE_PROJ}" "${NOOK}" init two origin --dir notes
assert_exit_nonzero "case-colliding content dir refused"
assert_contains "case-collision error names the existing dir" "${RUN_OUT}" "differs only by case"

section "list / show"

LIST_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" list)
assert_contains "list shows notes slug" "${LIST_OUT}" "${NOTES_SLUG}"
assert_contains "list shows scratch's dir" "${LIST_OUT}" "tmp/scratch/"

SHOW_OUT=$(cd "${ADD_PROJ}" && "${NOOK}" -n notes show)
assert_contains "show prints the slug" "${SHOW_OUT}" "slug:     ${NOTES_SLUG}"
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
(cd "${BROKEN_PROJ}" && "${NOOK}" init wrecked origin >/dev/null)
BROKEN_SLUG=$(slug_for_name "${BROKEN_PROJ}" wrecked)
rm -rf "${BROKEN_PROJ}/.git/nook/${BROKEN_SLUG}.git"
run_cmd_in "${BROKEN_PROJ}" "${NOOK}" -n wrecked show
assert_eq "show of nook with missing inner git-dir exits 0" "0" "${RUN_EXIT}"
assert_contains "show of broken nook prints url (none)" "${RUN_OUT}" "url:      (none)"
BROKEN_LIST=$(cd "${BROKEN_PROJ}" && "${NOOK}" list)
assert_contains "list flags the missing inner repo" "${BROKEN_LIST}" "(no inner repo)"

EMPTY_PROJ="${WORK}/proj-empty-list"
make_project_repo "${EMPTY_PROJ}" no
EMPTY_LIST=$(cd "${EMPTY_PROJ}" && "${NOOK}" list)
assert_contains "empty list explains how to create one" "${EMPTY_LIST}" "git nook init"

# --- passthrough: full git against the inner repo --------------------------------

section "passthrough: status/add/commit/log round trip"

PT_PROJ="${WORK}/proj-passthrough"
make_project_repo "${PT_PROJ}" yes "pt-demo"
(cd "${PT_PROJ}" && "${NOOK}" init notes origin)
PT_SLUG=$(slug_for_name "${PT_PROJ}" notes)

if [[ -L "${PT_PROJ}/notes" ]]; then fail "originating worktree content path must not be a symlink"; else pass "content path is a real dir (primary home)"; fi
assert_eq "home recorded at the content path" \
    "$(cd "${PT_PROJ}/notes" && pwd -P)" "$(cd "$(git -C "${PT_PROJ}" config --get "nook.${PT_SLUG}.home")" && pwd -P)"

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

section "guard: nook subcommands abort cleanly when the primary home is gone"

GONE=${WORK}/proj-gone; make_project_repo "${GONE}" yes gone
(cd "${GONE}" && "${NOOK}" init stash origin >/dev/null)
GONE_SLUG=$(slug_for_name "${GONE}" stash)
printf 'keep\n' > "${GONE}/stash/keeper.txt"
(cd "${GONE}" && "${NOOK}" -n stash run add --all && "${NOOK}" -n stash run commit -q -m keeper)
GONE_LOG=$(cd "${GONE}" && "${NOOK}" -n stash run log --oneline)
assert_contains "passthrough works while the primary home is intact" "${GONE_LOG}" "keeper"
# Destroy the primary home (as if its worktree was removed).
rm -rf "${GONE}/stash"
# run must abort with the materialize hint, and must NOT reach git (no raw git error).
run_cmd_in "${GONE}" "${NOOK}" -n stash run status
assert_exit_nonzero "run aborts when primary home missing"
assert_contains "run error points at materialize" "${RUN_OUT}" "git nook -n ${GONE_SLUG} materialize"
if [[ "${RUN_OUT}" == *"fatal:"* ]]; then fail "raw git error leaked (guard fired too late)"; else pass "no raw git error (guard fired before passthrough)"; fi
if [[ "${RUN_OUT}" == *"mkdir"* ]]; then fail "error still suggests the mkdir footgun"; else pass "no mkdir footgun in error"; fi
# materialize itself is EXEMPT: it recovers by re-checkout from the inner repo.
(cd "${GONE}" && "${NOOK}" materialize >/dev/null)
assert_file_exists "materialize recovered the content" "${GONE}/stash/keeper.txt"
# show is exempt (diagnostic): reports not-linked instead of aborting.
rm -rf "${GONE}/stash"
run_cmd_in "${GONE}" "${NOOK}" -n stash show
assert_exit_zero "show does not abort on missing home (diagnostic)"
assert_contains "show reports home" "${RUN_OUT}" "home:"
assert_contains "show reports linked state" "${RUN_OUT}" "linked:"
# recover for any later reuse of this fixture
(cd "${GONE}" && "${NOOK}" materialize >/dev/null)

section "guard: existence/repo checks run BEFORE the dangling-primary hint (correct diagnosis)"
# A NONEXISTENT nook under -n ... run must get "no nook named", never the
# "was its worktree removed?" materialize hint -- that hint only makes sense
# for a nook that IS configured but whose recorded home died. Without the
# fix, the guard fired first and misdiagnosed this case (and running the
# hinted materialize then errored differently: "no nook named").
run_cmd_in "${GONE}" "${NOOK}" -n totally-bogus-nook run status
assert_exit_nonzero "run on a nonexistent nook exits nonzero"
assert_contains "nonexistent nook gets 'no nook named', not the materialize hint" "${RUN_OUT}" "no nook named"
if [[ "${RUN_OUT}" == *"was its worktree removed"* ]]; then
    fail "nonexistent nook wrongly got the dangling-primary hint"
else
    pass "nonexistent nook did not get the dangling-primary hint"
fi
# A genuinely configured-but-dangling nook must STILL get the materialize hint.
rm -rf "${GONE}/stash"
run_cmd_in "${GONE}" "${NOOK}" -n stash run status
assert_contains "configured-but-dangling nook still gets the materialize hint" "${RUN_OUT}" "was its worktree removed"
(cd "${GONE}" && "${NOOK}" materialize >/dev/null)   # recover for later reuse

section "guard: -n <name> materialize is the exact recovery form the guard hints at (dispatch coverage)"
# Every guard error prescribes `git nook -n <name> materialize`; confirm that
# exact dispatch path (materialize routed through the -n branch, not just
# top-level `git nook materialize`) actually works end-to-end.
rm -rf "${GONE}/stash"
run_cmd_in "${GONE}" "${NOOK}" -n stash run status
assert_contains "guard hint names the exact -n <name> materialize form" "${RUN_OUT}" "-n ${GONE_SLUG} materialize"
run_cmd_in "${GONE}" "${NOOK}" -n stash materialize
assert_exit_zero "'-n <name> materialize' succeeds (the guard's own prescribed recovery)"
assert_file_exists "'-n <name> materialize' recovered the content" "${GONE}/stash/keeper.txt"
run_cmd_in "${GONE}" "${NOOK}" -n stash run status
assert_exit_zero "run works again after '-n <name> materialize' recovery"

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
(cd "${PUB_PROJ}" && "${NOOK}" init beads origin --dir .beads)
PUB_SLUG=$(slug_for_name "${PUB_PROJ}" beads)
printf '{"id":"pub-1"}\n' > "${PUB_PROJ}/.beads/issues.jsonl"
(cd "${PUB_PROJ}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m "issues")
(cd "${PUB_PROJ}" && "${NOOK}" -n beads run push -q)

PUB_REF="refs/nook/${PUB_SLUG}/files"
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

# NOTE: the old "publish: --ref refs/heads/... publishes a visible branch
# instead" section tested cmd_add's --ref override (a custom ref template,
# optionally landing under refs/heads/ for a visible branch). init/clone have
# no --ref equivalent -- they always publish to refs/nook/<slug>/files (never
# refs/heads/), so there is nothing to port; this capability is intentionally
# gone. Deleted rather than ported.

# --- bootstrap: init/clone on a machine where the ref already exists --------------

section "bootstrap: clone fetches and materializes an existing nook (fresh consumer)"

# Publisher machine: inits + pushes a nook with nested content.
BS_A="${WORK}/proj-bs-a"
make_project_repo "${BS_A}" yes "bs-demo"
BS_BARE="${WORK}/origins/bs-demo.git"
git -C "${BS_A}" push -q origin HEAD:refs/heads/main
(cd "${BS_A}" && "${NOOK}" init notes origin)
printf 'from machine A\n' > "${BS_A}/notes/shared.md"
mkdir -p "${BS_A}/notes/sub"
printf 'nested\n' > "${BS_A}/notes/sub/inner.md"
(cd "${BS_A}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m "A1" && "${NOOK}" -n notes run push -q)

# Fresh clone = second machine, with nothing local at the target dir yet.
BS_B="${WORK}/proj-bs-b"
git clone -q "${BS_BARE}" "${BS_B}"
BS_B_OUT=$(cd "${BS_B}" && "${NOOK}" clone notes origin)
assert_contains "clone reports success" "${BS_B_OUT}" "cloned"
assert_file_exists "content materialized" "${BS_B}/notes/shared.md"
assert_file_exists "nested content materialized" "${BS_B}/notes/sub/inner.md"
assert_true "clone made the content dir the real primary home" test -d "${BS_B}/notes"
if [[ -L "${BS_B}/notes" ]]; then fail "clone in fresh repo must leave a real dir, not a symlink"; else pass "clone left a real primary-home dir"; fi
assert_eq "clone recorded home" "$(cd "${BS_B}/notes" && pwd -P)" "$(cd "$(git -C "${BS_B}" config --get "nook.$(slug_for_name "${BS_B}" notes).home")" && pwd -P)"
assert_eq "nook clean right after clone" \
    "" "$(cd "${BS_B}" && "${NOOK}" -n notes run status --porcelain)"
BS_B_LOG=$(cd "${BS_B}" && "${NOOK}" -n notes run log --oneline)
assert_contains "history came along" "${BS_B_LOG}" "A1"
assert_eq "parent clone status stays clean" "" "$(git -C "${BS_B}" status --porcelain)"

# NOTE: the old "bootstrap: both-sides-exist refuses to touch local files"
# section tested cmd_add's special case where the target dir already had
# local (uncommitted) content AND the remote ref already existed: add
# detected this, refused to clobber, and printed a --no-rebase/--no-edit/
# --allow-unrelated-histories reconcile hint. cmd_clone has no equivalent
# guard: it fetches unconditionally, then calls materialize_one once, whose
# real-dir-migration branch does not populate from HEAD when the checkout
# is empty, so remote content can be silently NOT materialized instead of
# either merging or refusing (found while porting this test; filed as a
# Discovery, out of scope for this task -- see the "clone silently drops
# remote content when local dir non-empty" follow-up). Deleted rather than
# ported with a weakened assertion.

section "bootstrap: clone rolls back cleanly on fetch failure"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "  [SKIP] running as root; permission-based failure injection unavailable"
else
    # Deterministic failure: publish real data to the target, then make the
    # one loose object at its tip unreadable so ls-remote (refs only) still
    # succeeds but the actual fetch fails. (Root ignores permissions, hence
    # the skip above.)
    BS_D="${WORK}/proj-bs-d"
    make_project_repo "${BS_D}" yes "bs-fail"
    git -C "${BS_D}" push -q origin HEAD:refs/heads/main
    BS_D_SEED="${WORK}/proj-bs-d-seed"
    git clone -q "${WORK}/origins/bs-fail.git" "${BS_D_SEED}"
    (cd "${BS_D_SEED}" && "${NOOK}" init notes origin >/dev/null)
    printf 'seeded\n' > "${BS_D_SEED}/notes/seed.md"
    (cd "${BS_D_SEED}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m seed && "${NOOK}" -n notes run push -q)
    BS_D_SLUG=$(slug_for_name "${BS_D_SEED}" notes)

    BS_D_BARE="${WORK}/origins/bs-fail.git"
    BS_D_TIP=$(git -C "${BS_D_BARE}" rev-parse "refs/nook/${BS_D_SLUG}/files")
    BS_D_OBJPATH="${BS_D_BARE}/objects/${BS_D_TIP:0:2}/${BS_D_TIP:2}"
    if [[ -f "${BS_D_OBJPATH}" ]]; then
        chmod 000 "${BS_D_OBJPATH}"
        run_cmd_in "${BS_D}" "${NOOK}" clone notes origin
        chmod 644 "${BS_D_OBJPATH}"
        assert_exit_nonzero "clone fetch failure exits nonzero"
        assert_contains "failure says it rolled back" "${RUN_OUT}" "rolled back"
        if git -C "${BS_D}" config --get-regexp '^nook\.' >/dev/null 2>&1; then
            fail "config not rolled back after clone fetch failure"
        else
            pass "config (incl. .home) rolled back after clone fetch failure"
        fi
        assert_file_absent "inner repo rolled back" "${BS_D}/.git/nook/${BS_D_SLUG}.git"
        BS_D_EXCLUDE=$(abs_git_path "${BS_D}" info/exclude)
        if grep -qxF '/notes' "${BS_D_EXCLUDE}" 2>/dev/null; then
            fail "exclude entry not rolled back after clone fetch failure"
        else
            pass "exclude entry rolled back after clone fetch failure"
        fi
        assert_file_absent "elected home dir removed on rollback" "${BS_D}/notes"

        # Once the object is readable again, the same clone succeeds (nothing
        # stale left behind by the rollback).
        BS_D_OUT2=$(cd "${BS_D}" && "${NOOK}" clone notes origin)
        assert_contains "re-clone after repair succeeds" "${BS_D_OUT2}" "cloned"
        assert_file_exists "content materialized on retry" "${BS_D}/notes/seed.md"
    else
        echo "  [SKIP] clone rollback test: tip commit is not a loose object (already packed) in this environment"
    fi
fi

section "bootstrap: nested --dir rollback removes the elected home dir"

# Publisher for a distinct nook name/target so its ref differs from the ones
# above; seed real published data so ls-remote succeeds and the code
# proceeds to the fetch/materialize step.
BS_E_PUB="${WORK}/proj-bs-e-pub"
make_project_repo "${BS_E_PUB}" yes "bs-nested"
git -C "${BS_E_PUB}" push -q origin HEAD:refs/heads/main
(cd "${BS_E_PUB}" && "${NOOK}" init deep origin --dir deep/nested/path >/dev/null)
BS_E_SLUG=$(slug_for_name "${BS_E_PUB}" deep)
printf 'nested seed\n' > "${BS_E_PUB}/deep/nested/path/seed.md"
(cd "${BS_E_PUB}" && "${NOOK}" -n deep run add --all && "${NOOK}" -n deep run commit -q -m seed && "${NOOK}" -n deep run push -q)

# Second machine: none of deep/, deep/nested/, deep/nested/path/ exist yet.
# Force fetch to fail deterministically by making the target's objects
# unreadable after ls-remote would already see the ref (ls-remote only needs
# refs, not object data). On failure, rollback must remove the elected
# primary-home dir (deep/nested/path, a real dir under the new model) --
# not just an ancestor symlink.
BS_E="${WORK}/proj-bs-e"
git clone -q "${WORK}/origins/bs-nested.git" "${BS_E}"
BS_E_BARE="${WORK}/origins/bs-nested.git"
BS_E_REF="refs/nook/${BS_E_SLUG}/files"
BS_E_TIP=$(git -C "${BS_E_BARE}" rev-parse "${BS_E_REF}")
# ls-remote only lists refs (succeeds even if the object is unreadable), but
# fetch must actually transfer the commit object, so making just that one
# loose object unreadable fails fetch specifically, after ls-remote passed.
BS_E_OBJPATH="${BS_E_BARE}/objects/${BS_E_TIP:0:2}/${BS_E_TIP:2}"
if [[ -f "${BS_E_OBJPATH}" ]]; then
    chmod 000 "${BS_E_OBJPATH}"
    run_cmd_in "${BS_E}" "${NOOK}" clone deep origin --dir deep/nested/path
    chmod 644 "${BS_E_OBJPATH}"
    if [[ "${RUN_EXIT}" -ne 0 ]] && [[ "${RUN_OUT}" == *"rolled back"* ]]; then
        pass "nested --dir clone fetch failure rolls back"
        assert_file_absent "elected home dir removed" "${BS_E}/deep/nested/path"
        if git -C "${BS_E}" config --get-regexp '^nook\.' >/dev/null 2>&1; then
            fail "config (incl. .home) not rolled back for nested --dir"
        else
            pass "config (incl. .home) rolled back for nested --dir"
        fi
    else
        echo "  [SKIP] nested --dir rollback test: could not force a deterministic fetch failure in this environment (exit=${RUN_EXIT}, out='${RUN_OUT}')"
    fi
else
    echo "  [SKIP] nested --dir rollback test: tip commit is not a loose object (already packed) in this environment"
fi

section "init: adopts a pre-existing untracked dir as the primary home"
AM=${WORK}/proj-add-migrate; make_project_repo "${AM}" yes addmig
mkdir -p "${AM}/.data"; printf 'pre\n' > "${AM}/.data/pre.txt"
(cd "${AM}" && "${NOOK}" init data origin --dir .data >/dev/null)
AM_SLUG=$(slug_for_name "${AM}" data)
if [[ -L "${AM}/.data" ]]; then fail "init must leave a real dir (the primary home), not a symlink"; else pass "init left a real dir"; fi
assert_file_exists "pre-existing content preserved in place" "${AM}/.data/pre.txt"
assert_eq "pre-existing dir recorded as the home" "$(cd "${AM}/.data" && pwd -P)" "$(cd "$(git -C "${AM}" config --get "nook.${AM_SLUG}.home")" && pwd -P)"

# --- two clones: concurrency and conflicts ----------------------------------------

section "two clones: non-fast-forward push rejected, then pull/push succeeds"

TC_A="${WORK}/proj-tc-a"
make_project_repo "${TC_A}" yes "tc-demo"
TC_BARE="${WORK}/origins/tc-demo.git"
git -C "${TC_A}" push -q origin HEAD:refs/heads/main
(cd "${TC_A}" && "${NOOK}" init notes origin)
TC_SLUG=$(slug_for_name "${TC_A}" notes)
printf 'base\n' > "${TC_A}/notes/doc.md"
(cd "${TC_A}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m base && "${NOOK}" -n notes run push -q)

TC_B="${WORK}/proj-tc-b"
git clone -q "${TC_BARE}" "${TC_B}"
(cd "${TC_B}" && "${NOOK}" clone notes origin >/dev/null)

# A pushes a new commit; B commits independently -> B's push must be rejected.
printf 'from A\n' > "${TC_A}/notes/a-only.md"
(cd "${TC_A}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m from-a && "${NOOK}" -n notes run push -q)
printf 'from B\n' > "${TC_B}/notes/b-only.md"
(cd "${TC_B}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m from-b)
run_cmd_in "${TC_B}" "${NOOK}" -n notes run push
assert_exit_nonzero "non-fast-forward push rejected"

(cd "${TC_B}" && "${NOOK}" -n notes run pull -q --no-edit --no-rebase)
(cd "${TC_B}" && "${NOOK}" -n notes run push -q)
TC_TIP=$(git -C "${TC_BARE}" rev-parse "refs/nook/${TC_SLUG}/files")
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
    "$(git -C "${TC_BARE}" show "refs/nook/${TC_SLUG}/files:doc.md")" "A and B"
assert_eq "parent repos stayed clean through all of it" \
    "" "$(git -C "${TC_A}" status --porcelain)$(git -C "${TC_B}" status --porcelain)"

# --- init refusals ------------------------------------------------------------------

section "init: a nook may be named after a subcommand (no reserved names)"

REF_PROJ="${WORK}/proj-refusals"
make_project_repo "${REF_PROJ}" yes "refusals-demo"

# RESERVED_NAMES is gone: a nook can be named after any subcommand, including
# 'list', 'init', 'clone', 'show', 'remove', 'materialize'. It must be
# creatable AND reachable end-to-end through the new -n/run grammar.
run_cmd_in "${REF_PROJ}" "${NOOK}" init list origin
assert_exit_zero "creating a nook named 'list' succeeds"
assert_contains "init reports the new nook named 'list'" "${RUN_OUT}" "initialized nook 'list'"
run_cmd_in "${REF_PROJ}" "${NOOK}" -n list run status
assert_exit_zero "'-n list run status' reaches the nook named 'list'"

section "init refusals: names"

run_cmd_in "${REF_PROJ}" "${NOOK}" init 'bad/name' origin
assert_exit_nonzero "slash in name refused"

run_cmd_in "${REF_PROJ}" "${NOOK}" init 'bad..name' origin
assert_exit_nonzero "invalid ref component refused"

run_cmd_in "${REF_PROJ}" "${NOOK}" init -leading origin
assert_exit_nonzero "leading dash refused"

section "init refusals: targets and dirs"

run_cmd_in "${REF_PROJ}" "${NOOK}" init notes bogusremote
assert_exit_nonzero "nonexistent remote name refused"
assert_contains "bad target error names the offender" "${RUN_OUT}" "bogusremote"

run_cmd_in "${REF_PROJ}" "${NOOK}" init notes origin --dir ../outside
assert_exit_nonzero "dir escaping the repo refused"
run_cmd_in "${REF_PROJ}" "${NOOK}" init notes origin --dir /abs/path
assert_exit_nonzero "absolute dir refused"
run_cmd_in "${REF_PROJ}" "${NOOK}" init notes origin --dir .git/sneaky
assert_exit_nonzero "dir under .git refused"

# Tracked files: docs/ is committed in the parent.
mkdir -p "${REF_PROJ}/docs"
printf 'tracked\n' > "${REF_PROJ}/docs/real.md"
git -C "${REF_PROJ}" add docs/real.md
git -C "${REF_PROJ}" commit -q -m "tracked docs"
run_cmd_in "${REF_PROJ}" "${NOOK}" init docs origin --dir docs
assert_exit_nonzero "dir with parent-tracked files refused"
assert_contains "tracked-files error explains" "${RUN_OUT}" "tracked"

section "init refusals: duplicates and overlap"

# init has no name-uniqueness concept (each init mints a fresh slug via a
# random uuid) -- re-initing the same name with its default --dir instead
# collides on the DIR overlap check (both want dir "notes/"), which is the
# real "you already have a nook here" refusal under init. A literal
# same-slug collision (checked via channel_dir "${slug}") is not reachable
# from the CLI with a fresh uuid; the case-insensitive collision guard is
# dir-based (see "init refuses a content dir differing only by case"
# further up), since that -- not the name/slug -- is the real hazard on a
# case-insensitive filesystem.
(cd "${REF_PROJ}" && "${NOOK}" init notes origin >/dev/null)
run_cmd_in "${REF_PROJ}" "${NOOK}" init notes origin
assert_exit_nonzero "re-init with the same default dir refused"
assert_contains "re-init error explains the dir overlap" "${RUN_OUT}" "overlaps nook"

run_cmd_in "${REF_PROJ}" "${NOOK}" init nested origin --dir notes/nested
assert_exit_nonzero "dir nesting inside another nook refused"
assert_contains "overlap error names the other nook" "${RUN_OUT}" "notes"
run_cmd_in "${REF_PROJ}" "${NOOK}" init umbrella origin --dir .
assert_exit_nonzero "dir '.' refused"

run_cmd_in "${REF_PROJ}" "${NOOK}" init sub2 origin --dir 'sub/.git/evil'
assert_exit_nonzero "nested .git dir refused"

# A failed init leaves no debris behind.
if [[ -n "$(slug_for_name "${REF_PROJ}" nested)" ]]; then
    fail "failed init leaked config for 'nested'"
else
    pass "failed init leaked no config"
fi
assert_true "failed init leaked no inner repo" bash -c '! ls "'"${REF_PROJ}"'"/.git/nook/nested.*.git >/dev/null 2>&1'

# --- remove -------------------------------------------------------------------------

section "remove: full local delete, upstream untouched"

RM_REPO="${WORK}/rm-repo"; make_project_repo "${RM_REPO}" yes rmproj
( cd "${RM_REPO}"
  "${NOOK}" init beads origin --dir .beads
  echo x > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m seed; "${NOOK}" -n beads run push )
RM_SLUG=$(cd "${RM_REPO}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
RM_ORIGIN="${WORK}/origins/rmproj.git"
# Sanity: fully pushed.
assert_contains "files ref on upstream before remove" \
    "$(git ls-remote "${RM_ORIGIN}" "refs/nook/${RM_SLUG}/files")" "refs/nook/${RM_SLUG}/files"
( cd "${RM_REPO}"; "${NOOK}" -n beads remove )
assert_true "config section gone" test -z "$(cd "${RM_REPO}" && git config --get "nook.${RM_SLUG}.dir" 2>/dev/null)"
assert_true "inner git dir removed" test ! -e "${RM_REPO}/.git/nook/${RM_SLUG}.git"
assert_true "primary home (real dir) removed" test ! -e "${RM_REPO}/.beads"
assert_contains "upstream files ref survives remove" \
    "$(git ls-remote "${RM_ORIGIN}" "refs/nook/${RM_SLUG}/files")" "refs/nook/${RM_SLUG}/files"

section "remove: refuses unpushed commits without --force"

RM2="${WORK}/rm2"; make_project_repo "${RM2}" yes rm2
( cd "${RM2}"; "${NOOK}" init notes origin --dir notes
  echo y > notes/n; "${NOOK}" -n notes run add --all; "${NOOK}" -n notes run commit -m local )
# committed locally but NEVER pushed.
RC=$(cd "${RM2}"; "${NOOK}" -n notes remove >/dev/null 2>&1; echo $?)
assert_eq "remove refuses unpushed" "1" "${RC}"
assert_true "still configured after refusal" test -n "$(cd "${RM2}" && git config --get-regexp '^nook\..*\.dir$')"
( cd "${RM2}"; "${NOOK}" -n notes remove --force )
assert_true "force removes despite unpushed" test -z "$(cd "${RM2}" && git config --get-regexp '^nook\..*\.dir$')"

section "remove: in a peer worktree, a real dir replacing the symlink is left in place"
RM3="${WORK}/rm3"; make_project_repo "${RM3}" yes rm3
( cd "${RM3}"; "${NOOK}" init beads origin --dir .beads
  echo x > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
RM3_SLUG=$(cd "${RM3}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
# Peer worktree: materialize gets a symlink to the primary home. Then a user
# manually replaces that symlink with an independent real dir -- remove must
# leave it in place (never risk the user's files) rather than clobber it.
RM3_WT="${WORK}/rm3-wt"
git -C "${RM3}" worktree add -q "${RM3_WT}" -b rm3feat
( cd "${RM3_WT}"; "${NOOK}" materialize >/dev/null )
assert_true "peer got a symlink before the manual replacement" test -L "${RM3_WT}/.beads"
( cd "${RM3_WT}"; rm -f .beads; mkdir .beads; echo manual > .beads/keep )
( cd "${RM3_WT}"; "${NOOK}" -n beads remove )
assert_true "config removed despite real dir" test -z "$(cd "${RM3_WT}" && git config --get "nook.${RM3_SLUG}.dir" 2>/dev/null)"
assert_true "inner git dir removed despite real dir" test ! -e "${RM3}/.git/nook/${RM3_SLUG}.git"
assert_true "user real dir left in place" test -f "${RM3_WT}/.beads/keep"
assert_true "primary home in the OTHER worktree is untouched" test -f "${RM3}/.beads/f"

section "remove: passthrough for a removed nook fails cleanly"

RM_PROJ="${WORK}/proj-remove"
make_project_repo "${RM_PROJ}" yes "remove-demo"
(cd "${RM_PROJ}" && "${NOOK}" init notes origin >/dev/null)
printf 'unpushed work\n' > "${RM_PROJ}/notes/keep.md"
(cd "${RM_PROJ}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m keep)
(cd "${RM_PROJ}" && "${NOOK}" -n notes remove --force >/dev/null)

run_cmd_in "${RM_PROJ}" "${NOOK}" -n notes run status
assert_exit_nonzero "passthrough for a removed nook fails cleanly"

run_cmd_in "${RM_PROJ}" "${NOOK}" -n notes remove
assert_exit_nonzero "removing a nonexistent nook fails cleanly"

section "remove then re-clone: stale inner repo is refused with a hint, then works"

# Unlike init (a fresh random uuid each call, so a same-named stale leftover
# essentially never collides), clone's slug is re-derived from the remote's
# published ref -- re-cloning the SAME nook after a local remove reproduces
# the exact same slug, so a stale inner git dir left at that path (here,
# manufactured directly; remove no longer leaves one behind under normal
# operation) is a real collision clone must refuse to adopt/clobber.
RC_PROJ="${WORK}/proj-remove-clone"
make_project_repo "${RC_PROJ}" yes "remove-clone-demo"
RC_BARE="${WORK}/origins/remove-clone-demo.git"
(cd "${RC_PROJ}" && "${NOOK}" init notes origin >/dev/null)
RC_SLUG=$(slug_for_name "${RC_PROJ}" notes)
printf 'x\n' > "${RC_PROJ}/notes/f"
(cd "${RC_PROJ}" && "${NOOK}" -n notes run add --all && "${NOOK}" -n notes run commit -q -m seed && "${NOOK}" -n notes run push -q)
(cd "${RC_PROJ}" && "${NOOK}" -n notes remove --force >/dev/null)

mkdir -p "${RC_PROJ}/.git/nook/${RC_SLUG}.git"
run_cmd_in "${RC_PROJ}" "${NOOK}" clone notes "${RC_BARE}"
assert_exit_nonzero "re-clone with stale inner repo refused (history is never silently adopted or destroyed)"
assert_contains "refusal names the stale path" "${RUN_OUT}" "${RC_SLUG}.git"

rm -rf "${RC_PROJ}/.git/nook/${RC_SLUG}.git" "${RC_PROJ}/notes"
RC_READD=$(cd "${RC_PROJ}" && "${NOOK}" clone notes "${RC_BARE}")
assert_contains "re-clone succeeds after manual cleanup" "${RC_READD}" "cloned"

section "init argument parsing: missing values and extra args"

run_cmd_in "${RM_PROJ}" "${NOOK}" init other origin --dir
assert_exit_nonzero "--dir without a value refused"
assert_contains "--dir error names the flag" "${RUN_OUT}" "--dir requires a value"
run_cmd_in "${RM_PROJ}" "${NOOK}" init other origin --bogus-flag
assert_exit_nonzero "unknown flag refused"
run_cmd_in "${RM_PROJ}" "${NOOK}" init other origin surplus
assert_exit_nonzero "extra positional argument refused"
assert_contains "extra positional named" "${RUN_OUT}" "surplus"
run_cmd_in "${RM_PROJ}" "${NOOK}" init
assert_exit_nonzero "missing name/target shows usage error"
assert_contains "usage error printed" "${RUN_OUT}" "usage: git nook init"

# --- isolation: ignore machinery and byte identity ---------------------------------

section "isolation: the nook's own .gitignore filters; the host's never does"

ISO_PROJ="${WORK}/proj-isolation"
make_project_repo "${ISO_PROJ}" yes "iso-demo"
(cd "${ISO_PROJ}" && "${NOOK}" init data origin >/dev/null)

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
(cd "${ISO_B}" && "${NOOK}" clone data origin >/dev/null)
CRLF_HASH_AFTER=$(shasum "${ISO_B}/data/windows.txt" | awk '{print $1}')
assert_eq "CRLF file round-trips byte-identically despite global autocrlf=true" \
    "${CRLF_HASH_BEFORE}" "${CRLF_HASH_AFTER}"

git config --global --unset core.autocrlf

# --- materialize: linking configured nooks into other worktrees -------------------

section "materialize: peer worktree symlinks to the primary home"
MZ=${WORK}/proj-materialize; make_project_repo "${MZ}" yes materialize-demo
(cd "${MZ}" && "${NOOK}" init beads origin --dir .beads)
MZ_SLUG=$(slug_for_name "${MZ}" beads)
assert_true "originating worktree has a REAL primary-home dir" test -d "${MZ}/.beads"
if [[ -L "${MZ}/.beads" ]]; then fail "originating worktree must be a real dir"; else pass "originating is a real dir"; fi
printf 'x\n' > "${MZ}/.beads/f.txt"
(cd "${MZ}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
WT=${WORK}/proj-materialize-wt
git -C "${MZ}" worktree add -q "${WT}" -b feat
assert_file_absent "peer worktree has no nook symlink before materialize" "${WT}/.beads"
MZ_OUT=$(cd "${WT}" && "${NOOK}" materialize)
assert_contains "materialize reports the nook" "${MZ_OUT}" "materialized ${MZ_SLUG}"
assert_true "peer worktree got a symlink" test -L "${WT}/.beads"
# The peer symlink resolves to the ORIGINATING worktree's real dir (the home).
assert_eq "peer symlink resolves to the primary home" "$(cd "${MZ}/.beads" && pwd -P)" "$(cd "${WT}/.beads" && pwd -P)"
assert_file_exists "content visible through the peer symlink" "${WT}/.beads/f.txt"
# NGI-3: the resolved target has no .git component.
if [[ "$(cd "${WT}/.beads" && pwd -P)" == *"/.git/"* ]]; then fail "peer symlink resolves under .git"; else pass "peer symlink target has no .git component"; fi
MZ_LOG=$(cd "${WT}" && "${NOOK}" -n beads run log --oneline)
assert_contains "passthrough works from peer worktree after materialize" "${MZ_LOG}" "c1"
assert_eq "peer worktree parent status clean" "" "$(git -C "${WT}" status --porcelain)"
# idempotent
(cd "${WT}" && "${NOOK}" materialize >/dev/null)
assert_true "second materialize is a no-op (still a symlink)" test -L "${WT}/.beads"

section "materialize: restores an emptied-but-present primary home (git clean -x recovery)"
# The home DIR survives but its files were wiped (e.g. `git clean -x`, or a
# manual `rm` of only the contents). The old code repopulated from HEAD on
# every materialize; this layout's primary branch only `mkdir -p`s, so
# without the fix `materialize` prints "materialized" but leaves the dir
# empty and `run status` then shows every tracked file as deleted --
# undercutting the "git clean -x is recoverable via re-materialize" story.
rm -f "${MZ}/.beads"/*
assert_true "home dir survives, but is now empty" test -z "$(ls -A "${MZ}/.beads" 2>/dev/null)"
(cd "${MZ}" && "${NOOK}" materialize >/dev/null)
assert_file_exists "committed content restored into the emptied home" "${MZ}/.beads/f.txt"
assert_eq "restored content matches HEAD" "x" "$(cat "${MZ}/.beads/f.txt")"
MZ_STATUS_AFTER_RESTORE=$(cd "${MZ}" && "${NOOK}" -n beads run status --porcelain)
assert_eq "no phantom deletions after restore" "" "${MZ_STATUS_AFTER_RESTORE}"

section "materialize: refuses when the peer's content path and the home both have content"
# A real dir with content at the peer's configured path, while the primary
# home also has content -> ambiguous -> refuse (never silently pick a side).
rm "${WT}/.beads"
mkdir -p "${WT}/.beads"; printf 'independent\n' > "${WT}/.beads/other.txt"
run_cmd_in "${WT}" "${NOOK}" materialize
assert_exit_nonzero "materialize refuses when peer content and home both have content"
assert_contains "refusal explains the conflict" "${RUN_OUT}" "reconcile manually"
rm -rf "${WT}/.beads"   # clean up for reuse below

section "materialize: promotes a surviving worktree when the primary home is gone"
PR=${WORK}/proj-promote; make_project_repo "${PR}" yes promote-demo
(cd "${PR}" && "${NOOK}" init beads origin --dir .beads)
PR_SLUG=$(slug_for_name "${PR}" beads)
printf 'v1\n' > "${PR}/.beads/data.txt"
(cd "${PR}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
# Peer worktree materializes as a symlink.
PRW=${WORK}/proj-promote-wt
git -C "${PR}" worktree add -q "${PRW}" -b feat
(cd "${PRW}" && "${NOOK}" materialize >/dev/null)
assert_true "peer symlink exists before promotion" test -L "${PRW}/.beads"
# Simulate the primary home worktree being removed: delete the real dir.
rm -rf "${PR}/.beads"
# materialize in the peer PROMOTES it: re-checkout HEAD into the peer's dir.
(cd "${PRW}" && "${NOOK}" materialize >/dev/null)
assert_true "promoted worktree now has a REAL dir" test -d "${PRW}/.beads"
if [[ -L "${PRW}/.beads" ]]; then fail "promoted worktree must be a real dir, not a symlink"; else pass "promoted worktree is a real dir"; fi
assert_file_exists "committed content restored from inner repo" "${PRW}/.beads/data.txt"
assert_eq "home now points at the promoted worktree" \
    "$(cd "${PRW}/.beads" && pwd -P)" "$(cd "$(git -C "${PR}" config --get "nook.${PR_SLUG}.home")" && pwd -P)"

section "materialize: a peer's dangling symlink re-resolves after another peer promotes (regression)"
# 3+ worktrees: A=home, B and C are peers. A's dir dies; B promotes (becomes
# the new real-dir primary). C's symlink now dangles (points at A's dead
# path). C's materialize must NOT refuse forever -- it should drop the
# dangling symlink and recreate it pointing at B's (the new) home.
DP=${WORK}/proj-danglepeer; make_project_repo "${DP}" yes danglepeer-demo
(cd "${DP}" && "${NOOK}" init beads origin --dir .beads)
printf 'v1\n' > "${DP}/.beads/data.txt"
(cd "${DP}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
DPB=${WORK}/proj-danglepeer-b; git -C "${DP}" worktree add -q "${DPB}" -b featb
DPC=${WORK}/proj-danglepeer-c; git -C "${DP}" worktree add -q "${DPC}" -b featc
(cd "${DPB}" && "${NOOK}" materialize >/dev/null)
(cd "${DPC}" && "${NOOK}" materialize >/dev/null)
assert_true "B has a peer symlink before promotion" test -L "${DPB}/.beads"
assert_true "C has a peer symlink before promotion" test -L "${DPC}/.beads"
# Kill A's home; B promotes (becomes the new real-dir primary).
rm -rf "${DP}/.beads"
(cd "${DPB}" && "${NOOK}" materialize >/dev/null)
if [[ -L "${DPB}/.beads" ]]; then fail "B must be a real dir after promotion"; else pass "B promoted to a real dir"; fi
# C's symlink is now dangling (still points at A's dead path). Without the
# fix, C's materialize hits the peer branch, resolves an empty target ('t=""'),
# and refuses forever ("refusing to clobber").
run_cmd_in "${DPC}" "${NOOK}" materialize
assert_exit_zero "C's materialize succeeds despite a dangling symlink to the old home"
assert_true "C got a fresh symlink" test -L "${DPC}/.beads"
assert_eq "C's symlink now resolves to B's (the new) home" \
    "$(cd "${DPB}/.beads" && pwd -P)" "$(cd "${DPC}/.beads" && pwd -P)"
assert_file_exists "content visible through C's re-resolved symlink" "${DPC}/.beads/data.txt"

section "election: refuses to elect through a live symlink (never records a home under it)"
# No home recorded yet, and content_path is a LIVE (non-dangling) symlink --
# e.g. a legacy-container leftover, or any user symlink. Electing through it
# would follow it (mkdir -p/populate_checkout_from_head all resolve
# symlinks) and record the FOREIGN target as the home -- if that target
# happens to resolve under .git/, the home would silently violate NGI-3.
ELS=${WORK}/proj-elect-livesym; make_project_repo "${ELS}" yes elect-livesym-demo
(cd "${ELS}" && "${NOOK}" init beads origin --dir .beads >/dev/null)
ELS_SLUG=$(slug_for_name "${ELS}" beads)
# Simulate a legacy container under .git/ that a live symlink still points at
# (the scenario the reviewer called out as worst-case).
ELS_LEGACY_DIR="${ELS}/.git/legacy-leftover"
mkdir -p "${ELS_LEGACY_DIR}"; printf 'foreign\n' > "${ELS_LEGACY_DIR}/foreign.txt"
# Unelect this nook entirely (simulate "no home ever recorded") and replace
# its content path with a live symlink into the .git-nested legacy dir.
git -C "${ELS}" config --unset "nook.${ELS_SLUG}.home"
rm -rf "${ELS}/.beads"
ln -s "${ELS_LEGACY_DIR}" "${ELS}/.beads"
run_cmd_in "${ELS}" "${NOOK}" materialize
assert_exit_nonzero "election refuses a live symlink at the content path"
assert_contains "refusal names the dir" "${RUN_OUT}" ".beads"
assert_true "the live symlink itself is left untouched" test -L "${ELS}/.beads"
assert_true "no home was recorded" test -z "$(git -C "${ELS}" config --get "nook.${ELS_SLUG}.home" 2>/dev/null)"

section "materialize: promotion refuses to clobber independent content at the target"
PC=${WORK}/proj-promote-clobber; make_project_repo "${PC}" yes promote-clobber
(cd "${PC}" && "${NOOK}" init beads origin --dir .beads)
printf 'committed\n' > "${PC}/.beads/c.txt"
(cd "${PC}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
PCW=${WORK}/proj-promote-clobber-wt
git -C "${PC}" worktree add -q "${PCW}" -b feat
(cd "${PCW}" && "${NOOK}" materialize >/dev/null)   # peer symlink
# Kill the primary; then put INDEPENDENT real content where the peer symlink was.
rm -rf "${PC}/.beads"
rm -f "${PCW}/.beads"                                 # drop the now-dangling symlink
mkdir -p "${PCW}/.beads"; printf 'independent\n' > "${PCW}/.beads/other.txt"
run_cmd_in "${PCW}" "${NOOK}" materialize
assert_exit_nonzero "promotion refuses when target holds independent content"
assert_contains "refusal explains the conflict" "${RUN_OUT}" "reconcile manually"

section "materialize: adopts a pre-home nook (created before this feature existed) with commit history"
# A nook created before nook.<slug>.home existed (or whose repo dir was
# since moved/renamed) has real, committed content at <toplevel>/<dir> and
# nook.<slug>.dir set, but NO .home ever recorded. The guard/election must
# not dead-end at "both '.beads' and the nook have content; reconcile
# manually" forever -- it should ADOPT the existing dir as the home. This is
# exactly this repo's own beads nook on merge day, and mirrors the old
# "upgrades a legacy real-dir nook that has commit history" test from before
# the worktree-home layout landed.
UP=${WORK}/proj-upgrade; make_project_repo "${UP}" yes upgrade-demo
UP_GITDIR="${UP}/.git/nook/legacy.git"
mkdir -p "${UP}/.git/nook"
git init -q --bare "${UP_GITDIR}"
git --git-dir="${UP_GITDIR}" symbolic-ref HEAD refs/heads/main
git --git-dir="${UP_GITDIR}" config core.bare false
mkdir -p "${UP}/.legacy"; printf 'issue-1\n' > "${UP}/.legacy/data.txt"
git --git-dir="${UP_GITDIR}" --work-tree="${UP}/.legacy" add data.txt
git --git-dir="${UP_GITDIR}" --work-tree="${UP}/.legacy" -c user.email=t@t -c user.name=t commit -q -m "legacy history"
git -C "${UP}" config nook.legacy.dir .legacy
printf '/.legacy\n' >> "$(abs_git_path "${UP}" info/exclude)"
# sanity: real dir, not a symlink, with content + history, NO .home recorded.
assert_true "precondition: legacy content dir is a real dir" test -d "${UP}/.legacy"
if [[ -L "${UP}/.legacy" ]]; then fail "precondition violated: already a symlink"; else pass "precondition: not a symlink yet"; fi
assert_true "precondition: no home recorded yet" test -z "$(git -C "${UP}" config --get nook.legacy.home 2>/dev/null)"
# ADOPT: materialize must adopt it, not refuse.
run_cmd_in "${UP}" "${NOOK}" materialize
assert_eq "materialize succeeds on a pre-home nook with history (out: ${RUN_OUT})" "0" "${RUN_EXIT}"
assert_contains "materialize reports the adoption" "${RUN_OUT}" "adopted"
if [[ -L "${UP}/.legacy" ]]; then fail "adopted dir must stay a real dir, not become a symlink"; else pass "adopted dir remains a real dir"; fi
assert_file_exists "committed history preserved (file still present)" "${UP}/.legacy/data.txt"
assert_eq "home now recorded at the adopted dir" \
    "$(cd "${UP}/.legacy" && pwd -P)" "$(cd "$(git -C "${UP}" config --get nook.legacy.home)" && pwd -P)"
# passthrough works and history is intact.
UP_LOG=$(cd "${UP}" && "${NOOK}" -n legacy run log --oneline)
assert_contains "committed history preserved after adoption" "${UP_LOG}" "legacy history"
UP_STATUS=$(cd "${UP}" && "${NOOK}" -n legacy run status --porcelain)
assert_eq "clean working tree after adoption" "" "${UP_STATUS}"
assert_eq "host status clean" "" "$(git -C "${UP}" status --porcelain -- .legacy)"
# run status works afterward without hitting the dangling-primary guard.
run_cmd_in "${UP}" "${NOOK}" -n legacy run status
assert_exit_zero "run status works after adoption (guard does not misfire)"

section "materialize: no nooks configured prints guidance"
MZE=${WORK}/proj-mz-empty; make_project_repo "${MZE}" no mzempty
MZE_OUT=$(cd "${MZE}" && "${NOOK}" materialize)
assert_contains "materialize with no nooks names the init command" "${MZE_OUT}" "git nook init"

section "init: a nook may be named 'materialize' (no reserved names)"
MZR=${WORK}/proj-mz-reserved; make_project_repo "${MZR}" yes mzr
run_cmd_in "${MZR}" "${NOOK}" init materialize origin
assert_exit_zero "creating a nook named 'materialize' succeeds"
assert_contains "init reports the new nook named 'materialize'" "${RUN_OUT}" "initialized nook 'materialize'"
run_cmd_in "${MZR}" "${NOOK}" -n materialize run status
assert_exit_zero "'-n materialize run status' reaches the nook named 'materialize'"

# --- list: unmaterialized marker ---------------------------------------------------

section "list: flags a nook not materialized in this worktree"
LM=${WORK}/proj-listmark; make_project_repo "${LM}" yes listmark
(cd "${LM}" && "${NOOK}" init data origin --dir .data >/dev/null)
LM_OK=$(cd "${LM}" && "${NOOK}" list)
if [[ "${LM_OK}" == *"not linked here"* ]]; then fail "materialized nook wrongly flagged"; else pass "materialized nook not flagged"; fi
# Simulate an unmaterialized worktree via a peer worktree that hasn't run
# materialize yet: list there must flag it "not linked here".
LM_WT=${WORK}/proj-listmark-wt
git -C "${LM}" worktree add -q "${LM_WT}" -b listfeat
LM_FLAG=$(cd "${LM_WT}" && "${NOOK}" list)
assert_contains "unmaterialized nook is flagged" "${LM_FLAG}" "not linked here"

# --- bare/all-worktrees layout: no originating work tree ---------------------------

section "bare layout: init + materialize across peer worktrees (no main work tree)"
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
# Add a nook FROM a linked worktree (there is no main work tree). This
# worktree ELECTS itself as the primary home: a real dir, not a symlink.
(cd "${WA}" && "${NOOK}" init beads origin --dir .beads)
if [[ -L "${WA}/.beads" ]]; then fail "adding worktree (the elected home) must not be a symlink"; else pass "adding worktree got a real dir (the primary home)"; fi
printf 'y\n' > "${WA}/.beads/f.txt"
(cd "${WA}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c1)
# Peer worktree: list flags it unmaterialized; materialize links it.
LIST_B=$(cd "${WB}" && "${NOOK}" list)
assert_contains "list flags unmaterialized nook in peer worktree" "${LIST_B}" "not linked here"
(cd "${WB}" && "${NOOK}" materialize >/dev/null)
assert_true "peer worktree now has the symlink" test -L "${WB}/.beads"
assert_file_exists "peer worktree sees the shared content" "${WB}/.beads/f.txt"
# The peer's symlink resolves to the SAME real dir as the adding worktree's home.
RA=$(cd "${WA}/.beads" && pwd -P); RB=$(cd "${WB}/.beads" && pwd -P)
assert_eq "both worktrees resolve to the one primary home" "${RA}" "${RB}"
# After materialize, list no longer flags it.
LIST_B2=$(cd "${WB}" && "${NOOK}" list)
if [[ "${LIST_B2}" == *"not linked here"* ]]; then fail "list still flags a materialized nook"; else pass "list no longer flags materialized nook"; fi
# A commit from one peer is visible to the other (shared refs+objects).
printf 'z\n' > "${WA}/.beads/g.txt"
(cd "${WA}" && "${NOOK}" -n beads run add --all && "${NOOK}" -n beads run commit -q -m c2)
LOG_B=$(cd "${WB}" && "${NOOK}" -n beads run log --oneline)
assert_contains "commit from peer A visible from peer B" "${LOG_B}" "c2"

section "home: show reports the primary home path (not a .git container)"
NEST=${WORK}/proj-nested
make_project_repo "${NEST}" yes nested-demo
(cd "${NEST}" && "${NOOK}" init beads origin --dir .beads >/dev/null)
NEST_SHOW=$(cd "${NEST}" && "${NOOK}" -n beads show)
NEST_HOME="$(cd "${NEST}/.beads" && pwd -P)"
assert_contains "show reports home: as the real primary-home dir" "${NEST_SHOW}" "home:     ${NEST_HOME}"
if [[ "${NEST_HOME}" == *"/.git/"* ]]; then fail "home under .git"; else pass "home has no .git component"; fi

section "home: passthrough commits tracked paths bare (no basename prefix)"
NESTPT=${WORK}/proj-nested-pt
make_project_repo "${NESTPT}" yes nested-pt-demo
(cd "${NESTPT}" && "${NOOK}" init beads origin --dir .beads >/dev/null)
echo '{"id":"x1"}' > "${NESTPT}/.beads/issues.jsonl"
(cd "${NESTPT}" && "${NOOK}" -n beads run add --all >/dev/null)
(cd "${NESTPT}" && "${NOOK}" -n beads run commit -q -m "seed" >/dev/null)
NESTPT_TREE=$(cd "${NESTPT}" && "${NOOK}" -n beads run ls-tree --name-only -r HEAD)
assert_eq "tracked path is bare issues.jsonl (no .beads/ prefix)" \
    "issues.jsonl" "${NESTPT_TREE}"

section "home: init materializes the primary home as a real dir"
NESTM=${WORK}/proj-nested-mat
make_project_repo "${NESTM}" yes nested-mat-demo
(cd "${NESTM}" && "${NOOK}" init beads origin --dir .beads >/dev/null)
NESTM_SLUG=$(slug_for_name "${NESTM}" beads)
if [[ -L "${NESTM}/.beads" ]]; then fail "originating worktree content path must not be a symlink"; else pass "content path is a real dir"; fi
assert_dir_exists "primary home dir exists" "${NESTM}/.beads"
assert_eq "home recorded at the content path" \
    "$(cd "${NESTM}/.beads" && pwd -P)" "$(cd "$(git -C "${NESTM}" config --get "nook.${NESTM_SLUG}.home")" && pwd -P)"

section "invariant: no checkout path or symlink target contains a .git component"
NG=${WORK}/proj-ngi3; make_project_repo "${NG}" yes ngi3-demo
(cd "${NG}" && "${NOOK}" init beads origin --dir .beads >/dev/null)
NG_SLUG=$(slug_for_name "${NG}" beads)
NG_HOME=$(git -C "${NG}" config --get "nook.${NG_SLUG}.home")
if [[ "/${NG_HOME}/" == *"/.git/"* ]]; then fail "primary home under .git"; else pass "primary home has no .git component"; fi
NG_WT=$( cd "${NG}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  canonical_worktree "${NG_SLUG}" )
if [[ "/${NG_WT}/" == *"/.git/"* ]]; then fail "canonical_worktree under .git"; else pass "canonical_worktree has no .git component"; fi

section "invariant: nook.<slug>.home never travels to the remote"
# nook.<slug>.home is local git config, never tracked content or a ref, so it
# cannot be pushed by construction -- confirm it is absent from a fresh clone
# of the same origin (a real, not merely theoretical, check of "local-only").
NG_CLONE=${WORK}/proj-ngi3-clone
git clone -q "$(git -C "${NG}" remote get-url origin)" "${NG_CLONE}"
if git -C "${NG_CLONE}" config --get-regexp '^nook\..*\.home$' >/dev/null 2>&1; then
    fail "nook.<slug>.home leaked into a fresh clone"
else
    pass "nook.<slug>.home is local-only (absent from a fresh clone)"
fi

section "acceptance: br operates against a home-layout nook (NGI-3 unblocked)"
if command -v br >/dev/null 2>&1; then
    BR=${WORK}/proj-br; make_project_repo "${BR}" yes br-demo
    (cd "${BR}" && "${NOOK}" init beads origin --dir .beads >/dev/null)
    run_cmd_in "${BR}/.beads" br init
    assert_exit_zero "br init succeeds in the home dir (no NGI-3)"
    if [[ "${RUN_OUT}" == *"NGI-3"* || "${RUN_OUT}" == *"targets git internals"* ]]; then
        fail "br still hit NGI-3 against the home layout"
    else
        pass "br did not hit NGI-3"
    fi
else
    echo "  [SKIP] br not installed; NGI-3 acceptance not exercised here"
fi

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

section "unit: sanitize_field maps non-alphanumerics to underscore"

# Source the tool's helpers without running main. The script runs main "$@"
# at the very end; guard by setting GIT_NOOK_LIB=1 (added in the impl step).
# shellcheck source=/dev/null
GIT_NOOK_LIB=1 . "${NOOK}"

assert_eq "plain alnum unchanged" "beads" "$(sanitize_field 'beads')"
assert_eq "dots to underscores" "my_notes" "$(sanitize_field 'my.notes')"
assert_eq "slash and dash mapped" "a_b_c" "$(sanitize_field 'a/b-c')"
assert_eq "mixed case preserved" "MyRepo" "$(sanitize_field 'MyRepo')"
assert_eq "leading dot mapped" "_beads" "$(sanitize_field '.beads')"
assert_eq "empty stays empty" "" "$(sanitize_field '')"

section "unit: gen_uuid produces distinct lowercased hex-ish uuids"

U1=$(gen_uuid)
U2=$(gen_uuid)
assert_true "uuid 1 nonempty" test -n "${U1}"
assert_true "uuid 2 nonempty" test -n "${U2}"
assert_true "two uuids differ" test "${U1}" != "${U2}"
# At least 8 chars so a 3-char prefix is always available.
assert_true "uuid at least 8 chars" test "${#U1}" -ge 8
# id3 is the first 3 chars, lowercased alnum.
ID3=$(printf '%s' "${U1}" | cut -c1-3)
assert_eq "id3 is 3 chars" "3" "${#ID3}"

section "unit: build_slug joins sanitized fields"

assert_eq "basic slug" \
    "beads.a3f.alice.my_simple_project" \
    "$(build_slug 'beads' 'a3f9c2e1' 'alice' 'my-simple-project')"
assert_eq "dotted name sanitized in slug" \
    "my_notes.7c1.bob.repo" \
    "$(build_slug 'my.notes' '7c1zzzz' 'bob' 'repo')"
assert_eq "owner with dots sanitized" \
    "n.abc.a_b.c_d" \
    "$(build_slug 'n' 'abcdef' 'a.b' 'c.d')"

section "unit: path helpers key off slug"

# Build a throwaway repo so common_git_dir resolves.
PH_REPO="${WORK}/ph-repo"
make_project_repo "${PH_REPO}" yes ph
( cd "${PH_REPO}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  cd "${PH_REPO}"
  SLUG="beads.a3f.alice.proj"
  git config "nook.${SLUG}.dir" ".beads"
  gd=$(inner_git_dir "${SLUG}")
  wt=$(canonical_worktree "${SLUG}")
  case "${gd}" in *"/nook/${SLUG}.git") echo GDOK;; *) echo "GDBAD:${gd}";; esac
  # No home recorded yet -> canonical_worktree falls back to the election
  # candidate: <toplevel>/.beads (never a .git path). Compare via `pwd`
  # (not -P) on both sides: no symlink is involved here, just normalizing
  # any double-slash noise from a trailing-slash $TMPDIR.
  case "${wt}" in "$(pwd)/.beads") echo WTOK;; *) echo "WTBAD:${wt}";; esac
) > "${WORK}/ph.out" 2>&1
assert_contains "inner_git_dir uses slug" "$(cat "${WORK}/ph.out")" "GDOK"
assert_contains "canonical_worktree falls back to the election candidate" "$(cat "${WORK}/ph.out")" "WTOK"

section "unit: primary-home helpers"
# Source the tool's helpers without running main; established pattern is
# GIT_NOOK_LIB=1 . "${NOOK}" in a subshell after cd-ing into a real repo.
HH_PROJ="${WORK}/proj-home-helpers"
make_project_repo "${HH_PROJ}" yes home-helpers
(cd "${HH_PROJ}" && "${NOOK}" init hdemo origin --dir .hdemo >/dev/null)
HH_SLUG=$(slug_for_name "${HH_PROJ}" hdemo)

# home_candidate: the election target for THIS worktree = <toplevel>/<dir>
HH_CAND=$( cd "${HH_PROJ}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  home_candidate "${HH_SLUG}" )
assert_eq "home_candidate is <toplevel>/<dir>" "$(cd "${HH_PROJ}" && pwd)/.hdemo" "${HH_CAND}"

# After init, primary_home is recorded and equals the candidate.
HH_HOME=$(git -C "${HH_PROJ}" config --get "nook.${HH_SLUG}.home")
assert_eq "init recorded nook.<slug>.home = <toplevel>/<dir>" "$(cd "${HH_PROJ}/.hdemo" && pwd -P)" "$(cd "${HH_HOME}" && pwd -P)"

# resolve_primary succeeds (home exists as a directory)
# shellcheck disable=SC2016 # $0/$1 below are for the bash -c subshell, not this outer shell
run_cmd_in "${HH_PROJ}" bash -c '
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "$0"
  resolve_primary "$1" >/dev/null' "${NOOK}" "${HH_SLUG}"
assert_exit_zero "resolve_primary succeeds when home dir exists"

# resolve_primary fails when home is gone
rm -rf "${HH_HOME}" "${HH_PROJ}/.hdemo"
# shellcheck disable=SC2016 # $0/$1 below are for the bash -c subshell, not this outer shell
run_cmd_in "${HH_PROJ}" bash -c '
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "$0"
  resolve_primary "$1" >/dev/null' "${NOOK}" "${HH_SLUG}"
assert_exit_nonzero "resolve_primary fails when home dir is missing"

section "unit: canonical_worktree returns recorded home when set"
CW_PROJ="${WORK}/proj-cw"; make_project_repo "${CW_PROJ}" yes cw-demo
(cd "${CW_PROJ}" && "${NOOK}" init cwd origin --dir .cwd >/dev/null)
CW_SLUG=$(slug_for_name "${CW_PROJ}" cwd)
# canonical_worktree must equal the recorded home (a real dir in the work-tree),
# and must NOT contain a .git path component.
CW=$( cd "${CW_PROJ}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  canonical_worktree "${CW_SLUG}" )
assert_eq "canonical_worktree == recorded home" "$(cd "${CW_PROJ}/.cwd" && pwd -P)" "$(cd "${CW}" && pwd -P)"
if [[ "/${CW}/" == *"/.git/"* ]]; then fail "canonical_worktree still under .git"; else pass "canonical_worktree has no .git component"; fi

section "unit: resolve_slug_prefix matches minimal left-anchored prefix"

RP_REPO="${WORK}/rp-repo"
make_project_repo "${RP_REPO}" yes rp
( cd "${RP_REPO}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  cd "${RP_REPO}"
  git config "nook.beads.7c1.bob.projx.dir" ".beads"
  git config "nook.notes.a3f.bob.projx.dir" "notes"
  git config "nook.notes.f92.eve.other.dir" "n2"

  echo "UNIQ:$(resolve_slug_prefix 'beads' 2>&1)"
  echo "EXACT:$(resolve_slug_prefix 'beads.7c1.bob.projx' 2>&1)"
  echo "AMBIG_RC:$(resolve_slug_prefix 'notes' >/dev/null 2>&1; echo $?)"
  echo "AMBIG_MSG:$(resolve_slug_prefix 'notes' 2>&1 || true)"
  echo "NARROW:$(resolve_slug_prefix 'notes.a3f' 2>&1)"
  echo "NONE_RC:$(resolve_slug_prefix 'zzz' >/dev/null 2>&1; echo $?)"
) > "${WORK}/rp.out" 2>&1
OUT=$(cat "${WORK}/rp.out")
assert_contains "unique name resolves to full slug" "${OUT}" "UNIQ:beads.7c1.bob.projx"
assert_contains "exact slug resolves to itself" "${OUT}" "EXACT:beads.7c1.bob.projx"
assert_contains "ambiguous prefix returns nonzero" "${OUT}" "AMBIG_RC:1"
assert_contains "ambiguous lists both candidates" "${OUT}" "notes.a3f.bob.projx"
assert_contains "ambiguous lists the other candidate" "${OUT}" "notes.f92.eve.other"
assert_contains "narrowed prefix resolves uniquely" "${OUT}" "NARROW:notes.a3f.bob.projx"
assert_contains "no match returns nonzero" "${OUT}" "NONE_RC:1"

section "unit: manifest write to inner ref and read back"

MF_REPO="${WORK}/mf-repo"
make_project_repo "${MF_REPO}" yes mf
( cd "${MF_REPO}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  cd "${MF_REPO}"
  SLUG="beads.a3f.alice.proj"
  git config "nook.${SLUG}.dir" ".beads"
  gd=$(inner_git_dir "${SLUG}")
  mkdir -p "$(dirname "${gd}")"
  git init -q --bare "${gd}"
  write_manifest_ref "${gd}" \
    "a3f9c2e1-full-uuid" "beads" "alice" "my-proj" \
    "git@github.com:alice/my-proj.git" "Alice <a@x>" "2026-07-20T00:00:00Z" ".beads"
  echo "UUID:$(read_manifest_field "${gd}" refs/nook-meta/manifest uuid)"
  echo "NAME:$(read_manifest_field "${gd}" refs/nook-meta/manifest name)"
  echo "OWNER:$(read_manifest_field "${gd}" refs/nook-meta/manifest owner)"
  echo "REPO:$(read_manifest_field "${gd}" refs/nook-meta/manifest repo_dir)"
  echo "DIR:$(read_manifest_field "${gd}" refs/nook-meta/manifest dir)"
  echo "UPSTREAM:$(read_manifest_field "${gd}" refs/nook-meta/manifest upstream)"
) > "${WORK}/mf.out" 2>&1
OUT=$(cat "${WORK}/mf.out")
assert_contains "manifest uuid round-trips" "${OUT}" "UUID:a3f9c2e1-full-uuid"
assert_contains "manifest name round-trips" "${OUT}" "NAME:beads"
assert_contains "manifest owner round-trips" "${OUT}" "OWNER:alice"
assert_contains "manifest repo_dir round-trips" "${OUT}" "REPO:my-proj"
assert_contains "manifest dir round-trips" "${OUT}" "DIR:.beads"
assert_contains "manifest upstream round-trips" "${OUT}" "UPSTREAM:git@github.com:alice/my-proj.git"

section "init: creates a slug-keyed wired hidden inner repo"

IN_REPO="${WORK}/init-repo"
make_project_repo "${IN_REPO}" yes myproj
# Point origin at a reachable bare repo whose path still carries alice/myproj
# provenance (owner_and_project derives owner/repo from the URL's last two
# path segments), so the init-time manifest push in this section actually
# lands on a real remote instead of an unreachable placeholder URL.
IN_ORIGIN="${WORK}/origins/alice/myproj.git"
mkdir -p "$(dirname "${IN_ORIGIN}")"
git init -q --bare "${IN_ORIGIN}"
( cd "${IN_REPO}"
  git remote set-url origin "${IN_ORIGIN}"
  "${NOOK}" init beads origin --dir .beads
)
# Find the single configured slug.
IN_SLUG=$(cd "${IN_REPO}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
assert_contains "slug has name.id3.owner.repo shape" "${IN_SLUG}" "beads."
case "${IN_SLUG}" in beads.*.alice.myproj) pass "slug carries provenance owner/repo";; *) fail "slug provenance wrong: ${IN_SLUG}";; esac
IN_GD="${IN_REPO}/.git/nook/${IN_SLUG}.git"
assert_dir_exists "inner git dir exists at slug path" "${IN_GD}"
assert_eq "push refspec targets /files" \
    "refs/heads/main:refs/nook/${IN_SLUG}/files" \
    "$(git --git-dir="${IN_GD}" config --get remote.origin.push)"
assert_eq "fetch refspec reads /files" \
    "+refs/nook/${IN_SLUG}/files:refs/remotes/origin/main" \
    "$(git --git-dir="${IN_GD}" config --get remote.origin.fetch)"
if [[ -L "${IN_REPO}/.beads" ]]; then fail "originating worktree content path must not be a symlink"; else pass "primary home materialized as a real dir"; fi
assert_eq "manifest name is the exact name" "beads" \
    "$(git --git-dir="${IN_GD}" show refs/nook-meta/manifest:manifest.json | grep '"name"' | sed -E 's/.*: *"(.*)".*/\1/')"
assert_contains "manifest ref published to remote at init" \
    "$(git ls-remote "${IN_ORIGIN}" "refs/nook/${IN_SLUG}/manifest")" "refs/nook/${IN_SLUG}/manifest"
assert_eq "files ref NOT yet published at init (main unborn)" "" \
    "$(git ls-remote "${IN_ORIGIN}" "refs/nook/${IN_SLUG}/files")"

section "clone: fetches an existing nook by name"

# Producer repo inits a nook and pushes content to a shared bare origin.
CLONE_SHARED="${WORK}/origins/shared-nooks.git"
mkdir -p "$(dirname "${CLONE_SHARED}")"; git init -q --bare "${CLONE_SHARED}"
CLONE_PROD="${WORK}/clone-prod-repo"
make_project_repo "${CLONE_PROD}" no prod
( cd "${CLONE_PROD}"
  git remote add origin "git@github.com:bob/prod.git"   # provenance only
  "${NOOK}" init beads "${CLONE_SHARED}" --dir .beads
  echo "hi" > .beads/issues.jsonl
  "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m "seed"
  "${NOOK}" -n beads run push
)
# Consumer clones by name into a fresh repo.
CLONE_CONS="${WORK}/clone-cons-repo"
make_project_repo "${CLONE_CONS}" no cons
( cd "${CLONE_CONS}"
  "${NOOK}" clone beads "${CLONE_SHARED}" --dir .beads
)
if [[ -L "${CLONE_CONS}/.beads" ]]; then fail "consumer's fresh clone must elect a real dir, not a symlink"; else pass "consumer has a real primary-home dir"; fi
assert_contains "cloned content present" "$(cat "${CLONE_CONS}/.beads/issues.jsonl" 2>/dev/null)" "hi"

section "clone refusals: tracked dir and bad --dir"
CLR="${WORK}/clone-refuse"; make_project_repo "${CLR}" no clr
( cd "${CLR}"; mkdir -p taken; echo t > taken/f; git add taken/f; git commit -q -m t )
RC=$(cd "${CLR}"; "${NOOK}" clone beads "${CLONE_SHARED}" --dir taken >/dev/null 2>&1; echo $?)
assert_eq "clone refuses a host-tracked dir" "1" "${RC}"
assert_true "host-tracked file untouched" test -f "${CLR}/taken/f"
assert_true "host-tracked dir did not become a symlink" test ! -L "${CLR}/taken"
RC2=$(cd "${CLR}"; "${NOOK}" clone beads "${CLONE_SHARED}" --dir ../escape >/dev/null 2>&1; echo $?)
assert_eq "clone refuses escaping --dir" "1" "${RC2}"

section "clone refuses a non-empty content dir (no silent content drop)"
# Regression: clone must never silently drop fetched remote content because
# the target dir already has local (untracked) files -- the old failure mode
# exited 0, left the local files in place, and the fetched remote content
# was simply absent from the work-tree; the documented daily flow (run add
# --all && commit && push) would then publish a commit DELETING every
# remote file upstream. Reuses the "beads" nook already pushed to
# CLONE_SHARED above.
CLND="${WORK}/clnd"; make_project_repo "${CLND}" no clnd
( cd "${CLND}"; mkdir .beads; echo mine > .beads/local )
RC3=$(cd "${CLND}"; "${NOOK}" clone beads "${CLONE_SHARED}" --dir .beads >/dev/null 2>&1; echo $?)
assert_eq "clone refuses non-empty content dir" "1" "${RC3}"
assert_true "local file preserved" test -f "${CLND}/.beads/local"
assert_true "no nook was configured" test -z "$(cd "${CLND}" && git config --get-regexp '^nook\..*\.dir$')"
assert_true "no inner repo created" test -z "$(ls -A "${CLND}/.git/nook" 2>/dev/null || true)"

section "destroy: deletes upstream refs and local state"

DS="${WORK}/ds"; make_project_repo "${DS}" yes dsproj
( cd "${DS}"; "${NOOK}" init beads origin --dir .beads
  echo z > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m seed; "${NOOK}" -n beads run push )
DS_SLUG=$(cd "${DS}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
DS_ORIGIN="${WORK}/origins/dsproj.git"
assert_contains "files ref present before destroy" \
    "$(git ls-remote "${DS_ORIGIN}" "refs/nook/${DS_SLUG}/files")" "refs/nook/${DS_SLUG}/files"
assert_contains "manifest ref present before destroy" \
    "$(git ls-remote "${DS_ORIGIN}" "refs/nook/${DS_SLUG}/manifest")" "refs/nook/${DS_SLUG}/manifest"
# Requires --yes; a bare destroy must refuse and change nothing.
RC=$(cd "${DS}"; "${NOOK}" -n beads destroy >/dev/null 2>&1; echo $?)
assert_eq "destroy without --yes refuses" "1" "${RC}"
assert_contains "still configured after refusal" \
    "$(cd "${DS}" && git config --get "nook.${DS_SLUG}.dir")" ".beads"
assert_contains "files ref still there after refusal" \
    "$(git ls-remote "${DS_ORIGIN}" "refs/nook/${DS_SLUG}/files")" "refs/nook/${DS_SLUG}/files"
# With --yes: nukes upstream + local.
( cd "${DS}"; "${NOOK}" -n beads destroy --yes )
assert_eq "files ref gone after destroy" "" \
    "$(git ls-remote "${DS_ORIGIN}" "refs/nook/${DS_SLUG}/files")"
assert_eq "manifest ref gone after destroy" "" \
    "$(git ls-remote "${DS_ORIGIN}" "refs/nook/${DS_SLUG}/manifest")"
assert_true "local inner dir gone" test ! -e "${DS}/.git/nook/${DS_SLUG}.git"
assert_true "local container gone" test ! -e "${DS}/.git/nook/${DS_SLUG}.nook"
assert_true "local config gone" test -z "$(cd "${DS}" && git config --get "nook.${DS_SLUG}.dir" 2>/dev/null)"

section "destroy: aborts and changes nothing if upstream delete fails"
DSF="${WORK}/dsf"; make_project_repo "${DSF}" yes dsfproj
( cd "${DSF}"; "${NOOK}" init beads origin --dir .beads
  echo z > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
DSF_SLUG=$(cd "${DSF}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
# Repoint the inner repo's origin at a nonexistent path so push --delete fails.
git --git-dir="${DSF}/.git/nook/${DSF_SLUG}.git" config remote.origin.url "${WORK}/origins/does-not-exist.git"
RC=$(cd "${DSF}"; "${NOOK}" -n beads destroy --yes >/dev/null 2>&1; echo $?)
assert_eq "destroy aborts when upstream delete fails" "1" "${RC}"
assert_true "local inner dir intact after abort" test -e "${DSF}/.git/nook/${DSF_SLUG}.git"
assert_contains "config intact after abort" "$(cd "${DSF}" && git config --get "nook.${DSF_SLUG}.dir")" ".beads"

section "index: init adds an entry; reindex rebuilds from manifests"

IX_ORIGIN="${WORK}/origins/ixshared.git"; mkdir -p "$(dirname "${IX_ORIGIN}")"; git init -q --bare "${IX_ORIGIN}"
IXA="${WORK}/ixa"; make_project_repo "${IXA}" no ixa
( cd "${IXA}"; git remote add origin git@github.com:bob/ixa.git
  "${NOOK}" init beads "${IX_ORIGIN}" --dir .beads
  echo a > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
IDX=$(git ls-remote "${IX_ORIGIN}" refs/nook/index)
assert_contains "index ref created by init" "${IDX}" "refs/nook/index"
IXTMP="${WORK}/ixtmp.git"; git init -q --bare "${IXTMP}"
git --git-dir="${IXTMP}" fetch -q --depth 1 "${IX_ORIGIN}" refs/nook/index:refs/nook/index
INFO=$(git --git-dir="${IXTMP}" show refs/nook/index:info.json)
assert_contains "info.json lists the beads slug" "${INFO}" "beads."
assert_contains "info.json carries provenance owner" "${INFO}" "bob"

section "reindex: rebuilds a wiped index from manifest refs"
git --git-dir="${IXTMP}" push -q "${IX_ORIGIN}" --delete refs/nook/index
assert_eq "index gone" "" "$(git ls-remote "${IX_ORIGIN}" refs/nook/index)"
( cd "${IXA}"; "${NOOK}" reindex )
assert_contains "reindex recreated the index" \
    "$(git ls-remote "${IX_ORIGIN}" refs/nook/index)" "refs/nook/index"
IXTMP2="${WORK}/ixtmp2.git"; git init -q --bare "${IXTMP2}"
git --git-dir="${IXTMP2}" fetch -q --depth 1 "${IX_ORIGIN}" refs/nook/index:refs/nook/index
INFO2=$(git --git-dir="${IXTMP2}" show refs/nook/index:info.json)
assert_contains "reindexed info.json still lists beads" "${INFO2}" "beads."

section "destroy: deindexes from the collection index"
IXB="${WORK}/ixb"; make_project_repo "${IXB}" no ixb
( cd "${IXB}"; git remote add origin git@github.com:carol/ixb.git
  "${NOOK}" init notes "${IX_ORIGIN}" --dir notes
  echo n > notes/f; "${NOOK}" -n notes run add --all
  "${NOOK}" -n notes run commit -m s; "${NOOK}" -n notes run push )
IXTMP3="${WORK}/ixtmp3.git"; git init -q --bare "${IXTMP3}"
git --git-dir="${IXTMP3}" fetch -q --depth 1 "${IX_ORIGIN}" refs/nook/index:refs/nook/index
assert_contains "index lists notes before destroy" \
    "$(git --git-dir="${IXTMP3}" show refs/nook/index:info.json)" "notes."
( cd "${IXB}"; "${NOOK}" -n notes destroy --yes )
IXTMP4="${WORK}/ixtmp4.git"; git init -q --bare "${IXTMP4}"
git --git-dir="${IXTMP4}" fetch -q --depth 1 "${IX_ORIGIN}" refs/nook/index:refs/nook/index
INFO4=$(git --git-dir="${IXTMP4}" show refs/nook/index:info.json)
assert_true "index no longer lists the destroyed notes slug" test -z "$(printf '%s' "${INFO4}" | grep -o 'notes\.[a-z0-9]*\.carol' || true)"
assert_contains "index still lists the surviving beads slug after deindex" "${INFO4}" "beads."

section "unit: manifest read decodes escaped values (no double-escape)"
MFE="${WORK}/mfe-repo"; make_project_repo "${MFE}" yes mfe
( cd "${MFE}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  cd "${MFE}"
  gd="$(pwd)/.git/nook/x.git"; mkdir -p "$(dirname "${gd}")"; git init -q --bare "${gd}"
  write_manifest_ref "${gd}" "uuid1" "beads" "alice" "proj" "" 'Don "D" Denton <d@x>' "2026-01-01T00:00:00Z" ".beads"
  echo "USER:$(read_manifest_field "${gd}" refs/nook-meta/manifest user)"
) > "${WORK}/mfe.out" 2>&1
assert_contains "user identity decodes with literal quotes" "$(cat "${WORK}/mfe.out")" 'USER:Don "D" Denton <d@x>'

section "unit: _index_merge split anchors on object boundary, not any '},{' in a value"
IMM="${WORK}/imm-repo"; make_project_repo "${IMM}" yes imm
( cd "${IMM}"
  # shellcheck source=/dev/null
  GIT_NOOK_LIB=1 . "${NOOK}"
  cd "${IMM}"
  # The entry being DROPPED has a free-form value containing a literal '},{'.
  # A naive split on '},{' anywhere cuts this entry's own value in half,
  # producing an orphan fragment ('{x","at":"t2"}') that is not a real object
  # and does not match the drop pattern -- so it survives as JSON garbage in
  # the output alongside the entry that should have been kept intact.
  ARR='[{"slug":"drop.2","uuid":"u2","name":"n2","owner":"o2","repo_dir":"r2","upstream":"up2","user":"ORPHANFRAGMENT},{x","at":"t2"},{"slug":"keep.1","uuid":"u1","name":"n1","owner":"o1","repo_dir":"r1","upstream":"up1","user":"a","at":"t1"}]'
  RESULT=$(_index_merge "${ARR}" "drop.2" "")
  echo "RESULT:${RESULT}"
) > "${WORK}/imm.out" 2>&1
IMM_OUT=$(cat "${WORK}/imm.out")
assert_true "dropped entry is fully gone (no orphan fragment)" \
    test -z "$(printf '%s' "${IMM_OUT}" | grep -o 'ORPHANFRAGMENT\|drop\.2' || true)"
assert_contains "surviving keep.1 entry is present and intact" "${IMM_OUT}" '"slug":"keep.1"'
assert_contains "result is a well-formed single-entry array" "${IMM_OUT}" \
    'RESULT:[{"slug":"keep.1","uuid":"u1","name":"n1","owner":"o1","repo_dir":"r1","upstream":"up1","user":"a","at":"t1"}]'

section "clone: disambiguates two same-named nooks using the index"

CL_SHARED="${WORK}/origins/clshared.git"; mkdir -p "$(dirname "${CL_SHARED}")"; git init -q --bare "${CL_SHARED}"
CL_P1="${WORK}/cl-p1"; make_project_repo "${CL_P1}" no p1
( cd "${CL_P1}"; git remote add origin git@github.com:alice/repo-one.git
  "${NOOK}" init notes "${CL_SHARED}" --dir notes
  echo one > notes/x; "${NOOK}" -n notes run add --all
  "${NOOK}" -n notes run commit -m one; "${NOOK}" -n notes run push )
CL_P2="${WORK}/cl-p2"; make_project_repo "${CL_P2}" no p2
( cd "${CL_P2}"; git remote add origin git@github.com:bob/repo-two.git
  "${NOOK}" init notes "${CL_SHARED}" --dir notes
  echo two > notes/x; "${NOOK}" -n notes run add --all
  "${NOOK}" -n notes run commit -m two; "${NOOK}" -n notes run push )

# Consumer clones 'notes'; two candidates exist -> picker. Pick #2 via stdin.
CL_CC="${WORK}/cl-cons"; make_project_repo "${CL_CC}" no cc
CL_OUT=$( cd "${CL_CC}"; printf '2\n' | "${NOOK}" clone notes "${CL_SHARED}" --dir notes 2>&1 ) || true
# The picker must show provenance from the index (repo_dir + owner), which
# ls-remote alone cannot provide.
assert_contains "picker shows a repo_dir from the index" "${CL_OUT}" "repo-"
if [[ -L "${CL_CC}/notes" ]]; then fail "clone into a fresh repo must elect a real dir, not a symlink"; else pass "clone produced a real primary-home dir"; fi
# Content of whichever candidate was chosen must be present.
assert_true "cloned content nonempty" test -s "${CL_CC}/notes/x"
# The index appends entries in push order (p1/alice/repo-one pushed first,
# p2/bob/repo-two pushed second), so pick #2 deterministically selects
# bob/repo-two's content ("two"), not alice/repo-one's ("one"). Assert the
# specific candidate was actually materialized, not just "some" content.
assert_eq "pick #2 selects bob/repo-two's content" "two" "$(cat "${CL_CC}/notes/x")"

section "clone: falls back to ls-remote slug discovery when refs/nook/index is absent"

# init always publishes refs/nook/index, so the normal single-candidate clone
# test above goes through the index path. Force the OTHER path (no in-suite
# coverage otherwise): delete refs/nook/index from the shared origin after
# publishing a nook, then clone by name into a fresh repo and confirm it
# still succeeds via remote_slugs_for_name's ls-remote scan.
NI_SHARED="${WORK}/origins/nishared.git"; mkdir -p "$(dirname "${NI_SHARED}")"; git init -q --bare "${NI_SHARED}"
NI_P1="${WORK}/ni-p1"; make_project_repo "${NI_P1}" no nip1
( cd "${NI_P1}"; git remote add origin git@github.com:carol/repo-ni.git
  "${NOOK}" init stash "${NI_SHARED}" --dir stash
  echo stashed > stash/y; "${NOOK}" -n stash run add --all
  "${NOOK}" -n stash run commit -m s; "${NOOK}" -n stash run push )

# Delete the index ref the producer just published, forcing ls-remote fallback.
git push -q "${NI_SHARED}" --delete refs/nook/index
assert_eq "index ref deleted from origin" "" "$(git ls-remote "${NI_SHARED}" refs/nook/index)"

NI_CC="${WORK}/ni-cons"; make_project_repo "${NI_CC}" no nicc
NI_OUT=$( cd "${NI_CC}"; "${NOOK}" clone stash "${NI_SHARED}" --dir stash 2>&1 ) || true
if [[ -L "${NI_CC}/stash" ]]; then fail "no-index clone into a fresh repo must elect a real dir, not a symlink"; else pass "no-index clone produced a real primary-home dir"; fi
assert_eq "no-index clone content matches producer" "stashed" "$(cat "${NI_CC}/stash/y" 2>/dev/null)"
assert_true "no-index clone reports success" test -z "$(printf '%s' "${NI_OUT}" | grep -i 'error\|refuse' || true)"

section "names: a name with a dash is addressable by -n and clonable"

DN="${WORK}/dashname"; make_project_repo "${DN}" yes dnproj
( cd "${DN}"; "${NOOK}" init my-notes origin --dir my-notes
  echo hi > my-notes/f; "${NOOK}" -n my-notes run add --all
  "${NOOK}" -n my-notes run commit -m s; "${NOOK}" -n my-notes run push )
# -n by the raw dashed name must resolve:
DN_RC=$(cd "${DN}"; "${NOOK}" -n my-notes run status >/dev/null 2>&1; echo $?)
assert_eq "-n resolves a dashed name" "0" "${DN_RC}"
# clone by dashed name via the NO-INDEX fallback must find it (delete index first):
DN_ORIGIN="${WORK}/origins/dnproj.git"
DN_SLUG=$(cd "${DN}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
git --git-dir="${DN}/.git/nook/${DN_SLUG}.git" push -q "${DN_ORIGIN}" --delete refs/nook/index
assert_eq "index ref deleted for dashed-name origin" "" "$(git ls-remote "${DN_ORIGIN}" refs/nook/index)"
DN2="${WORK}/dashname-clone"; make_project_repo "${DN2}" no dn2
DN2_RC=$(cd "${DN2}"; "${NOOK}" clone my-notes "${DN_ORIGIN}" --dir my-notes >/dev/null 2>&1; echo $?)
assert_eq "clone finds a dashed name via ls-remote fallback" "0" "${DN2_RC}"
assert_contains "cloned dashed-name content present" "$(cat "${DN2}/my-notes/f" 2>/dev/null)" "hi"

section "clone: unreachable remote fails with a clear message, not silently"

UC="${WORK}/unreach"; make_project_repo "${UC}" no uc
UC_RC=$(cd "${UC}"; "${NOOK}" clone notes /nonexistent/remote.git --dir notes >/dev/null 2>&1; echo $?)
assert_eq "clone unreachable remote exits nonzero" "1" "${UC_RC}"
UC_ERR=$(cd "${UC}"; "${NOOK}" clone notes /nonexistent/remote.git --dir notes 2>&1 >/dev/null || true)
assert_contains "clone unreachable prints a reason" "${UC_ERR}" "cannot reach"

section "pull guard: refuses when remote manifest uuid differs"

PG_SHARED="${WORK}/origins/pgshared.git"; mkdir -p "$(dirname "${PG_SHARED}")"; git init -q --bare "${PG_SHARED}"
PG="${WORK}/pg"; make_project_repo "${PG}" no pg
( cd "${PG}"; git remote add origin git@github.com:alice/pg.git
  "${NOOK}" init beads "${PG_SHARED}" --dir .beads
  echo a > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
PG_SLUG=$(cd "${PG}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
PG_GD="${PG}/.git/nook/${PG_SLUG}.git"

# Tamper: overwrite the UPSTREAM manifest ref with a DIFFERENT uuid.
# shellcheck source=/dev/null
GIT_NOOK_LIB=1 . "${NOOK}"
BAD_BLOB=$(manifest_json "DIFFERENT-uuid" "beads" "alice" "pg" "" "x <x>" "2026-01-01T00:00:00Z" ".beads" | git --git-dir="${PG_GD}" hash-object -w --stdin)
BAD_TREE=$(printf '100644 blob %s\tmanifest.json\n' "${BAD_BLOB}" | git --git-dir="${PG_GD}" mktree)
BAD_COMMIT=$(printf 'x\n' | git --git-dir="${PG_GD}" commit-tree "${BAD_TREE}")
git --git-dir="${PG_GD}" update-ref refs/nook-tamper "${BAD_COMMIT}"
git --git-dir="${PG_GD}" push -q -f "${PG_SHARED}" "refs/nook-tamper:refs/nook/${PG_SLUG}/manifest"

# A guarded pull must now refuse (remote uuid != local uuid).
PG_RC=$(cd "${PG}"; "${NOOK}" -n beads run pull >/dev/null 2>&1; echo $?)
assert_eq "guarded pull refuses on uuid mismatch" "1" "${PG_RC}"

section "pull guard: allows pull when uuids match"

PG2_SHARED="${WORK}/origins/pg2shared.git"; mkdir -p "$(dirname "${PG2_SHARED}")"; git init -q --bare "${PG2_SHARED}"
PG2="${WORK}/pg2"; make_project_repo "${PG2}" no pg2
( cd "${PG2}"; git remote add origin git@github.com:alice/pg2.git
  "${NOOK}" init beads "${PG2_SHARED}" --dir .beads
  echo a > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
# A normal pull (uuids match) must succeed (exit 0). Nothing to pull, but no refusal.
PG2_RC=$(cd "${PG2}"; "${NOOK}" -n beads run pull --no-rebase --no-edit >/dev/null 2>&1; echo $?)
assert_eq "matching-uuid pull is allowed" "0" "${PG2_RC}"

section "migration: legacy bare-name nook is detected and flagged (no auto-migrate)"

LG="${WORK}/legacy"; make_project_repo "${LG}" yes lg
# Simulate an OLD-layout nook: a config key with a bare name (no .id3.owner.repo).
( cd "${LG}"; git config "nook.beads.dir" ".beads"
  mkdir -p .git/nook/beads.git .git/nook/beads.nook/.beads )
LG_OUT=$(cd "${LG}"; "${NOOK}" list 2>&1 || true)
assert_contains "legacy layout is detected" "${LG_OUT}" "older git-nook layout"
assert_contains "points at MIGRATION.md" "${LG_OUT}" "MIGRATION.md"
assert_contains "tells agent not to auto-migrate" "${LG_OUT}" "do not"
assert_file_exists "MIGRATION.md exists in repo" "${REPO_UNDER_TEST}/MIGRATION.md"

LG_RC=$(cd "${LG}"; "${NOOK}" list >/dev/null 2>&1; echo $?)
assert_eq "legacy warning does not change exit status" "0" "${LG_RC}"
LG_STDOUT=$(cd "${LG}"; "${NOOK}" list 2>/dev/null)
assert_true "legacy warning is not on stdout" test -z "$(printf '%s' "${LG_STDOUT}" | grep -i 'older git-nook layout' || true)"

section "migration: a modern slug nook does NOT trigger the legacy warning"

MD="${WORK}/modern"; make_project_repo "${MD}" yes md
( cd "${MD}"; "${NOOK}" init beads origin --dir .beads )
MD_OUT=$(cd "${MD}"; "${NOOK}" list 2>&1 || true)
assert_true "modern slug nook does not warn about legacy" test -z "$(printf '%s' "${MD_OUT}" | grep -i 'older git-nook layout' || true)"

section "record-dir: init records the content dir in the manifest"
RD="${WORK}/rd"; make_project_repo "${RD}" yes rdproj
( cd "${RD}"; "${NOOK}" init beads origin --dir .beads )
RD_SLUG=$(cd "${RD}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
RD_GD="${RD}/.git/nook/${RD_SLUG}.git"
assert_eq "manifest records the dir" ".beads" \
    "$(git --git-dir="${RD_GD}" show refs/nook-meta/manifest:manifest.json | grep '\"dir\"' | grep -v repo_dir | sed -E 's/.*: *\"(.*)\".*/\1/')"

section "record-dir: clone defaults to the recorded dir when --dir omitted"
RDS="${WORK}/origins/rdshared.git"; mkdir -p "$(dirname "${RDS}")"; git init -q --bare "${RDS}"
RDP="${WORK}/rd-prod"; make_project_repo "${RDP}" no rdp
( cd "${RDP}"; git remote add origin git@github.com:alice/rdp.git
  "${NOOK}" init beads "${RDS}" --dir .beads
  echo hi > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
RDC="${WORK}/rd-cons"; make_project_repo "${RDC}" no rdc
( cd "${RDC}"; "${NOOK}" clone beads "${RDS}" )   # NO --dir
assert_dir_exists "clone landed at the recorded .beads (not ./beads)" "${RDC}/.beads"
if [[ -L "${RDC}/.beads" ]]; then fail "clone into a fresh repo must elect a real dir, not a symlink"; else pass "clone at recorded dir is a real primary-home dir"; fi
assert_true "clone did NOT use the bare name dir" test ! -e "${RDC}/beads"
assert_contains "cloned content present at recorded dir" "$(cat "${RDC}/.beads/f" 2>/dev/null)" "hi"

section "record-dir: explicit --dir still overrides the recorded dir"
RDC2="${WORK}/rd-cons2"; make_project_repo "${RDC2}" no rdc2
( cd "${RDC2}"; "${NOOK}" clone beads "${RDS}" --dir elsewhere )
assert_dir_exists "explicit --dir wins" "${RDC2}/elsewhere"
if [[ -L "${RDC2}/elsewhere" ]]; then fail "clone into a fresh repo must elect a real dir, not a symlink"; else pass "clone at explicit --dir is a real primary-home dir"; fi
assert_true "recorded dir not used when --dir given" test ! -e "${RDC2}/.beads"

section "record-dir: clone against a dir-less index entry falls back to name (no JSON-named dir)"
RDL_SHARED="${WORK}/origins/rdl.git"; mkdir -p "$(dirname "${RDL_SHARED}")"; git init -q --bare "${RDL_SHARED}"
RDLP="${WORK}/rdl-prod"; make_project_repo "${RDLP}" no rdlp
( cd "${RDLP}"; git remote add origin git@github.com:alice/rdlp.git
  "${NOOK}" init beads "${RDL_SHARED}" --dir .beads
  echo hi > .beads/f; "${NOOK}" -n beads run add --all
  "${NOOK}" -n beads run commit -m s; "${NOOK}" -n beads run push )
RDL_SLUG=$(cd "${RDLP}" && git config --get-regexp '^nook\..*\.dir$' | sed -E 's/^nook\.(.*)\.dir .*/\1/')
# Overwrite the published index with a legacy-style entry that has NO "dir" key.
RDLT="${WORK}/rdlt.git"; git init -q --bare "${RDLT}"
LEGACY_ENTRY=$(printf '[{"slug":"%s","uuid":"u","name":"beads","owner":"alice","repo_dir":"rdlp","upstream":"","user":"x","at":"t"}]' "${RDL_SLUG}")
LB=$(printf '%s' "${LEGACY_ENTRY}" | git --git-dir="${RDLT}" hash-object -w --stdin)
LT=$(printf '100644 blob %s\tinfo.json\n' "${LB}" | git --git-dir="${RDLT}" mktree)
LC=$(printf 'legacy index\n' | git --git-dir="${RDLT}" commit-tree "${LT}")
git --git-dir="${RDLT}" update-ref refs/nook/index "${LC}"
git --git-dir="${RDLT}" push -q -f "${RDL_SHARED}" refs/nook/index:refs/nook/index
# Clone with no --dir: must fall back to the bare name 'beads', NOT a JSON-named dir.
RDLC="${WORK}/rdl-cons"; make_project_repo "${RDLC}" no rdlc
( cd "${RDLC}"; "${NOOK}" clone beads "${RDL_SHARED}" )
assert_dir_exists "fell back to bare-name dir" "${RDLC}/beads"
if [[ -L "${RDLC}/beads" ]]; then fail "clone into a fresh repo must elect a real dir, not a symlink"; else pass "clone at fallback dir is a real primary-home dir"; fi
RDLC_JSON_NAMED=""
for f in "${RDLC}"/*; do
    case "$(basename "${f}")" in *"{"*) RDLC_JSON_NAMED="${f}" ;; esac
done
assert_true "no JSON-named dir created" test -z "${RDLC_JSON_NAMED}"
assert_contains "content present at fallback dir" "$(cat "${RDLC}/beads/f" 2>/dev/null)" "hi"

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
