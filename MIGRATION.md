# git-nook migration: legacy layout -> universal identity

**AGENT INSTRUCTIONS: Do NOT perform any step below until the human has
explicitly said to proceed. Detecting a legacy layout means you should TELL
the user a migration is available and then WAIT. Migration rewrites refs and
moves local directories; it must be a deliberate, confirmed action. Never
auto-migrate.**

## What changed

Older nooks were identified only by a bare `name`:

- config: `nook.<name>.dir`
- inner repo: `.git/nook/<name>.git`
- container: `.git/nook/<name>.nook/<base>/`
- remote ref: `refs/nook/<owner>/<project>/<name>` (a single ref, content only)

The new layout gives each nook an immutable UUID and a slug
`<name>.<id3>.<owner>.<repo_dir>` used everywhere, plus a per-nook manifest ref
and a rebuildable collection index:

- config: `nook.<slug>.dir`
- inner repo: `.git/nook/<slug>.git`
- container: `.git/nook/<slug>.nook/<base>/`
- remote refs: `refs/nook/<slug>/files`, `refs/nook/<slug>/manifest`,
  and `refs/nook/index`

> **Note (superseded by the worktree-home layout):** the "container:
> `.git/nook/<slug>.nook/<base>/`" line above describes where the nook's
> checkout lived at the time the identity migration was written. That is no
> longer where the checkout lives — see "Migrating a nook's checkout out of
> `.git/` (worktree-home layout)" below. Only the inner repo
> (`.git/nook/<slug>.git`) still lives under `.git/`; the identity fields
> (slug, config key, remote refs) described in this section are unaffected
> and unchanged.

## Before you start

- Migrate a nook only after EVERY machine that uses it has upgraded git-nook to
  the universal-identity version.
- The old ref and the new refs can coexist. Keep the old ref until the new one
  is confirmed good on all machines; only the final cleanup step is destructive.
- Ensure all local work is committed and pushed on the OLD ref first, so nothing
  is lost.

## Migration steps (run ONLY after explicit user confirmation)

For each legacy nook `<name>` with content dir `<dir>` and remote `<url>`:

**Naming note — read this before running anything:** while old and new nooks
coexist, `nook.<name>.dir` (the legacy exact config key) and
`nook.<newslug>.dir` (the new slug) are BOTH configured. `git nook -n <name>`
does an exact-key match before prefix resolution, so for as long as the legacy
key exists, `-n <name>` (the bare name) ALWAYS resolves to the OLD/legacy
nook — never the new one. Always address the new nook by its FULL SLUG (from
`git nook list`, e.g. `-n <name>.<id3>.<owner>.<repo>`, or an unambiguous
longer prefix that isn't just `<name>`) for every step below. Only after step
7 removes the legacy config key does the bare `<name>` become free to resolve
to the new nook again.

1. Commit and push any pending work on the OLD nook so the old ref is current:
   `git nook -n <name> run status`
   (commit + push anything outstanding to the old ref). This is the one step
   that is SUPPOSED to hit the legacy nook.

2. Record the old remote URL and old ref:
   `git --git-dir=.git/nook/<name>.git config --get remote.origin.url`
   old ref: `refs/nook/<owner>/<project>/<name>` (as configured in that repo).

3. Initialize a NEW nook under the universal identity, into a temporary dir so
   it can't collide with the live one:
   `git nook init <name> <url> --dir <dir>.migrating`
   Immediately run `git nook list` and note the full slug it was assigned,
   e.g. `<newslug>` = `<name>.<id3>.<owner>.<repo>`. Use `<newslug>` — never
   the bare `<name>` — for every remaining step until step 7c below.

4. Import the old history into the new inner repo:
   `git --git-dir=.git/nook/<newslug>.git fetch <url> \
        'refs/nook/<owner>/<project>/<name>:refs/heads/imported'`
   Then set the new main to the imported history (fresh nook has an empty main):
   `git --git-dir=.git/nook/<newslug>.git update-ref refs/heads/main imported`
   `git nook -n <newslug> run reset --hard main`

5. Publish the new refs:
   `git nook -n <newslug> run push`
   Verify:
   `git ls-remote <url> 'refs/nook/<newslug>/*'`
   `git ls-remote <url> refs/nook/index`

6. Confirm the new nook's content looks right (diff it against the old
   content dir, spot-check history, whatever gives confidence) and confirm it
   is good on ALL machines that use this nook before proceeding — nothing
   past this point is reversible without the old ref, which is still intact.

