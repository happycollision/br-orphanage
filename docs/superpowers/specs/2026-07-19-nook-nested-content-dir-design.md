# Design: nested content dir preserves the `--dir` basename

**Status:** approved 2026-07-19, awaiting implementation plan.

> Note: per AGENTS.md, designs/plans normally live in beads on the nook, not as
> committed markdown on master. This one is a temporary exception: beads is
> currently unusable because of the very bug this design fixes (see "Problem").
> Once the change lands and `br` works against the nook again, migrate this spec
> into a beads epic and remove the markdown from master.

## Problem

git-nook materializes a nook's checkout at `.git/nook/<name>.nook/`, and the
files in that directory *are* the tracked content. The per-worktree symlink
therefore points at a directory whose basename is `<name>.nook`:

```
.beads -> .git/nook/beads.nook
```

Name-sensitive tools reject this. Concretely, `br` (beads_rust) 0.2.16 resolves
the `.beads` symlink to its physical target and hard-requires that target's
basename be `.beads` or `_beads`:

```
Error: Configuration error: Redirect target must be a .beads or _beads directory:
  /Users/don.denton/GitProjects/git-nook/.git/nook/beads.nook
```

`br` checks the *resolved* basename, so no symlink indirection bypasses it
(verified: `_beads -> beads.nook` still fails; only a dir literally named
`.beads`/`_beads` satisfies the guard). This breaks every `br` command in a
repo whose beads live in a nook — including `br create`, so the documented
beads workflow (AGENTS.md session protocol) is dead in such a checkout.

**Root cause:** the content directory's on-disk basename does not equal
`basename(--dir)`. It is always `<name>.nook`. Fixing that mismatch fixes the
class of problem for any name-sensitive tool, without git-nook knowing anything
tool-specific.

## Non-goals

- Teaching git-nook about `br` or the magic names `.beads`/`_beads`. The tool
  stays general: it guarantees the content dir's basename equals
  `basename(--dir)`, nothing more.
- Changing the published ref's path layout. Tracked paths stay bare
  (`issues.jsonl`, not `.beads/issues.jsonl`). No ref migration of content.
- Hard links. Directories cannot be hard-linked (POSIX); per-file hard links
  break under atomic-rename writes, don't survive `git checkout`/clone, and are
  same-filesystem-only. The symlink model is retained.

## Core change

Split the single checkout path into two distinct paths:

```
.git/nook/<name>.nook/                  # container: git-nook owns it
                                        #   (mkdir on add, rm -rf on rollback)
.git/nook/<name>.nook/<basename(dir)>/  # work-tree: the content dir
                                        #   git tracks it; symlink targets it
<dir> -> .git/nook/<name>.nook/<basename(dir)>
```

Example (`--dir .beads`, nook name `beads`):

```
.git/nook/beads.nook/            <- container
.git/nook/beads.nook/.beads/     <- work-tree (git --work-tree points here)
  issues.jsonl                   <- tracked as "issues.jsonl" (bare, unchanged)
  merge-issues.sh
.beads -> .git/nook/beads.nook/.beads
```

`br` (or any tool) resolving `.beads` now lands on a directory named `.beads`. ✓

Because `git --work-tree` points at the nested content dir (not the container),
the tracked path set is unchanged — the published ref stays byte-identical.

### `basename(dir)` rule

The nested dir is named `basename(dir)`, where `dir` is the configured
`nook.<name>.dir` value:

- `--dir .beads`  → nested `.beads`   → symlink `.beads` -> `beads.nook/.beads`
- `--dir notes`   → nested `notes`    → symlink `notes`  -> `notes.nook/notes`
- `--dir a/b/c`   → nested `c`        → symlink `a/b/c`  -> `abc.nook/c`

The container is always `<name>.nook`, regardless of `--dir` depth. Only the
leaf name is mirrored inside; the full relative path is *not* recreated in the
container (only the leaf matters to name-sensitive tools, and mirroring the
full path complicates the math for no benefit).

## Code changes (`bin/git-nook`)

Replace the single helper:

```sh
canonical_checkout() { printf '%s/nook/%s.nook\n' "$(common_git_dir)" "$1"; }
```

with two:

- `canonical_container(name)` → `<common-git-dir>/nook/<name>.nook`
  The directory git-nook creates (`mkdir -p`) and removes on rollback
  (`rm -rf`). Independent of `--dir`.
- `canonical_worktree(name)` → `<common-git-dir>/nook/<name>.nook/<basename(dir)>`
  The content dir. Used for: every `git --work-tree=...`, the symlink target,
  every "does the checkout have content?" check, `run_passthrough`'s checkout
  existence guard and `cd`, `show`'s `checkout:` line, and the `list`/`show`
  "linked here?" physical-path comparison.

