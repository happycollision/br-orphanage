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
assert_contains "installer always documents the full-path fallback" "${INSTALL_OUT}" "by full path"
assert_contains "fallback names the wrapper's full path" "${INSTALL_OUT}" "${INSTALLED_BR}"

REINSTALL_OUT=$("${REPO_UNDER_TEST}/install.sh")
assert_contains "re-install does not duplicate the rc line" "${REINSTALL_OUT}" "already configured"
RC_LINE_COUNT=$(grep -cF "# br-orphanage" "${FAKE_HOME}/.bashrc" || true)
assert_eq "exactly one marked PATH line after two installs" "1" "${RC_LINE_COUNT}"

section "install.sh: non-interactive zsh resolves 'br' to the wrapper (PATH shadowing)"

# A typical zsh user has ~/.zshrc. The installer must guarantee that even a
# NON-interactive zsh (agent tool calls, scripts, cron, CI) resolves 'br' to
# the wrapper. Non-interactive zsh sources ~/.zshenv but NOT ~/.zshrc, so a
# PATH line placed only in ~/.zshrc leaves the real binary shadowing us there.
if command -v zsh >/dev/null 2>&1; then
    touch "${FAKE_HOME}/.zshrc"
    "${REPO_UNDER_TEST}/install.sh" >/dev/null

    # Clean PATH: real br present, wrapper dir absent — only the installer's
    # shell config can put the wrapper ahead of the real binary. `env -i` keeps
    # the harness's own (wrapper-prepended) PATH and any ZDOTDIR from leaking in.
    NONINT_BR=$(env -i HOME="${FAKE_HOME}" PATH="${REAL_BR_DIR}:/usr/bin:/bin" \
        zsh -c 'command -v br' 2>/dev/null || true)
    assert_eq "non-interactive zsh resolves br to the installed wrapper" \
        "$(readlink -f "${INSTALLED_BR}")" "$(readlink -f "${NONINT_BR}" 2>/dev/null)"

    # Interactive zsh must keep working too (regression guard).
    INT_BR=$(env -i HOME="${FAKE_HOME}" PATH="${REAL_BR_DIR}:/usr/bin:/bin" \
        zsh -i -c 'command -v br' 2>/dev/null || true)
    assert_eq "interactive zsh still resolves br to the installed wrapper" \
        "$(readlink -f "${INSTALLED_BR}")" "$(readlink -f "${INT_BR}" 2>/dev/null)"
else
    echo "  zsh not installed; skipping non-interactive zsh PATH check."
fi

section "install.sh: unrecognized shell gets manual PATH guidance"

# A shell we don't auto-configure (fish, nushell, ...) with no bash/zsh rc files
# to piggyback on: nothing is written, so the installer must instead PRINT the
# manual PATH line, name the shell, and offer the full-path fallback.
FISH_HOME="${WORK}/home-fish"
mkdir -p "${FISH_HOME}"
FISH_BIN="${FISH_HOME}/.local/share/br-orphanage/bin/br"
FISH_OUT=$(env HOME="${FISH_HOME}" XDG_DATA_HOME="${FISH_HOME}/.local/share" \
    SHELL=/opt/fish "${REPO_UNDER_TEST}/install.sh")
assert_contains "guidance names the unconfigured shell" "${FISH_OUT}" "fish"
assert_contains "guidance gives the manual PATH export line" "${FISH_OUT}" \
    "export PATH=\"${FISH_HOME}/.local/share/br-orphanage/bin"
assert_contains "guidance offers the full-path fallback" "${FISH_OUT}" "by full path"
assert_contains "fallback names the wrapper's full path" "${FISH_OUT}" "${FISH_BIN}"
assert_file_absent "unrecognized shell: no ~/.zshenv written" "${FISH_HOME}/.zshenv"

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

# --- orphanage namespace: version, usage, alias, unknown subcommand -------------

section "br orphanage: version, usage, 'br o' alias, unknown subcommand"

SRC_VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${REPO_UNDER_TEST}/bin/br" | head -n 1)
if [[ -n "${SRC_VERSION}" ]]; then
    pass "bin/br declares a VERSION (${SRC_VERSION})"
else
    fail "bin/br has no VERSION= line"
fi

ORPH_VERSION_OUT=$(br orphanage --version)
assert_eq "'br orphanage --version' prints the wrapper version" \
    "br-orphanage ${SRC_VERSION}" "${ORPH_VERSION_OUT}"

O_VERSION_OUT=$(br o --version)
assert_eq "'br o --version' matches 'br orphanage --version'" \
    "${ORPH_VERSION_OUT}" "${O_VERSION_OUT}"

BARE_ORPH_OUT=$(br orphanage)
assert_contains "bare 'br orphanage' prints usage" "${BARE_ORPH_OUT}" "Usage:"
assert_contains "bare 'br orphanage' includes the version" "${BARE_ORPH_OUT}" "${SRC_VERSION}"

set +e
UNKNOWN_OUT=$(br orphanage frobnicate 2>&1)
UNKNOWN_EXIT=$?
set -e
if [[ "${UNKNOWN_EXIT}" -ne 0 ]]; then
    pass "'br orphanage frobnicate' exits nonzero (${UNKNOWN_EXIT})"
else
    fail "'br orphanage frobnicate' unexpectedly exited 0"
fi
assert_contains "unknown subcommand names the offender" "${UNKNOWN_OUT}" "unknown subcommand 'frobnicate'"

# --- bare 'br init' passes through UNMODIFIED ------------------------------------

section "bare 'br init' passes through to the real binary unmodified"

BAREINIT_PROJ="${WORK}/proj-bare-init"
make_project_repo "${BAREINIT_PROJ}" yes "bare-init-demo"
printf 'node_modules/\n' > "${BAREINIT_PROJ}/.gitignore"

(cd "${BAREINIT_PROJ}" && br init -q)

