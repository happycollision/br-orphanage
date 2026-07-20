# Findings & follow-ups — nested-content-dir work (2026-07-19)

These would normally be `Discovery:` beads issues, but `br` is unusable in this
checkout (NGI-3, see below), so they are recorded here until beads works again.
File them in beads once br-compatibility is resolved, then delete this file.

## BLOCKER — br NGI-3: br refuses any path under `.git/`

The motivating goal was making `br` work against the beads nook. This branch
cleared br's directory-**name** guard (the checkout now resolves to a dir named
`.beads`), and `br where` now succeeds. But `br ready`/`br sync`/`br create`
then fail with:

> Configuration error: Path '.../.git/nook/beads.nook/.beads/issues.jsonl'
> targets git internals - sync never accesses .git/ (safety invariant NGI-3)

br v0.2.16 categorically rejects any path resolving under `.git/`, with no
toggle. git-nook's architecture deliberately puts the checkout under `.git/`
(survives `git clean`, stays hidden). So the two are in hard conflict.

**Decision needed before this branch delivers br value:** either (a) relocate a
nook's checkout OUTSIDE `.git/` (e.g. under the common git dir's parent, or a
configurable location) — which would be a SECOND on-disk layout migration on top
of this one, so it should be decided before putting users through this
migration; or (b) patch/upstream br to allow a configured path under `.git`.
This branch is still independently valuable (correct layout + general
name-sensitive-tool support), but does not achieve br-compatibility alone.

## Discovery: correct-symlink materialize clobbers uncommitted work-tree edits (PRE-EXISTING)

`materialize_one`'s correct-symlink branch calls `populate_checkout_from_head`
(`git checkout -- .`), which discards uncommitted edits to tracked files in the
shared work-tree. Present on master too (pre-existing), but it undercuts this
branch's C1 fix in practice: AGENTS.md tells users to run `git nook materialize`
after `git worktree add`, and that force-checks-out HEAD over every
already-materialized nook's shared work-tree. Consider skipping populate when
the work-tree is non-empty, mirroring the dccabe2 reasoning (migrated/existing
content is authoritative). File as a bug, priority 2. Location: `bin/git-nook`,
correct-symlink branch of `materialize_one`.

## Discovery: interrupted-migration resume double-nests a non-empty partial work-tree

When the flat→nested migration resumes with a NON-empty partial `checkout_dir`
present, loop 1 moves the whole partial work-tree dir into the stage as a
subdirectory and loop 2 moves it back one level too deep
(`checkout_dir/<basename>/already-moved.txt`). Data is preserved, never lost;
recovery is a manual un-nest. Already acknowledged by a code comment
("an interruption mid-move may leave a nested dir to un-nest by hand"). The
d4ddd6a fix makes this resume path reachable in more cases (previously some were
mis-routed to repoint-only). Low priority (rare interruption window, no data
loss). File as a chore/bug, priority 3. Location: `bin/git-nook`, resume/stage
loops of `materialize_one`.

## Discovery: `.git-nook-migrate` staging name is reserved-by-assumption

The migration staging dir is `${container}/.git-nook-migrate`. If an inner repo
ever tracked an entry by that exact name, behavior is undefined-ish (a tracked
file there would fail the `mkdir -p` safely; a tracked dir could interact with
staging). Vanishingly unlikely; documented as "reserved by git-nook, assumed
absent from tracked content". File as a docs/chore note, priority 4.

## Discovery: `cmd_add` `--dir foo/.` slips validation

`cmd_add`'s dir-validation case patterns reject `..` forms but not a trailing
`/.`, so `--dir foo/.` yields `canonical_worktree` == container, which would
perpetually re-trigger the migration path. Partly pre-existing input-validation
looseness. Priority 3, `bin/git-nook` `cmd_add` validation block.