7. Once — and only once — the new nook is confirmed good everywhere, retire
   the OLD nook and promote the new one into the real content dir, in this
   order:
   a. Remove the NEW nook's temporary registration (this deletes only the
      `.migrating` bookkeeping; the new ref published in step 5 is untouched
      because it lives on the remote, not in this local checkout):
      `git nook -n <newslug> remove`
      then remove the now-unused `<dir>.migrating` symlink/dir if anything
      remains locally.
   b. Delete the OLD remote ref (destructive; do this only now):
      `git push <url> --delete refs/nook/<owner>/<project>/<name>`
   c. Delete the OLD local layout, freeing the bare `<name>` and the real
      `<dir>`:
      `git config --remove-section nook.<name>`
      `rm -rf .git/nook/<name>.git .git/nook/<name>.nook`
      remove the old `<dir>` symlink/content if still present.
   d. Clone the new nook into the now-free real dir (picks up `<newslug>`
      from the index automatically):
      `git nook clone <name> <url> --dir <dir>`

8. Rebuild the index to reflect the final state:
   `git nook reindex`

## Migrating a nook's checkout out of .git/ (worktree-home layout)

**What changed and why.** Nooks used to check their content out at
`.git/nook/<slug>.nook/<base>/`, under `.git/`. The `br` tool (beads_rust)
enforces a hard safety invariant (NGI-3) that refuses to read or write ANY
path with a literal `.git` path component — no toggle, no exception — so `br`
could never operate on a nook's content while it lived there. Now the
checkout is a REAL directory at `<toplevel>/<dir>` in whichever worktree
first created or adopted it (the nook's "primary home"), recorded in
LOCAL-ONLY git config `nook.<slug>.home` (an absolute path, never pushed to
any remote). Only the INNER repo (`.git/nook/<slug>.git`, the object store
and refs) still lives under `.git/`; the checkout itself does not, and `br`
now works against it normally.

**The common case — adopting an existing nook whose content dir is already a
real directory.** A nook created before this feature has no
`nook.<slug>.home` recorded. If `<toplevel>/<dir>` is ALREADY a real
directory (not a symlink) with content whose history matches the inner
repo, migration for it is simply:

```bash
git nook materialize
```

`materialize` auto-adopts it in place: it records `nook.<slug>.home` pointing
at that directory and does nothing else — it does not move, recreate, or
clobber any file. This is unlike the identity migration above (which
rewrites refs and reassigns directories); adoption only records a piece of
local config, so it is safe to run without the step-by-step confirmation
ceremony required above. **Still check with the user before running it on a
nook you didn't create**, per this file's general posture — but understand
that "adoption" itself carries none of the risk that the identity migration
does.

**The container-symlink case — content dir is a live symlink into the old
nested-content-dir container.** Many pre-worktree-home nooks are NOT a real
directory yet: `<toplevel>/<dir>` is a live symlink resolving to
`.git/nook/<slug>.nook/<base>/` (the container layout from the section
above). `materialize` correctly REFUSES to elect through a live symlink —
following it would check content out into that `.git`-nested target and
record it as the home, silently defeating the entire point of this feature
(NGI-3 forbids any `.git` path component). "Simply `git nook materialize`"
is NOT enough here; do this instead (the refusal itself also prints these
exact steps, with your real paths substituted in):

```bash
rm <toplevel>/<dir>                                   # the symlink only
mkdir -p <toplevel>/<dir>
mv .git/nook/<slug>.nook/<base>/* <toplevel>/<dir>/    # preserves uncommitted work
git nook materialize                                  # adopts <toplevel>/<dir> as the home
```

Step 2's `mv` moves the container's content — not the container itself —
into the new real directory, so any uncommitted edits sitting in the old
container come along intact. Once `<toplevel>/<dir>` is a real directory
with that content in it, the third step is the same safe, config-only
adoption described in the common case above.

**Other worktrees, and a fresh clone.** Run `git nook materialize` in any
worktree that doesn't yet have the nook's files:

- If another worktree already owns the recorded home, `materialize` creates a
  symlink to it — the nook's content is still one shared checkout, just
  exposed in more places.
- If the recorded home has vanished (e.g. the worktree that held it was
  removed, or its content dir was deleted), `materialize` PROMOTES the
  current worktree: it re-checks-out HEAD from the surviving inner repo and
  re-records `nook.<slug>.home` to point here.

A nook subcommand (`run`, `remove`, `destroy`) whose recorded home has
vanished will abort with a hint to run `git nook -n <name> materialize`
first, rather than silently doing the wrong thing.

**The `git clean -x` caveat.** Because the primary home is now a real,
host-visible directory in the working tree (hidden from the host repo only
via `.git/info/exclude`, not via location), it IS reachable by `git clean
-x` (which also removes ignored/excluded files). This is intrinsic to fixing
NGI-3 — `br` needs to read the file as an ordinary path, so it cannot be
hidden under `.git/` anymore, and no other location choice avoids this.
Losing the checkout this way is recoverable: run `git nook -n <name>
materialize` again to re-check-out from the surviving inner repo. As with
any git checkout, only uncommitted edits in that working copy are lost —
anything committed to the nook's inner repo survives and comes back.

## If in doubt

Stop and ask the user. Keep the old ref. The old and new nooks can coexist
indefinitely; nothing is lost until step 7.