assert_dir_exists "real init created .beads/" "${BAREINIT_PROJ}/.beads"
BAREINIT_EXCLUDE=$(abs_git_path "${BAREINIT_PROJ}" info/exclude)
if grep -qxF '.beads/' "${BAREINIT_EXCLUDE}" 2>/dev/null; then
    fail "bare 'br init' wrongly added '.beads/' to info/exclude (legacy interception still active)"
else
    pass "bare 'br init' did NOT touch info/exclude"
fi

# Bare 'br sync' is the real binary's own command: passthrough, no git traffic.
(cd "${BAREINIT_PROJ}" && br sync >/dev/null)
pass "bare 'br sync' passes through without error"
BAREINIT_ORIGIN_REFS=$(git -C "${WORK}/origins/bare-init-demo.git" for-each-ref --format='%(refname)' refs/heads)
if [[ "${BAREINIT_ORIGIN_REFS}" == *orphanage* ]]; then
    fail "bare 'br sync' unexpectedly created an orphan branch at the origin"
else
    pass "bare 'br sync' produced no git traffic (no orphan branch at origin)"
fi

# --- br orphanage target: set, print, resolve, validate --------------------------

section "br orphanage target: unset -> exit 1 with guidance"

TGT_PROJ="${WORK}/proj-target"
make_project_repo "${TGT_PROJ}" yes "target-demo"

set +e
TGT_UNSET_OUT=$(cd "${TGT_PROJ}" && br orphanage target 2>&1)
TGT_UNSET_EXIT=$?
set -e
if [[ "${TGT_UNSET_EXIT}" -ne 0 ]]; then
    pass "unset target exits nonzero (${TGT_UNSET_EXIT})"
else
    fail "unset target unexpectedly exited 0"
fi
assert_contains "unset target names the fix" "${TGT_UNSET_OUT}" "br orphanage target <remote-or-url>"

section "br orphanage target: set by remote name, resolved at print time"

(cd "${TGT_PROJ}" && br orphanage target origin)
STORED_TGT=$(git -C "${TGT_PROJ}" config --get beadsOrphanage.target)
assert_eq "stored config value is the remote name" "origin" "${STORED_TGT}"

TGT_PRINT_OUT=$(cd "${TGT_PROJ}" && br orphanage target)
TGT_ORIGIN_URL=$(git -C "${TGT_PROJ}" remote get-url origin)
assert_contains "print shows the resolved URL" "${TGT_PRINT_OUT}" "url:    ${TGT_ORIGIN_URL}"
# origin URL is $WORK/origins/target-demo.git -> owner=origins project=target-demo
assert_contains "print shows the default templated branch" "${TGT_PRINT_OUT}" "branch: orphanage/origins/target-demo"

section "br orphanage target: set by URL, template overrides, validation"

EXT_TARGET_BARE="${WORK}/targets/external-issues.git"
mkdir -p "$(dirname "${EXT_TARGET_BARE}")"
git init -q --bare "${EXT_TARGET_BARE}"

(cd "${TGT_PROJ}" && br orphanage target "${EXT_TARGET_BARE}")
STORED_TGT2=$(git -C "${TGT_PROJ}" config --get beadsOrphanage.target)
assert_eq "URL target stored literally" "${EXT_TARGET_BARE}" "${STORED_TGT2}"

(cd "${TGT_PROJ}" && br orphanage target --namespace beads --branch '<namespace>/only-<project>')
TGT_PRINT_OUT2=$(cd "${TGT_PROJ}" && br orphanage target)
assert_contains "custom template + namespace resolve in print" "${TGT_PRINT_OUT2}" "branch: beads/only-target-demo"
# Reset overrides for later tasks.
git -C "${TGT_PROJ}" config --unset beadsOrphanage.branch
git -C "${TGT_PROJ}" config --unset beadsOrphanage.namespace

set +e
BADREMOTE_OUT=$(cd "${TGT_PROJ}" && br orphanage target upstream 2>&1)
BADREMOTE_EXIT=$?
set -e
if [[ "${BADREMOTE_EXIT}" -ne 0 ]]; then
    pass "nonexistent remote name rejected (${BADREMOTE_EXIT})"
else
    fail "nonexistent remote name unexpectedly accepted"
fi
assert_contains "rejection names the missing remote" "${BADREMOTE_OUT}" "upstream"

section "br orphanage target: slash-in-remote-name resolves as a remote, not a URL"

(cd "${TGT_PROJ}" && git remote add fork/thing "${EXT_TARGET_BARE}")
(cd "${TGT_PROJ}" && br orphanage target fork/thing)
SLASH_PRINT=$(cd "${TGT_PROJ}" && br orphanage target)
assert_contains "slash-named remote resolves to its URL at print time" \
    "${SLASH_PRINT}" "url:    ${EXT_TARGET_BARE}"
# Restore prior state (URL target, no extra remote) for later sections.
(cd "${TGT_PROJ}" && br orphanage target "${EXT_TARGET_BARE}")
git -C "${TGT_PROJ}" remote remove fork/thing

section "br orphanage target: argument validation edge cases"

set +e
EXTRA_OUT=$(cd "${TGT_PROJ}" && br orphanage target origin bogus-extra 2>&1)
EXTRA_EXIT=$?
set -e
if [[ "${EXTRA_EXIT}" -ne 0 ]]; then
    pass "extra positional argument rejected (${EXTRA_EXIT})"
else
    fail "extra positional argument unexpectedly accepted"
fi
assert_contains "extra positional names the problem" "${EXTRA_OUT}" "unexpected extra argument"

set +e
OPTVAL_OUT=$(cd "${TGT_PROJ}" && br orphanage target --branch --namespace 2>&1)
OPTVAL_EXIT=$?
set -e
if [[ "${OPTVAL_EXIT}" -ne 0 ]]; then
    pass "option-looking --branch value rejected (${OPTVAL_EXIT})"
else
    fail "option-looking --branch value unexpectedly accepted"
