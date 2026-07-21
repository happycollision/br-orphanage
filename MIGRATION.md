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

## If in doubt

Stop and ask the user. Keep the old ref. The old and new nooks can coexist
indefinitely; nothing is lost until step 7.
