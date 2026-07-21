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

1. Commit and push any pending work on the old nook so the old ref is current:
   `git nook -n <name> run status`
   (commit + push anything outstanding to the old ref).

2. Record the old remote URL and old ref:
   `git --git-dir=.git/nook/<name>.git config --get remote.origin.url`
   old ref: `refs/nook/<owner>/<project>/<name>` (as configured in that repo).

3. Initialize a NEW nook under the universal identity, into a temporary dir so
   it can't collide with the live one:
   `git nook init <name> <url> --dir <dir>.migrating`

4. Import the old history into the new inner repo (find the new slug via
   `git nook list`):
   `git --git-dir=.git/nook/<newslug>.git fetch <url> \
        'refs/nook/<owner>/<project>/<name>:refs/heads/imported'`
   Then set the new main to the imported history (fresh nook has an empty main):
   `git --git-dir=.git/nook/<newslug>.git update-ref refs/heads/main imported`
   `git nook -n <name> run reset --hard main`

5. Publish the new refs:
   `git nook -n <name> run push`
   Verify:
   `git ls-remote <url> 'refs/nook/<newslug>/*'`
   `git ls-remote <url> refs/nook/index`

6. Move content into the real dir and drop the temporary one:
   remove the new nook's temporary `<dir>.migrating` symlink, reconcile the
   content into `<dir>`, and re-run `git nook materialize` if needed. (Simplest:
   `git nook -n <name> remove` the temp nook after confirming the ref is good,
   then `git nook clone <name> <url> --dir <dir>` into the real dir.)

7. Once the new nook is confirmed good on ALL machines, delete the OLD ref and
   OLD local layout:
   `git push <url> --delete refs/nook/<owner>/<project>/<name>`
   `rm -rf .git/nook/<name>.git .git/nook/<name>.nook`
   `git config --remove-section nook.<name>`

8. Rebuild the index to reflect the final state:
   `git nook reindex`

## If in doubt

Stop and ask the user. Keep the old ref. The old and new nooks can coexist
indefinitely; nothing is lost until step 7.