fi
assert_contains "rejection says --branch requires a value" "${OPTVAL_OUT}" "--branch requires a value"
if git -C "${TGT_PROJ}" config --get beadsOrphanage.branch >/dev/null 2>&1; then
    fail "beadsOrphanage.branch wrongly set after rejected --branch"
else
    pass "beadsOrphanage.branch left unset after rejected --branch"
fi

section "br orphanage target: invalid resolved branch name rejected at print time"

(cd "${TGT_PROJ}" && br orphanage target --branch 'bad branch')
set +e
BADBRANCH_OUT=$(cd "${TGT_PROJ}" && br orphanage target 2>&1)
BADBRANCH_EXIT=$?
set -e
if [[ "${BADBRANCH_EXIT}" -ne 0 ]]; then
    pass "invalid resolved branch name rejected (${BADBRANCH_EXIT})"
else
    fail "invalid resolved branch name unexpectedly accepted"
fi
assert_contains "invalid branch error names the problem" "${BADBRANCH_OUT}" "not a valid git branch name"
# Restore for later tasks.
git -C "${TGT_PROJ}" config --unset beadsOrphanage.branch

section "br orphanage target: fallbacks with no origin remote"

NOORIGIN_TGT_PROJ="${WORK}/proj-target-no-origin"
make_project_repo "${NOORIGIN_TGT_PROJ}" no
NOORIGIN_BARE="${WORK}/targets/no-origin-target.git"
git init -q --bare "${NOORIGIN_BARE}"
(cd "${NOORIGIN_TGT_PROJ}" && br orphanage target "${NOORIGIN_BARE}")
NOORIGIN_PRINT=$(cd "${NOORIGIN_TGT_PROJ}" && br orphanage target)
NOORIGIN_DIRNAME=$(basename "${NOORIGIN_TGT_PROJ}")
assert_contains "no-origin fallback branch is orphanage/local/<dirname>" \
    "${NOORIGIN_PRINT}" "branch: orphanage/local/${NOORIGIN_DIRNAME}"

# --- br orphanage init: gitignore preservation, exclude entry, --target ----------

section "br orphanage init: pre-existing .gitignore is byte-identical afterward"

OINIT1="${WORK}/proj-oinit-gitignore"
make_project_repo "${OINIT1}" yes "oinit-gitignore"
printf 'node_modules/\n*.log\n' > "${OINIT1}/.gitignore"
cp "${OINIT1}/.gitignore" "${WORK}/oinit-gitignore-snapshot"

(cd "${OINIT1}" && br orphanage init -q)

if cmp -s "${WORK}/oinit-gitignore-snapshot" "${OINIT1}/.gitignore"; then
    pass ".gitignore byte-identical after 'br orphanage init'"
else
    fail ".gitignore CHANGED after 'br orphanage init'"
fi

section "br orphanage init: no .gitignore before -> none after; exclude idempotent"

OINIT2="${WORK}/proj-oinit-clean"
make_project_repo "${OINIT2}" yes "oinit-clean"

(cd "${OINIT2}" && br orphanage init -q)

assert_file_absent "no .gitignore created" "${OINIT2}/.gitignore"
assert_dir_exists ".beads/ created" "${OINIT2}/.beads"
OINIT2_EXCLUDE=$(abs_git_path "${OINIT2}" info/exclude)
count_oinit2_excl() { grep -cxF '.beads/' "${OINIT2_EXCLUDE}" 2>/dev/null || true; }
assert_eq "exclude has exactly one '.beads/' line" "1" "$(count_oinit2_excl)"

# Repeat init (real br needs --force on an initialized workspace).
(cd "${OINIT2}" && br orphanage init -q --force)
(cd "${OINIT2}" && br orphanage init -q --force)
assert_eq "still exactly one '.beads/' line after repeated forced inits" "1" "$(count_oinit2_excl)"
assert_file_absent "still no .gitignore after repeated inits" "${OINIT2}/.gitignore"

section "br orphanage init: double init without --force fails like the real binary"

set +e
(cd "${OINIT2}" && br orphanage init -q >/dev/null 2>&1)
DBLINIT_WRAPPER_EXIT=$?
(cd "${OINIT2}" && "${REAL_BR_RESOLVED}" init -q >/dev/null 2>&1)
DBLINIT_REAL_EXIT=$?
set -e
if [[ "${DBLINIT_WRAPPER_EXIT}" -ne 0 ]]; then
    pass "double init without --force exits nonzero (${DBLINIT_WRAPPER_EXIT})"
else
    fail "double init without --force unexpectedly exited 0"
fi
assert_eq "wrapper double-init exit code matches the real binary's" \
    "${DBLINIT_REAL_EXIT}" "${DBLINIT_WRAPPER_EXIT}"
assert_eq "exclude still has exactly one '.beads/' line after failed double init" "1" "$(count_oinit2_excl)"

section "br orphanage init --target: inline target set"

OINIT3="${WORK}/proj-oinit-target"
make_project_repo "${OINIT3}" yes "oinit-target"

(cd "${OINIT3}" && br orphanage init -q --target origin)

OINIT3_TGT=$(git -C "${OINIT3}" config --get beadsOrphanage.target)
assert_eq "--target stored in git config" "origin" "${OINIT3_TGT}"
assert_dir_exists "--target didn't break the real init" "${OINIT3}/.beads"

section "br orphanage init --target: failing target still leaves a successful init"

OINIT4="${WORK}/proj-oinit-badtarget"
make_project_repo "${OINIT4}" yes "oinit-badtarget"

set +e
BADTGT_OUT=$(cd "${OINIT4}" && br orphanage init -q --target bogus-nonexistent 2>&1)
BADTGT_EXIT=$?
set -e
if [[ "${BADTGT_EXIT}" -ne 0 ]]; then
    pass "failing --target exits nonzero (${BADTGT_EXIT})"
else
    fail "failing --target unexpectedly exited 0"
