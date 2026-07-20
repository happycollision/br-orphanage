# Nested Content Dir Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a nook's on-disk content directory carry the basename of `--dir` (e.g. `.beads`) instead of `<name>.nook`, so name-sensitive tools like `br` accept the symlink target, while keeping the published git ref byte-identical.

**Architecture:** Split the single checkout path into a **container** (`.git/nook/<name>.nook/`, owned by git-nook) and a **work-tree** (`.git/nook/<name>.nook/<basename(dir)>/`, the git worktree the symlink targets). Every `git --work-tree=` and the symlink point at the work-tree; git-nook creates/removes the container. `materialize` migrates existing flat checkouts into the nested layout.

**Tech Stack:** Bash (`set -euo pipefail`, bash 3.2-compatible for macOS), git plumbing, shellcheck, a bespoke `tests/run.sh` end-to-end suite.

---

## Context every task needs

- The one file changed for behavior is `bin/git-nook`. Tests live in `tests/run.sh`. Run the suite with `bash tests/run.sh` (it prints `=== section ===` headers and `[PASS]`/`[FAIL]` lines, exits nonzero on any fail). Run shellcheck with `shellcheck bin/git-nook`.
- **Terminology:**
  - *container* = `<common-git-dir>/nook/<name>.nook` — git-nook mkdir's this and `rm -rf`s it on rollback. Independent of `--dir`.
  - *work-tree* = `<common-git-dir>/nook/<name>.nook/<basename(dir)>` — the git worktree; the symlink `<dir>` points here; `git --work-tree` uses it. Tracked paths stay bare because the worktree root IS the content dir.