`basename(dir)` is derived from `channel_dir "${name}"` (the configured
`nook.<name>.dir`), so `canonical_worktree` works everywhere the name is known,
not just inside `add`.

Call-site updates (from the current `checkout_dir` usages):

- `populate_checkout_from_head` / bootstrap `reset --hard`: `--work-tree` →
  `canonical_worktree`.
- `materialize_one`: create the container (`canonical_container`), then reconcile
  the symlink against `canonical_worktree`; `mkdir -p` the worktree dir before
  populating/symlinking.
- `run_passthrough`: existence guard, `cd`, and `--work-tree` → `canonical_worktree`;
  the "no checkout" error message points at the worktree path.
- `cmd_show`: `checkout:` prints the worktree path; link comparison uses it.
- `cmd_list`: link comparison uses `canonical_worktree`.
- `cmd_add`: container `mkdir` and the made_ckout emptiness check operate on the
  container; the "both have content" / bootstrap-clobber checks operate on the
  worktree.
- `rollback_add`: removes the whole container (`rm -rf <container>`), which
  also removes the nested worktree — equivalent in spirit to today's
  `rm -rf checkout_dir`.

Edge: an empty container with no worktree dir yet is the fresh state; helpers
`mkdir -p` the worktree dir as needed. The container's own emptiness (used by
`made_ckout` rollback bookkeeping) is judged before the worktree dir is created.

## Migration (existing nooks)

The on-disk layout changes for already-materialized nooks:
`beads.nook/issues.jsonl` → `beads.nook/.beads/issues.jsonl`. `materialize`
must detect the **old flat layout** (container holds tracked files directly,
no nested `<basename(dir)>/` dir) and migrate it:

1. Create the nested `<basename(dir)>/` dir inside the container.
2. Move the flat checkout's entries (incl. dotfiles, subdirs like `.br_history/`,
   the DB, lock files) down into it.
3. Repoint the per-worktree symlink from the container to the nested dir.

This is local relayout only — the ref content is identical, so no
commit/push/pull is needed. It runs idempotently and follows the same shape as
the existing legacy-real-dir migration already in `materialize_one`.

Detection rule (unambiguous): the nook is **already migrated** iff the symlink
resolves to `canonical_worktree` (the nested path). Otherwise, if the symlink
(or a real dir) resolves to `canonical_container` and that container holds
entries, it is the **old flat layout** and must be migrated. Keying on the
symlink's resolved target — container vs. nested — avoids the false positive
where a tracked file or subdir happens to share `basename(dir)`'s name: the
decision never inspects the *contents'* names, only which of the two known
paths the symlink points at.

Cross-machine: each machine runs `git nook materialize` (already the documented
step after clone / `worktree add`), which performs the migration on first run.
No coordinated flag day; old and new machines interoperate because the ref is
unchanged — only the local on-disk arrangement differs.

## Tests (`tests/run.sh`)

New:

- Symlink resolves to a directory whose basename equals `basename(--dir)`
  (assert for `--dir .beads`, dotless `--dir notes`, multi-segment `--dir a/b/c`
  → leaf `c`).
- `--work-tree` tracks bare paths: after a commit, `ls-tree` shows
  `issues.jsonl` (or equivalent) with no `<basename>/` prefix — ref layout
  unchanged.
- `materialize` migrates an old flat checkout to the nested layout: seed a
  container with files at top level + a symlink to the container, run
  `materialize`, assert files moved into `<basename>/`, symlink repointed, no
  data lost, idempotent on a second run.
- Container vs worktree: rollback (`add` bootstrap failure) removes the whole
  container.

Update:

- Existing assertions that reference the checkout path switch to the nested
  worktree path (`show` `checkout:` line, any `.nook/` path checks).

## Docs

- README "How it works" three-path diagram: show the container + nested content
  dir + symlink target.
- `git nook -n <name> show` `checkout:` field now prints the nested path;
  update any doc that quotes it.
- Separate finding (not this change): `merge-issues.sh` on the beads nook uses
  stale `git nook beads ...` grammar and must move to `-n beads run`. Track
  independently; it rides the same "beads usable again" milestone.

## Out of scope

- br-specific magic-name handling in git-nook.
- Published-ref path-prefix changes.
- Hard-link based content sharing.
- The stale installed-binary drift and `merge-issues.sh` grammar fixes (separate
  findings, filed once beads is usable again).