fi
assert_contains "output notes init succeeded but target was not set" "${BADTGT_OUT}" "init succeeded"
assert_dir_exists "real init still completed (.beads/ exists)" "${OINIT4}/.beads"
if git -C "${OINIT4}" config --get beadsOrphanage.target >/dev/null 2>&1; then
    fail "beadsOrphanage.target wrongly set after rejected --target"
else
    pass "beadsOrphanage.target left unset after rejected --target"
fi

section "br orphanage init: worktree resolves the shared info/exclude"

WT_MAIN="${WORK}/proj-worktree-main"
make_project_repo "${WT_MAIN}" yes "worktree-demo"
WT_LINKED="${WORK}/proj-worktree-linked"
git -C "${WT_MAIN}" worktree add -q -b wt-feature-branch "${WT_LINKED}"

(cd "${WT_LINKED}" && br orphanage init -q)

COMMON_EXCLUDE=$(abs_git_path "${WT_MAIN}" info/exclude)
if grep -qxF '.beads/' "${COMMON_EXCLUDE}" 2>/dev/null; then
    pass "'.beads/' landed in the shared/common info/exclude from a linked worktree"
else
    fail "'.beads/' did NOT land in the shared info/exclude (${COMMON_EXCLUDE})"
fi

# --- br orphanage sync: outbound core --------------------------------------------

INDEX_FILE="${INSTALL_DIR}/project-paths"

section "br orphanage sync: first sync creates the orphan root at the target"

SYNC_PROJ="${WORK}/proj-sync"
make_project_repo "${SYNC_PROJ}" yes "sync-demo"
SYNC_ORIGIN_BARE="${WORK}/origins/sync-demo.git"
(cd "${SYNC_PROJ}" && br orphanage init -q --target origin)
SYNC_ISSUE_ID=$(cd "${SYNC_PROJ}" && br q "orphan roundtrip issue")

SYNC_OUT1=$(cd "${SYNC_PROJ}" && br orphanage sync)
assert_contains "first sync reports success" "${SYNC_OUT1}" "Beads synced for sync-demo"

# Hardcodes the default template resolution (namespace/owner-from-origin-path/
# project); that resolution logic is independently covered by the target tests.
SYNC_BRANCH="orphanage/origins/sync-demo"
SYNC_TIP1=$(git -C "${SYNC_ORIGIN_BARE}" rev-parse "refs/heads/${SYNC_BRANCH}")
if [[ -n "${SYNC_TIP1}" ]]; then
    pass "orphan branch exists at the target (${SYNC_BRANCH})"
else
    fail "orphan branch missing at the target"
fi

PARENT_COUNT=$(git -C "${SYNC_ORIGIN_BARE}" cat-file -p "${SYNC_TIP1}" | grep -c '^parent ' || true)
assert_eq "first sync commit is an orphan root (no parents)" "0" "${PARENT_COUNT}"

SYNC_TREE_LS=$(git -C "${SYNC_ORIGIN_BARE}" ls-tree --name-only "${SYNC_TIP1}")
assert_contains "branch tree contains issues.jsonl" "${SYNC_TREE_LS}" "issues.jsonl"
assert_contains "branch tree contains config.yaml" "${SYNC_TREE_LS}" "config.yaml"
if printf '%s\n' "${SYNC_TREE_LS}" | grep -qx 'beads.db'; then
    fail "beads.db leaked into the branch tree"
else
    pass "beads.db NOT in the branch tree"
fi
REMOTE_ISSUES=$(git -C "${SYNC_ORIGIN_BARE}" show "${SYNC_TIP1}:issues.jsonl")
assert_contains "synced issues.jsonl contains the created issue" "${REMOTE_ISSUES}" "orphan roundtrip issue"

LOCAL_PUSHED=$(git -C "${SYNC_PROJ}" rev-parse refs/orphanage/pushed)
assert_eq "local refs/orphanage/pushed matches the remote tip" "${SYNC_TIP1}" "${LOCAL_PUSHED}"

section "br orphanage sync: index entry, second sync chains, no-op"

assert_file_exists "machine-local index created" "${INDEX_FILE}"
SYNC_PROJ_REAL=$(cd "${SYNC_PROJ}" && pwd -P)
assert_true "index records sync-demo -> its absolute path" \
    grep -qF "$(printf 'sync-demo\t%s' "${SYNC_PROJ_REAL}")" "${INDEX_FILE}"

(cd "${SYNC_PROJ}" && br q "second orphan issue" >/dev/null)
SYNC_OUT2=$(cd "${SYNC_PROJ}" && br orphanage sync)
assert_contains "second sync reports success" "${SYNC_OUT2}" "Beads synced for sync-demo"
SYNC_TIP2=$(git -C "${SYNC_ORIGIN_BARE}" rev-parse "refs/heads/${SYNC_BRANCH}")
SYNC_TIP2_PARENT=$(git -C "${SYNC_ORIGIN_BARE}" rev-parse "${SYNC_TIP2}^")
assert_eq "second sync commit's parent is the first sync commit" "${SYNC_TIP1}" "${SYNC_TIP2_PARENT}"

# The second sync fetched the branch tip as it stood BEFORE committing on top:
# refs/orphanage/fetched == SYNC_TIP1, while refs/orphanage/pushed == SYNC_TIP2.
LOCAL_FETCHED2=$(git -C "${SYNC_PROJ}" rev-parse refs/orphanage/fetched)
assert_eq "refs/orphanage/fetched holds the pre-commit remote tip after second sync" \
    "${SYNC_TIP1}" "${LOCAL_FETCHED2}"
LOCAL_PUSHED2=$(git -C "${SYNC_PROJ}" rev-parse refs/orphanage/pushed)
assert_eq "refs/orphanage/pushed holds the new tip after second sync" \
    "${SYNC_TIP2}" "${LOCAL_PUSHED2}"

INDEX_LINES=$(grep -cF "$(printf 'sync-demo\t')" "${INDEX_FILE}" || true)
assert_eq "re-sync does not duplicate the index entry" "1" "${INDEX_LINES}"