- `basename(dir)`: `dir` is the configured `nook.<name>.dir` (fetched via `channel_dir "${name}"`). For `--dir .beads` → `.beads`; `--dir notes` → `notes`; `--dir a/b/c` → `c`. Use bash `${dir##*/}` to take the basename (works for all three; a no-slash value returns itself).
- **Migration detection rule (authoritative):** a nook is *already migrated* iff its per-worktree symlink resolves to the work-tree path. If instead it resolves to the container path (old flat layout) and the container holds entries, migrate. Decide by which of the two known paths the symlink targets — never by inspecting the names of the contents (avoids a false positive when a tracked file/dir shares `basename(dir)`'s name).
- **bash 3.2:** no `${var,,}`; no associative arrays. Subshell `( shopt -s dotglob nullglob; ... )` is the established idiom for moving dotfiles (see current `materialize_one`).
- **`set -e` footgun (already burned once in this repo):** inside a `( ... )` subshell or a function whose result feeds `&&`/`||`/`if`, a failing command may not abort. Use explicit `|| { err ...; return 1; }` on every mutating step, matching the current code.

Read the current `bin/git-nook` before starting. The helper being replaced is at line 112:
```sh
canonical_checkout() { printf '%s/nook/%s.nook\n' "$(common_git_dir)" "$1"; }
```
Current call sites (all use a local `checkout_dir`): `populate_checkout_from_head`, `materialize_one`, `rollback_add`, `cmd_add`, `cmd_list`, `cmd_show`, `run_passthrough`.

---

## Task 1: Split the checkout helper into container + work-tree

**Files:**
- Modify: `bin/git-nook:109-112` (replace `canonical_checkout`)

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh` at the very end (just before the final summary/exit block — find the block that prints the pass/fail totals and insert above it). This drives an internal helper by observing `show`'s `checkout:` line, which must now report the nested path.

```bash
section "nested: show reports the nested work-tree path (not the container)"
NEST=${WORK}/proj-nested
make_project_repo "${NEST}" yes nested-demo
(cd "${NEST}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
NEST_SHOW=$(cd "${NEST}" && "${NOOK}" -n beads show)
NEST_COMMON=$(cd "${NEST}" && git rev-parse --git-common-dir)
NEST_WT="$(cd "${NEST}/${NEST_COMMON}" && pwd)/nook/beads.nook/.beads"
assert_contains "show checkout: is the nested work-tree" "${NEST_SHOW}" "checkout: ${NEST_WT}/"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 "nested: show reports"`
Expected: FAIL — `show` currently prints `.../nook/beads.nook/`, not `.../nook/beads.nook/.beads/`.

- [ ] **Step 3: Write minimal implementation**

Replace lines 109-112 of `bin/git-nook` with:

```sh
# Absolute path of the CONTAINER dir for a nook: git-nook owns this (creates
# it on add, removes it on rollback). Lives in the common git dir so every
# worktree shares it. Independent of the configured content dir.
canonical_container() { printf '%s/nook/%s.nook\n' "$(common_git_dir)" "$1"; }

# Absolute path of a nook's WORK-TREE: the content dir nested inside the
# container, named for the basename of the configured content dir. This is
# what the per-worktree symlink targets and what `git --work-tree` uses, so
# tracked paths stay bare (the worktree root IS the content dir) and a
# name-sensitive tool resolving the symlink lands on a dir named basename(dir).
# Falls back to the container itself only if the dir config is somehow unset.
canonical_worktree() {
    local name="$1" dir base
    dir=$(channel_dir "${name}" 2>/dev/null) || dir=""
    base="${dir##*/}"
    if [[ -n "${base}" ]]; then
        printf '%s/%s\n' "$(canonical_container "${name}")" "${base}"
    else
        canonical_container "${name}"
    fi
}
```

Then update `cmd_show` (currently near line 527) so `checkout_dir` uses the work-tree:
```sh
checkout_dir=$(canonical_worktree "${name}")
```
(Leave the rest of `cmd_show` alone for this task — later tasks handle the other call sites. Only the `checkout:` display and the local var it prints change here. If `cmd_show` also uses `checkout_dir` in its link comparison, that comparison now points at the work-tree, which is correct and covered in Task 4.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A1 "nested: show reports"`
Expected: PASS.

Note: OTHER tests will now FAIL (they assert the old `beads.nook` symlink target). That is expected — Tasks 2-4 fix the behavior those tests exercise; Task 6 updates the stale assertions. Do not "fix" them by reverting this task.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck bin/git-nook`
Expected: no new warnings.

- [ ] **Step 6: Commit**

```bash
git add bin/git-nook tests/run.sh
git commit -m "refactor(nook): split canonical checkout into container + work-tree helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `run_passthrough` targets the work-tree

**Files:**
- Modify: `bin/git-nook` `run_passthrough` (currently near lines 570-611)

- [ ] **Step 1: Write the failing test**

Add at the end of `tests/run.sh` (above the summary block):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 "tracked path is bare"`
Expected: FAIL — `run_passthrough` still points `--work-tree` at the container, so either the checkout guard misfires or the path resolves wrong.

- [ ] **Step 3: Write minimal implementation**

In `run_passthrough`, replace the two lines that compute `checkout_dir` from `canonical_checkout` with `canonical_worktree`, and switch the container-existence check to guard the container while the checkout/`cd`/`--work-tree` use the work-tree. The function head currently reads:

```sh
    gitdir=$(inner_git_dir "${name}")
    checkout_dir=$(canonical_checkout "${name}")
    if [[ ! -d "${gitdir}" ]]; then
        err "nook '${name}' has no inner repo at ${gitdir} (was it deleted?)"
        exit 1
    fi
    if [[ ! -d "${checkout_dir}" ]]; then
        err "nook '${name}' has no checkout at ${checkout_dir}; run: git nook materialize (or: git nook add ${name} <target>)"
        exit 1
    fi
```

Change the `checkout_dir` assignment to:
```sh
    checkout_dir=$(canonical_worktree "${name}")
```
The rest of the function (the `cd "${checkout_dir}"`, the `pwd -P` containment check, and `exec git --git-dir=... --work-tree="${checkout_dir}"`) is unchanged — it now operates on the work-tree, which is what we want. The `[[ ! -d "${checkout_dir}" ]]` guard still correctly fires when the work-tree is missing and still points the user at `git nook materialize`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A1 "tracked path is bare"`
Expected: PASS.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck bin/git-nook`
Expected: no new warnings.

- [ ] **Step 6: Commit**

```bash
git add bin/git-nook tests/run.sh
git commit -m "fix(nook): passthrough targets the nested work-tree

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `materialize_one` creates the nested work-tree and symlinks to it

**Files:**
- Modify: `bin/git-nook` `materialize_one` (currently lines 221-289) and `populate_checkout_from_head` (lines 207-215)

- [ ] **Step 1: Write the failing test**

Add at the end of `tests/run.sh` (above the summary block):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A4 "add materializes symlink to the nested"`
Expected: FAIL — the symlink currently targets `beads.nook`, whose basename is `beads.nook`, not `.beads`.

- [ ] **Step 3: Write minimal implementation**

Rewrite `materialize_one` so it distinguishes container from work-tree. Replace the function body's path setup and reconciliation. The new version:

```sh
materialize_one() {
    local name="$1" toplevel dir container_dir checkout_dir gitdir content_path t checkout_real c_has d_has
    toplevel=$(git rev-parse --show-toplevel)
    dir=$(channel_dir "${name}")               # configured path, verbatim (may start with '.')
    container_dir=$(canonical_container "${name}")   # git-nook-owned container dir
    checkout_dir=$(canonical_worktree "${name}")     # nested content dir (the work-tree)
    gitdir=$(inner_git_dir "${name}")
    content_path="${toplevel}/${dir}"

    # Ensure the container and the nested work-tree dir exist (empty for now).
    mkdir -p "${checkout_dir}"

    # MIGRATION: an old flat layout has tracked files directly in the container
    # and a symlink pointing at the container (not the nested work-tree). Detect
    # by the symlink's resolved target, never by content names. Move the flat
    # files down into the nested work-tree, then fall through to normal symlink
    # reconciliation (which will repoint at the work-tree).
    if [[ -L "${content_path}" ]]; then
        t=$(cd "${content_path}" 2>/dev/null && pwd -P) || t=""
        if [[ -n "${t}" && "${t}" == "$(cd "${container_dir}" && pwd -P)" ]]; then
            # symlink still points at the container -> old flat layout. Move every
            # container entry EXCEPT the nested work-tree dir itself down into it.
            ( shopt -s dotglob nullglob
              for e in "${container_dir}"/*; do
                  [[ "${e}" == "${checkout_dir}" ]] && continue
                  mv "${e}" "${checkout_dir}/" || { err "failed to migrate '${e}' into '${checkout_dir}'"; exit 1; }
              done ) || return 1
            rm -f "${content_path}"   # drop the stale symlink; re-created below
        fi
    fi

    # Reconcile the per-worktree path content_path against the work-tree.
    if [[ -L "${content_path}" ]]; then
        # existing symlink: OK only if it already points at the work-tree
        t=$(cd "${content_path}" 2>/dev/null && pwd -P) || t=""
        checkout_real=$(cd "${checkout_dir}" && pwd -P)
        if [[ "${t}" != "${checkout_real}" ]]; then
            err "'${dir}' is a symlink to '${t}', not the nook work-tree '${checkout_dir}'; refusing to clobber"
            return 1
        fi
        # shellcheck disable=SC2310 # failure handled by the || return
        populate_checkout_from_head "${gitdir}" "${checkout_dir}" || return 1
    elif [[ -d "${content_path}" ]]; then
        d_has=$(ls -A "${content_path}" 2>/dev/null)
        c_has=$(ls -A "${checkout_dir}" 2>/dev/null)
        if [[ -n "${d_has}" ]]; then
            if [[ -n "${c_has}" ]]; then
                err "both '${dir}' and the nook work-tree '${checkout_dir}' have content; reconcile manually"
                return 1
            fi
        else
            # shellcheck disable=SC2310 # failure handled by the || return
            populate_checkout_from_head "${gitdir}" "${checkout_dir}" || return 1
        fi
        ( shopt -s dotglob nullglob; for e in "${content_path}"/*; do mv "${e}" "${checkout_dir}/" || { err "failed to move '${e}' into '${checkout_dir}'"; exit 1; }; done )
        rmdir "${content_path}" || { err "could not remove '${dir}' after migrating its contents"; return 1; }
        mkdir -p "$(dirname "${content_path}")"
        ln -s "${checkout_dir}" "${content_path}"
    elif [[ -e "${content_path}" ]]; then
        err "'${dir}' exists but is not a directory or symlink"
        return 1
    else
        # shellcheck disable=SC2310 # failure handled by the || return
        populate_checkout_from_head "${gitdir}" "${checkout_dir}" || return 1
        mkdir -p "$(dirname "${content_path}")"
        ln -s "${checkout_dir}" "${content_path}"
    fi

    add_exclude_entry "/${dir}"

    echo "git-nook: materialized ${name} -> ${dir}"
    return 0
}
```

Note the migration branch and the correct-symlink branch can both leave `content_path` as a (now stale, removed) symlink; after the migration branch `rm -f`s it, the `else` (absent) branch re-creates the symlink pointing at the work-tree. `populate_checkout_from_head` is unchanged — it already takes `checkout_dir` as an argument and now receives the work-tree.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A4 "add materializes symlink to the nested"`
Expected: PASS.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck bin/git-nook`
Expected: no new warnings.

- [ ] **Step 6: Commit**

```bash
git add bin/git-nook tests/run.sh
git commit -m "feat(nook): materialize nests the work-tree, symlinks to basename(dir)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `cmd_add`, `cmd_list`, `cmd_show`, `rollback_add` use the right path

**Files:**
- Modify: `bin/git-nook` `cmd_add` (lines ~388-471), `rollback_add` (lines ~294-302), `cmd_list` (lines ~486-489), `cmd_show` (lines ~527-536)

- [ ] **Step 1: Write the failing test**

Add at the end of `tests/run.sh` (above the summary block):

```bash
section "nested: list and show report linked; rollback removes the container"
NESTL=${WORK}/proj-nested-list
make_project_repo "${NESTL}" yes nested-list-demo
(cd "${NESTL}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
NESTL_LIST=$(cd "${NESTL}" && "${NOOK}" list)
assert_contains "list shows the beads nook" "${NESTL_LIST}" "beads"
if [[ "${NESTL_LIST}" == *"not linked here"* ]]; then
    fail "list should report the freshly-added nested nook as linked"
else
    pass "list reports the nested nook as linked (no 'not linked here')"
fi
NESTL_SHOW=$(cd "${NESTL}" && "${NOOK}" -n beads show)
assert_contains "show reports linked: yes for nested nook" "${NESTL_SHOW}" "linked:   yes"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 "list and show report linked"`
Expected: FAIL — `cmd_list`/`cmd_show` compare `content_path` against `canonical_checkout` (the container), but the symlink now points at the nested work-tree, so both report "not linked".

- [ ] **Step 3: Write minimal implementation**

Make four edits in `bin/git-nook`:

1. **`cmd_list`** — the link comparison uses the work-tree. Change the line that sets `checkout_dir` inside the `while read` loop:
```sh
        checkout_dir=$(canonical_worktree "${name}")
```

2. **`cmd_show`** — already changed in Task 1 to `canonical_worktree`. Verify the link-comparison block and the `checkout:` echo both use that `checkout_dir`. No further change if Task 1 set `checkout_dir=$(canonical_worktree "${name}")`.

3. **`cmd_add`** — it computes `checkout_dir=$(canonical_checkout "${name}")` (line ~392) and uses it for: the `made_ckout` emptiness check (line ~434), the bootstrap "not empty" check (line ~452), the bootstrap `reset --hard --work-tree` (line ~460), and the `rollback_add` calls. The container-emptiness bookkeeping (`made_ckout`) must key on the **container**, while content checks and `--work-tree` must key on the **work-tree**. Replace the single assignment with two locals:
```sh
    local ref gitdir container_dir checkout_dir
    # shellcheck disable=SC2310 # failure handled by the || exit
    ref=$(resolve_ref "${ref_tpl}" "${name}") || exit 1
    gitdir=$(inner_git_dir "${name}")
    container_dir=$(canonical_container "${name}")
    checkout_dir=$(canonical_worktree "${name}")
```
Then:
- The `made_ckout` check (was `ls -A "${checkout_dir}"`) → key on the container so rollback removes a container this run created:
```sh
    [[ -n "$(ls -A "${container_dir}" 2>/dev/null)" ]] || made_ckout=1
```
- The bootstrap-clobber "not empty" check (was `ls -A "${checkout_dir}"`) stays on the **work-tree** `checkout_dir` (it asks "does the content dir already have local files?"). Leave as `checkout_dir`.
- The bootstrap `reset --hard --work-tree="${checkout_dir}"` stays on the **work-tree** `checkout_dir`. Leave as is.
- Every `rollback_add ... "${checkout_dir}" ...` call → pass the **container** so rollback removes the whole container:
```sh
        rollback_add "${name}" "${dir}" "${toplevel}" "${gitdir}" "${container_dir}" "${made_link}" "${made_ckout}"
```
(there are three such call sites in `cmd_add`; update all three).

4. **`rollback_add`** — its 5th positional was named `checkout_dir` and does `rm -rf "${checkout_dir}"`. It now receives the container. Rename the local for clarity and keep the `rm -rf`:
```sh
rollback_add() {
    local name="$1" dir="$2" toplevel="$3" gitdir="$4" container_dir="$5" made_link="$6" made_ckout="$7"
    rm -rf "${gitdir}"
    git config --remove-section "nook.${name}" 2>/dev/null || true
    remove_exclude_entry "${dir}"
    [[ -n "${made_link}" ]] && rm -f "${toplevel}/${dir}"
    [[ -n "${made_ckout}" ]] && rm -rf "${container_dir}"
    : # ensure exit status 0 so the trailing [[ ]] && cmd never trips set -e
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A2 "list and show report linked"`
Expected: PASS.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck bin/git-nook`
Expected: no new warnings.

- [ ] **Step 6: Commit**

```bash
git add bin/git-nook tests/run.sh
git commit -m "fix(nook): add/list/show/rollback distinguish container from work-tree

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: basename coverage — dotless and multi-segment dirs

**Files:**
- Test only: `tests/run.sh`

- [ ] **Step 1: Write the failing/covering test**

Add at the end of `tests/run.sh` (above the summary block). These should PASS already if Tasks 1-4 are correct; they lock the basename rule for the non-`.beads` cases.

```bash
section "nested: basename rule for dotless and multi-segment --dir"
# dotless default dir: --dir notes -> nested 'notes'
NB=${WORK}/proj-nested-basename
make_project_repo "${NB}" yes nested-basename-demo
(cd "${NB}" && "${NOOK}" add notes origin >/dev/null)   # default --dir = name = notes
assert_eq "dotless symlink target basename is notes" \
    "notes" "$(basename "$(cd "${NB}/notes" && pwd -P)")"
# multi-segment dir: --dir a/b/c -> symlink at a/b/c, nested leaf 'c'
NB_TGT="${WORK}/targets/nested-multi.git"
mkdir -p "$(dirname "${NB_TGT}")"; git init -q --bare "${NB_TGT}"
(cd "${NB}" && "${NOOK}" add deep "${NB_TGT}" --dir a/b/c >/dev/null)
assert_true "multi-segment content path is a symlink" test -L "${NB}/a/b/c"
assert_eq "multi-segment symlink target basename is c" \
    "c" "$(basename "$(cd "${NB}/a/b/c" && pwd -P)")"
NB_COMMON=$(cd "${NB}" && git rev-parse --git-common-dir)
NB_WT="$(cd "${NB}/${NB_COMMON}" && pwd)/nook/deep.nook/c"
assert_eq "multi-segment symlink resolves to nook/deep.nook/c" \
    "$(cd "${NB}/a/b/c" && pwd -P)" "$(cd "${NB_WT}" && pwd -P)"
```

- [ ] **Step 2: Run the tests**

Run: `bash tests/run.sh 2>&1 | grep -A5 "basename rule for dotless"`
Expected: PASS (all four assertions). If any FAIL, the basename logic in `canonical_worktree` or the symlink-parent `mkdir -p` in `materialize_one` is wrong — fix in `bin/git-nook`, not the test.

- [ ] **Step 3: Commit**

```bash
git add tests/run.sh
git commit -m "test(nook): basename rule covers dotless and multi-segment --dir

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Migration test + update stale assertions

**Files:**
- Modify: `tests/run.sh` — update the three existing `symlink points at canonical checkout` assertions and add a migration test

- [ ] **Step 1: Update the stale assertions**

Three existing blocks assert the symlink points at `nook/<name>.nook` (the container). They must now assert the nested work-tree. Find each and update:

(a) around line 376-380 (`ADD_CANON`, nook `notes`, default dir):
```bash
assert_true "content path is a symlink" test -L "${ADD_PROJ}/notes"
ADD_CANON=$(cd "${ADD_PROJ}" && git rev-parse --git-common-dir)
ADD_CANON="$(cd "${ADD_PROJ}/${ADD_CANON}" && pwd)/nook/notes.nook/notes"
assert_dir_exists "nested work-tree dir exists" "${ADD_CANON}"
assert_eq "symlink points at nested work-tree" \
    "$(cd "${ADD_PROJ}/notes" && pwd -P)" "$(cd "${ADD_CANON}" && pwd -P)"
```

(b) around line 422-426 (`SECRET_CANON`, nook `secret`, `--dir .secret`):
```bash
assert_true "explicit dotted dir is a symlink" test -L "${ADD_PROJ}/.secret"
SECRET_CANON=$(cd "${ADD_PROJ}" && git rev-parse --git-common-dir)
SECRET_CANON="$(cd "${ADD_PROJ}/${SECRET_CANON}" && pwd)/nook/secret.nook/.secret"
assert_dir_exists "nested work-tree dir exists" "${SECRET_CANON}"
assert_eq "symlink points at nested work-tree" \
    "$(cd "${ADD_PROJ}/.secret" && pwd -P)" "$(cd "${SECRET_CANON}" && pwd -P)"
```

(c) around line 505-509 (`PT_CANON`, nook `notes`, passthrough section):
```bash
assert_true "content path is a symlink" test -L "${PT_PROJ}/notes"
PT_CANON=$(cd "${PT_PROJ}" && git rev-parse --git-common-dir)
PT_CANON="$(cd "${PT_PROJ}/${PT_CANON}" && pwd)/nook/notes.nook/notes"
assert_dir_exists "nested work-tree dir exists" "${PT_CANON}"
assert_eq "symlink points at nested work-tree" \
    "$(cd "${PT_PROJ}/notes" && pwd -P)" "$(cd "${PT_CANON}" && pwd -P)"
```

The passthrough "missing checkout" section (lines ~562-585) does `rm -rf` on `CGONE = .../nook/stash.nook` (the container). Leave `CGONE` as the container path — **no change needed**. After this plan's changes `run_passthrough` guards on the work-tree (`nook/stash.nook/stash`); removing the whole container makes that work-tree absent too, so the `! -d "${checkout_dir}"` error still fires and still points at `git nook materialize`. Just re-run this section after your edits to confirm the two assertions (`missing canonical checkout exits nonzero`, `error points at materialize`) still pass; they should, unchanged.

There is one line in that section to leave exactly as-is:
```bash
CGONE=$(cd "${GONE}" && git rev-parse --git-common-dir); CGONE="$(cd "${GONE}/${CGONE}" && pwd)/nook/stash.nook"
```
Do NOT append `/stash` to it — removing the container is the intended, stronger simulation.

- [ ] **Step 2: Add the migration test**

Add at the end of `tests/run.sh` (above the summary block). This seeds an OLD flat layout by hand, then runs `materialize` and asserts it migrated to nested without data loss, idempotently.

```bash
section "nested: materialize migrates an old flat checkout to nested layout"
MIG=${WORK}/proj-migrate
make_project_repo "${MIG}" yes migrate-demo
(cd "${MIG}" && "${NOOK}" add beads origin --dir .beads >/dev/null)
MIG_COMMON=$(cd "${MIG}" && git rev-parse --git-common-dir)
MIG_CONTAINER="$(cd "${MIG}/${MIG_COMMON}" && pwd)/nook/beads.nook"
MIG_WT="${MIG_CONTAINER}/.beads"
# Simulate the OLD flat layout: put content directly in the container and point
# the symlink at the container (undo the nesting this build created).
rm "${MIG}/.beads"                       # drop the nested symlink
( shopt -s dotglob nullglob; for e in "${MIG_WT}"/*; do mv "${e}" "${MIG_CONTAINER}/"; done )
rmdir "${MIG_WT}"
ln -s "${MIG_CONTAINER}" "${MIG}/.beads" # old-style symlink at the container
echo '{"id":"mig1"}' > "${MIG_CONTAINER}/issues.jsonl"
mkdir -p "${MIG_CONTAINER}/.br_history"; echo hist > "${MIG_CONTAINER}/.br_history/h1"
# Now migrate.
(cd "${MIG}" && "${NOOK}" materialize >/dev/null)
assert_true "post-migration content path is a symlink" test -L "${MIG}/.beads"
assert_eq "symlink now resolves to the nested work-tree" \
    "$(cd "${MIG}/.beads" && pwd -P)" "$(cd "${MIG_WT}" && pwd -P)"
assert_file_exists "flat file migrated into nested work-tree" "${MIG_WT}/issues.jsonl"
assert_file_exists "flat subdir file migrated too" "${MIG_WT}/.br_history/h1"
assert_file_absent "no leftover issues.jsonl at container top level" "${MIG_CONTAINER}/issues.jsonl"
# Idempotent: a second materialize is a clean no-op that keeps the nested layout.
(cd "${MIG}" && "${NOOK}" materialize >/dev/null)
assert_eq "second materialize keeps nested target" \
    "$(cd "${MIG}/.beads" && pwd -P)" "$(cd "${MIG_WT}" && pwd -P)"
assert_file_exists "content still present after idempotent re-run" "${MIG_WT}/issues.jsonl"
```

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: all sections PASS, process exits 0. If the migration test fails on the `.br_history` subdir, the migration loop in `materialize_one` isn't handling dotfile dirs — confirm the `shopt -s dotglob nullglob` subshell and the `[[ "${e}" == "${checkout_dir}" ]]` skip are present.

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test(nook): migration coverage + update assertions to nested layout

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Docs — README "How it works" reflects the nested layout

**Files:**
- Modify: `README.md` (the three-path block ~lines 93-99 and the surrounding "How it works" prose ~lines 100-121)

- [ ] **Step 1: Update the three-path diagram**

In `README.md`, the current block reads:
```
.git/nook/notes.git    # the inner bare repository (hidden inside your .git)
.git/nook/notes.nook/  # the one real checkout, shared by every worktree
notes/                 # a symlink to the checkout above; excluded via .git/info/exclude
```
Replace with:
```
.git/nook/notes.git         # the inner bare repository (hidden inside your .git)
.git/nook/notes.nook/       # the container git-nook owns, shared by every worktree
.git/nook/notes.nook/notes/ # the real checkout (the work-tree); its basename
                            #   matches your content dir, so name-sensitive tools
                            #   (e.g. br's .beads) accept it
notes/                      # a symlink to the work-tree above; excluded via .git/info/exclude
```

- [ ] **Step 2: Update the surrounding prose**

Immediately below, the prose says "The real files live once, under `.git/nook/<name>.nook/`". Adjust to name the nested work-tree and explain the basename guarantee. Replace the sentence:
> The real files live once, under `.git/nook/<name>.nook/` in the host repo's *common* git dir.

with:
> The real files live once, in a content directory nested inside the container at `.git/nook/<name>.nook/<dir-basename>/` in the host repo's *common* git dir. That nested directory's name is the basename of your content dir (`notes`, or `.beads` for `--dir .beads`), so a tool that resolves the symlink and insists on a particular directory name — like `br`, which requires a `.beads`/`_beads` directory — sees exactly the name it expects.

Also update the `≈` equivalence block (~line 120) if it names the work-tree path:
```
git nook -n <name> run <any-git-args...>
# ≈ git --git-dir=.git/nook/<name>.git --work-tree=.git/nook/<name>.nook/<dir-basename> <any-git-args...>
```

- [ ] **Step 3: Verify no other README path references are now wrong**

Run: `grep -n "nook/.*\.nook" README.md`
Expected: every hit either shows the container (`<name>.nook/`) in a context that's still accurate, or the nested work-tree. Fix any that imply the checkout files live directly in `<name>.nook/`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(nook): README reflects the nested content dir layout

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Full-suite + shellcheck green, then real-repo dogfood

**Files:** none (verification only)

- [ ] **Step 1: Full suite**

Run: `bash tests/run.sh`
Expected: exits 0, no `[FAIL]` lines.

- [ ] **Step 2: shellcheck**

Run: `shellcheck bin/git-nook`
Expected: clean.

- [ ] **Step 3: Dogfood on THIS repo's beads nook (the motivating case)**

This repo has a real `beads` nook whose checkout is the old flat layout. Re-materialize with the freshly built binary and confirm br can finally read it.

Run:
```bash
./bin/git-nook materialize
readlink .beads                                  # expect: .git/nook/beads.nook/.beads (or abs)
basename "$(cd .beads && pwd -P)"                # expect: .beads
./bin/git-nook -n beads run status -sb           # expect: ## main...origin/main
br where                                          # expect: a path ending in /.beads, no error
```
Expected: `basename` is `.beads`; `br where` succeeds instead of the "Redirect target must be a .beads or _beads directory" error. If `br` still errors, STOP — the migration didn't produce a `.beads`-named resolved dir; re-examine `canonical_worktree`/`materialize_one`.

- [ ] **Step 4: Confirm the published ref is unchanged (no accidental re-pathing)**

Run:
```bash
./bin/git-nook -n beads run ls-tree --name-only -r HEAD | head
```
Expected: bare paths (`issues.jsonl`, `merge-issues.sh`, ...), NOT `.beads/issues.jsonl`. If prefixed, the work-tree is wrong (pointing at the container, not the nested dir).

- [ ] **Step 5: Parent repo stays clean**

Run: `git status --porcelain`
Expected: no mention of `.beads` (still excluded), only the intended tracked changes on this branch.

No commit — this task is verification. If everything is green, the branch is ready for whole-branch review.
```