set +e
NOOP_OUT=$(cd "${SYNC_PROJ}" && br orphanage sync 2>&1)
NOOP_EXIT=$?
set -e
assert_eq "no-op sync exits 0" "0" "${NOOP_EXIT}"
assert_contains "no-op sync reports already in sync" "${NOOP_OUT}" "Already in sync for sync-demo"
SYNC_TIP3=$(git -C "${SYNC_ORIGIN_BARE}" rev-parse "refs/heads/${SYNC_BRANCH}")
assert_eq "no-op sync created no new commit" "${SYNC_TIP2}" "${SYNC_TIP3}"

section "br orphanage sync: external (non-origin) target"

EXT_PROJ="${WORK}/proj-sync-external"
make_project_repo "${EXT_PROJ}" yes "sync-external"
EXT_BARE="${WORK}/targets/private-issues.git"
mkdir -p "$(dirname "${EXT_BARE}")"
git init -q --bare "${EXT_BARE}"
(cd "${EXT_PROJ}" && br orphanage init -q --target "${EXT_BARE}")
(cd "${EXT_PROJ}" && br q "external target issue" >/dev/null)
(cd "${EXT_PROJ}" && br orphanage sync >/dev/null)
EXT_BRANCH="orphanage/origins/sync-external"
EXT_ISSUES=$(git -C "${EXT_BARE}" show "refs/heads/${EXT_BRANCH}:issues.jsonl")
assert_contains "issue landed at the external target" "${EXT_ISSUES}" "external target issue"
EXT_ORIGIN_BRANCHES=$(git -C "${WORK}/origins/sync-external.git" for-each-ref --format='%(refname)' refs/heads)
if [[ "${EXT_ORIGIN_BRANCHES}" == *orphanage* ]]; then
    fail "external-target sync leaked an orphan branch to the project's origin"
else
    pass "project origin has no orphan branch (data went only to the external target)"
fi

section "br orphanage sync: errors (unset target, unknown option)"

NOTGT_PROJ="${WORK}/proj-sync-no-target"
make_project_repo "${NOTGT_PROJ}" yes "sync-no-target"
(cd "${NOTGT_PROJ}" && br orphanage init -q)
set +e
NOTGT_OUT=$(cd "${NOTGT_PROJ}" && br orphanage sync 2>&1)
NOTGT_EXIT=$?
set -e
if [[ "${NOTGT_EXIT}" -ne 0 ]]; then
    pass "sync without a target exits nonzero (${NOTGT_EXIT})"
else
    fail "sync without a target unexpectedly exited 0"
fi
assert_contains "unset-target error names the fix" "${NOTGT_OUT}" "br orphanage target <remote-or-url>"

set +e
BOGUS_OUT=$(cd "${SYNC_PROJ}" && br orphanage sync --bogus 2>&1)
BOGUS_EXIT=$?
set -e
if [[ "${BOGUS_EXIT}" -ne 0 ]]; then
    pass "'sync --bogus' exits nonzero (${BOGUS_EXIT})"
else
    fail "'sync --bogus' unexpectedly exited 0"
fi
assert_contains "'sync --bogus' names the unknown option" "${BOGUS_OUT}" "unknown sync option '--bogus'"

# --- Divergence: two machines, one target ----------------------------------------

section "divergence: two clones alternate syncs; issues merge to the union"

# "Machine A" = a project + its origin bare (also the sync target).
DIV_A="${WORK}/proj-div-a"
make_project_repo "${DIV_A}" yes "div-demo"
DIV_BARE="${WORK}/origins/div-demo.git"
# Push code so machine B can clone the project like a real second machine.
git -C "${DIV_A}" push -q origin HEAD:refs/heads/main
(cd "${DIV_A}" && br orphanage init -q --target origin)
(cd "${DIV_A}" && br q "issue from machine A" >/dev/null)
(cd "${DIV_A}" && br orphanage sync >/dev/null)

# "Machine B" = a fresh clone with its own empty workspace (bootstrap-by-init;
# the dedicated bootstrap path is exercised in its own section later).
DIV_B="${WORK}/proj-div-b"
git clone -q "${DIV_BARE}" "${DIV_B}"
(cd "${DIV_B}" && br orphanage init -q --target origin)
(cd "${DIV_B}" && br q "issue from machine B" >/dev/null)
set +e
(cd "${DIV_B}" && br orphanage sync >/dev/null 2>&1)
DIV_B_SYNC_EXIT=$?
set -e
assert_eq "machine B's divergent sync exits 0" "0" "${DIV_B_SYNC_EXIT}"

DIV_BRANCH="orphanage/origins/div-demo"
DIV_REMOTE_ISSUES=$(git -C "${DIV_BARE}" show "refs/heads/${DIV_BRANCH}:issues.jsonl")
assert_contains "union contains machine A's issue" "${DIV_REMOTE_ISSUES}" "issue from machine A"
assert_contains "union contains machine B's issue" "${DIV_REMOTE_ISSUES}" "issue from machine B"

DIV_B_LIST=$(cd "${DIV_B}" && br list)
assert_contains "machine B's DB gained machine A's issue" "${DIV_B_LIST}" "issue from machine A"

# History stayed linear: B's commit has A's commit as parent, no force.
DIV_TIP=$(git -C "${DIV_BARE}" rev-parse "refs/heads/${DIV_BRANCH}")
DIV_TIP_PARENTS=$(git -C "${DIV_BARE}" cat-file -p "${DIV_TIP}" | grep -c '^parent ' || true)
assert_eq "merged commit has exactly one parent (linear history)" "1" "${DIV_TIP_PARENTS}"

section "divergence: A picks up B's issue; deletion propagates via tombstone"

(cd "${DIV_A}" && br orphanage sync >/dev/null)
DIV_A_LIST=$(cd "${DIV_A}" && br list)
assert_contains "machine A's DB gained machine B's issue" "${DIV_A_LIST}" "issue from machine B"

# A deletes its own issue; sync; B syncs; the issue must be gone on B and
# must NOT resurrect on any later sync from either side.
DIV_A_DEL_ID=$(cd "${DIV_A}" && br list --json | jq -r '.issues[] | select(.title | contains("issue from machine A")) | .id' | head -n 1)
(cd "${DIV_A}" && br delete "${DIV_A_DEL_ID}" >/dev/null)
(cd "${DIV_A}" && br orphanage sync >/dev/null)
(cd "${DIV_B}" && br orphanage sync >/dev/null)
DIV_B_LIST2=$(cd "${DIV_B}" && br list)
if [[ "${DIV_B_LIST2}" == *"issue from machine A"* ]]; then
    fail "deleted issue still visible on machine B after sync"
else
    pass "deletion propagated to machine B"
fi
# This round is A's tombstone-protected import (no DB changes, equal issue-id
# sets): the byte-convergence adoption path must fire here, or br's tombstone
# closed_at serialization asymmetry would flap the tree hash between the two
# machines forever.
DIV_ADOPT_OUT=$(cd "${DIV_A}" && br orphanage sync 2>&1)
assert_contains "A's post-deletion sync adopts remote serialization" \
    "${DIV_ADOPT_OUT}" "adopted remote serialization"
DIV_A_LIST2=$(cd "${DIV_A}" && br list)
if [[ "${DIV_A_LIST2}" == *"issue from machine A"* ]]; then
    fail "deleted issue RESURRECTED on machine A (tombstone not honored)"
else
    pass "no resurrection on machine A after another sync round"
fi

section "divergence: three-way non-issue files (converge, no flap, both-changed)"

# A edits config.yaml; the edit must reach B and then settle (no flapping).
printf '\n# marker-from-A\n' >> "${DIV_A}/.beads/config.yaml"
(cd "${DIV_A}" && br orphanage sync >/dev/null)
(cd "${DIV_B}" && br orphanage sync >/dev/null 2>&1)
assert_true "A's config edit reached machine B" \
    grep -qF "# marker-from-A" "${DIV_B}/.beads/config.yaml"

set +e
DIV_SETTLE_OUT=$(cd "${DIV_B}" && br orphanage sync 2>&1)
set -e
assert_contains "B's follow-up sync is a no-op (no flapping)" "${DIV_SETTLE_OUT}" "Already in sync"
set +e
DIV_SETTLE_A=$(cd "${DIV_A}" && br orphanage sync 2>&1)
set -e
assert_contains "A's follow-up sync is a no-op (no flapping)" "${DIV_SETTLE_A}" "Already in sync"

# Byte-level convergence: after settling, both machines hold the SAME
# serialization of issues.jsonl (adoption picked one canonical byte form).
if cmp -s "${DIV_A}/.beads/issues.jsonl" "${DIV_B}/.beads/issues.jsonl"; then
    pass "both machines' issues.jsonl are byte-identical after settling"
else
    fail "both machines' issues.jsonl differ after settling"
fi

# Both-changed: A and B edit config.yaml differently; syncing machine keeps
# local and warns with the recovery command.
printf '\n# conflict-from-A\n' >> "${DIV_A}/.beads/config.yaml"
printf '\n# conflict-from-B\n' >> "${DIV_B}/.beads/config.yaml"
(cd "${DIV_A}" && br orphanage sync >/dev/null)
set +e
DIV_CONFLICT_OUT=$(cd "${DIV_B}" && br orphanage sync 2>&1)
DIV_CONFLICT_EXIT=$?
set -e
assert_eq "both-changed sync still exits 0" "0" "${DIV_CONFLICT_EXIT}"
assert_contains "both-changed warns" "${DIV_CONFLICT_OUT}" "both local and remote changed config.yaml"
assert_contains "warning includes the recovery command" "${DIV_CONFLICT_OUT}" "git cat-file blob"
assert_true "machine B kept its local config" \
    grep -qF "# conflict-from-B" "${DIV_B}/.beads/config.yaml"
DIV_REMOTE_CONFIG=$(git -C "${DIV_BARE}" show "refs/heads/${DIV_BRANCH}:config.yaml")
assert_contains "B's (local-wins) config was published" "${DIV_REMOTE_CONFIG}" "# conflict-from-B"

# --- Bootstrap: fresh clone converges from the orphan branch ----------------------

section "bootstrap: fresh clone + target + sync restores the workspace"

# Reuse the sync-demo project from the outbound-core section: clone it fresh.
git -C "${SYNC_PROJ}" push -q origin HEAD:refs/heads/main
BOOT_PROJ="${WORK}/proj-bootstrap"
git clone -q "${SYNC_ORIGIN_BARE}" "${BOOT_PROJ}"
assert_file_absent "fresh clone has no .beads/" "${BOOT_PROJ}/.beads"

(cd "${BOOT_PROJ}" && br orphanage target origin)
BOOT_OUT=$(cd "${BOOT_PROJ}" && br orphanage sync)
assert_contains "bootstrap reports success" "${BOOT_OUT}" "Bootstrapped sync-demo"

assert_dir_exists "workspace bootstrapped: .beads/ exists" "${BOOT_PROJ}/.beads"
assert_file_exists "issues.jsonl restored" "${BOOT_PROJ}/.beads/issues.jsonl"
BOOT_EXCLUDE=$(abs_git_path "${BOOT_PROJ}" info/exclude)
assert_true "bootstrap's init added '.beads/' to info/exclude" \
    grep -qxF '.beads/' "${BOOT_EXCLUDE}"

BOOT_LIST=$(cd "${BOOT_PROJ}" && br list)
assert_contains "issue visible via 'br list' after bootstrap" "${BOOT_LIST}" "orphan roundtrip issue"
BOOT_SHOW=$(cd "${BOOT_PROJ}" && br show "${SYNC_ISSUE_ID}")
assert_contains "issue visible via 'br show <id>' after bootstrap" "${BOOT_SHOW}" "orphan roundtrip issue"

BOOT_PUSHED=$(git -C "${BOOT_PROJ}" rev-parse refs/orphanage/pushed)
BOOT_REMOTE_TIP=$(git -C "${SYNC_ORIGIN_BARE}" rev-parse "refs/heads/${SYNC_BRANCH}")
assert_eq "bootstrap set refs/orphanage/pushed to the remote tip" "${BOOT_REMOTE_TIP}" "${BOOT_PUSHED}"

set +e
BOOT_NOOP=$(cd "${BOOT_PROJ}" && br orphanage sync 2>&1)
BOOT_NOOP_EXIT=$?
set -e
assert_eq "post-bootstrap sync exits 0" "0" "${BOOT_NOOP_EXIT}"
assert_contains "post-bootstrap sync is a no-op" "${BOOT_NOOP}" "Already in sync"

section "bootstrap: never-synced branch is a clear error"

NEVER_PROJ="${WORK}/proj-never-synced"
make_project_repo "${NEVER_PROJ}" yes "never-synced"
NEVER_CLONE="${WORK}/proj-never-synced-clone"
git -C "${NEVER_PROJ}" push -q origin HEAD:refs/heads/main
git clone -q "${WORK}/origins/never-synced.git" "${NEVER_CLONE}"
(cd "${NEVER_CLONE}" && br orphanage target origin)
set +e
NEVER_OUT=$(cd "${NEVER_CLONE}" && br orphanage sync 2>&1)
NEVER_EXIT=$?
set -e
if [[ "${NEVER_EXIT}" -ne 0 ]]; then
    pass "sync against a never-synced branch exits nonzero (${NEVER_EXIT})"
else
    fail "sync against a never-synced branch unexpectedly exited 0"
fi
assert_contains "never-synced error suggests 'br orphanage init'" "${NEVER_OUT}" "br orphanage init"

section "bootstrap: partial failure cleans up and stays re-bootstrappable"

BF_PROJ="${WORK}/proj-bootfail"
make_project_repo "${BF_PROJ}" yes "bootfail"
(cd "${BF_PROJ}" && br orphanage init -q --target origin)
(cd "${BF_PROJ}" && br q "bootfail recovery issue" >/dev/null)
(cd "${BF_PROJ}" && br orphanage sync >/dev/null)
git -C "${BF_PROJ}" push -q origin HEAD:refs/heads/main

BF_BARE="${WORK}/origins/bootfail.git"
BF_BRANCH="orphanage/origins/bootfail"
BF_GOOD_TIP=$(git -C "${BF_BARE}" rev-parse "refs/heads/${BF_BRANCH}")

# Corrupt the branch tip via plumbing: a commit whose issues.jsonl is garbage,
# so a bootstrap fails deterministically AFTER .beads/ has been created (the
# import step rejects the invalid JSONL).
BF_BAD_BLOB=$(printf 'this is not json {{{\n' | git -C "${BF_BARE}" hash-object -w --stdin)
BF_BAD_TREE=$(printf '100644 blob %s\tissues.jsonl\n' "${BF_BAD_BLOB}" | git -C "${BF_BARE}" mktree)
BF_BAD_COMMIT=$(git -C "${BF_BARE}" -c user.name=corruptor -c user.email=c@test \
    commit-tree "${BF_BAD_TREE}" -p "${BF_GOOD_TIP}" -m "corrupt issues.jsonl")
git -C "${BF_BARE}" update-ref "refs/heads/${BF_BRANCH}" "${BF_BAD_COMMIT}"

BF_CLONE="${WORK}/proj-bootfail-clone"
git clone -q "${BF_BARE}" "${BF_CLONE}"
(cd "${BF_CLONE}" && br orphanage target origin)
set +e
BF_OUT=$(cd "${BF_CLONE}" && br orphanage sync 2>&1)
BF_EXIT=$?
set -e
if [[ "${BF_EXIT}" -ne 0 ]]; then
    pass "bootstrap against corrupt data exits nonzero (${BF_EXIT})"
else
    fail "bootstrap against corrupt data unexpectedly exited 0"
fi
assert_contains "failure output explains the partial-bootstrap cleanup" "${BF_OUT}" "bootstrap failed partway"
assert_file_absent "partially-created .beads/ was removed" "${BF_CLONE}/.beads"

# Repair the branch and confirm the same clone re-bootstraps cleanly: the
# failed attempt must not have dead-ended the workspace.
git -C "${BF_BARE}" update-ref "refs/heads/${BF_BRANCH}" "${BF_GOOD_TIP}"
BF_RETRY=$(cd "${BF_CLONE}" && br orphanage sync)
assert_contains "re-bootstrap after repair succeeds" "${BF_RETRY}" "Bootstrapped bootfail"
BF_LIST=$(cd "${BF_CLONE}" && br list)
assert_contains "issue visible after recovered bootstrap" "${BF_LIST}" "bootfail recovery issue"

section "retargeting: new empty target receives a fresh orphan root"

RETGT_BARE="${WORK}/targets/retarget-home.git"
git init -q --bare "${RETGT_BARE}"
(cd "${SYNC_PROJ}" && br orphanage target "${RETGT_BARE}")
RETGT_OUT=$(cd "${SYNC_PROJ}" && br orphanage sync)
assert_contains "retargeted sync reports success" "${RETGT_OUT}" "Beads synced for sync-demo"
RETGT_TIP=$(git -C "${RETGT_BARE}" rev-parse "refs/heads/${SYNC_BRANCH}")
RETGT_PARENTS=$(git -C "${RETGT_BARE}" cat-file -p "${RETGT_TIP}" | grep -c '^parent ' || true)
assert_eq "retargeted commit is a fresh orphan root (no parents)" "0" "${RETGT_PARENTS}"
RETGT_ISSUES=$(git -C "${RETGT_BARE}" show "${RETGT_TIP}:issues.jsonl")
assert_contains "full current state landed at the new target" "${RETGT_ISSUES}" "orphan roundtrip issue"
# Point sync-demo back at origin for any later sections. Output is kept so a
# failing settle sync prints its diagnostics before set -e stops the harness.
(cd "${SYNC_PROJ}" && br orphanage target origin)
(cd "${SYNC_PROJ}" && br orphanage sync)
RETGT_TIP_AFTER=$(git -C "${RETGT_BARE}" rev-parse "refs/heads/${SYNC_BRANCH}")
assert_eq "old retarget target left untouched after repointing to origin" "${RETGT_TIP}" "${RETGT_TIP_AFTER}"

# --- sync --all: iterate the machine-local index ----------------------------------

section "sync --all: syncs multiple projects with different targets in one run"

ALL_A="${WORK}/proj-all-a"
ALL_B="${WORK}/proj-all-b"
make_project_repo "${ALL_A}" yes "all-a"
make_project_repo "${ALL_B}" yes "all-b"
ALL_B_TARGET="${WORK}/targets/all-b-private.git"
git init -q --bare "${ALL_B_TARGET}"
(cd "${ALL_A}" && br orphanage init -q --target origin)
(cd "${ALL_B}" && br orphanage init -q --target "${ALL_B_TARGET}")
(cd "${ALL_A}" && br q "first in all-a" >/dev/null)
(cd "${ALL_B}" && br q "first in all-b" >/dev/null)
(cd "${ALL_A}" && br orphanage sync >/dev/null)
(cd "${ALL_B}" && br orphanage sync >/dev/null)

(cd "${ALL_A}" && br q "second in all-a" >/dev/null)
(cd "${ALL_B}" && br q "second in all-b" >/dev/null)

# Runnable from anywhere, including outside any git repo.
set +e
ALL_OUT=$(cd "${WORK}" && br orphanage sync --all 2>&1)
ALL_EXIT=$?
set -e
assert_eq "'sync --all' exits 0 when all known projects sync cleanly" "0" "${ALL_EXIT}"
assert_contains "reports syncing all-a" "${ALL_OUT}" "syncing 'all-a'"
assert_contains "reports syncing all-b" "${ALL_OUT}" "syncing 'all-b'"
assert_contains "prints a summary" "${ALL_OUT}" "sync --all summary:"
assert_contains "first --all run reports zero failures" "${ALL_OUT}" "0 failed"

ALL_A_REMOTE=$(git -C "${WORK}/origins/all-a.git" show "refs/heads/orphanage/origins/all-a:issues.jsonl")
assert_contains "all-a's second issue reached its target" "${ALL_A_REMOTE}" "second in all-a"
ALL_B_REMOTE=$(git -C "${ALL_B_TARGET}" show "refs/heads/orphanage/origins/all-b:issues.jsonl")
assert_contains "all-b's second issue reached its (different) target" "${ALL_B_REMOTE}" "second in all-b"

section "sync --all: skips (with warnings) without failing the run"

# Stale path: recorded project deleted from disk.
STALE_ALL="${WORK}/proj-all-stale"
make_project_repo "${STALE_ALL}" yes "all-stale"
(cd "${STALE_ALL}" && br orphanage init -q --target origin)
(cd "${STALE_ALL}" && br q "stale issue" >/dev/null)
(cd "${STALE_ALL}" && br orphanage sync >/dev/null)
rm -rf "${STALE_ALL}"

# No-target project: synced once (so it's in the index), then target unset.
NOTGT_ALL="${WORK}/proj-all-no-target"
make_project_repo "${NOTGT_ALL}" yes "all-no-target"
(cd "${NOTGT_ALL}" && br orphanage init -q --target origin)
(cd "${NOTGT_ALL}" && br q "no-target issue" >/dev/null)
(cd "${NOTGT_ALL}" && br orphanage sync >/dev/null)
git -C "${NOTGT_ALL}" config --unset beadsOrphanage.target

set +e
SKIP_OUT=$(cd "${WORK}" && br orphanage sync --all 2>&1)
SKIP_EXIT=$?
set -e
assert_eq "'sync --all' still exits 0 with skips present" "0" "${SKIP_EXIT}"
assert_contains "warns about the stale path" "${SKIP_OUT}" "skipping 'all-stale'"
assert_contains "stale warning says the path is gone" "${SKIP_OUT}" "no longer exists"
assert_contains "warns about the unconfigured project" "${SKIP_OUT}" "skipping 'all-no-target'"
assert_contains "unconfigured warning names the cause" "${SKIP_OUT}" "no sync target configured"
# Restore the target so later full-suite runs stay deterministic.
git -C "${NOTGT_ALL}" config beadsOrphanage.target origin

section "sync --all: a real per-project failure yields nonzero exit"

FAIL_ALL="${WORK}/proj-all-fail"
make_project_repo "${FAIL_ALL}" yes "all-fail"
(cd "${FAIL_ALL}" && br orphanage init -q --target origin)
(cd "${FAIL_ALL}" && br q "doomed issue" >/dev/null)
(cd "${FAIL_ALL}" && br orphanage sync >/dev/null)
# Induce a real failure: point the target at a URL that doesn't exist.
git -C "${FAIL_ALL}" config beadsOrphanage.target "${WORK}/definitely/not/a/repo.git"

set +e
FAILRUN_OUT=$(cd "${WORK}" && br orphanage sync --all 2>&1)
FAILRUN_EXIT=$?
set -e
if [[ "${FAILRUN_EXIT}" -ne 0 ]]; then
    pass "'sync --all' exits nonzero when a known project's sync fails (${FAILRUN_EXIT})"
else
    fail "'sync --all' unexpectedly exited 0 despite an induced failure"
fi
assert_contains "failure is warned per-project" "${FAILRUN_OUT}" "sync failed for 'all-fail'"
assert_contains "healthy projects still synced in the same run" "${FAILRUN_OUT}" "syncing 'all-a'"
# Restore all-fail's target so later runs are deterministic.
git -C "${FAIL_ALL}" config beadsOrphanage.target origin

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
