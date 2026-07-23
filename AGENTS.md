<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status                        # Check what changed
git add <files>                   # Stage code changes
br sync --flush-only              # Export beads changes to JSONL
git nook -n beads run add --all          # Stage issue data in the nook
git nook -n beads run commit -m "issues" # Commit it (skip if nothing changed)
git nook -n beads run push               # Publish the hidden ref
git commit -m "..."               # Commit code
git push                          # Push code
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->

## This project

...develops `git-nook` ("git for a hidden directory"): real git tracking for
files the host repo cannot track, hidden in an inner repository under
`.git/nook/<name>.git` and published to a custom ref (`refs/nook/...`) that
never appears in branch listings or default clones. The nook's *checkout*
(the actual files) no longer lives under `.git/` — see "Worktrees" below;
only the inner repo (objects/refs) does.

> **✅ `br` WORKS on this repo's own beads nook again (as of 2026-07-22).**
> The root cause that broke `br` everywhere — a nook's checkout living under
> `.git/`, which trips `br` v0.2.16's hard "never touch `.git/`" invariant
> (**NGI-3**): *"Path '.../.git/nook/.../issues.jsonl' targets git internals -
> sync never accesses .git/ (safety invariant NGI-3)"* — is fixed by the
> worktree-home layout (see "Worktrees" below): a nook's checkout is now a real
> directory OUTSIDE `.git/`, so `br` reads and writes it normally. This repo's
> own `beads` nook was migrated to that layout on 2026-07-22, and `br ready` /
> `br create` / `br sync` / `br where` all work here now. The full `br`
> workflow and session protocol above are live again.
>
> **Two caveats while the fix is unmerged:**
> 1. The fix lives on branch **`feat/nook-worktree-home`** (not yet merged to
>    master). The **installed** `git-nook` is stale (`post-v0.3.0-dev`, from
>    before the branch) and still uses the old `.git/`-checkout behavior — so
>    run nook commands via **`./bin/git-nook`** from the repo root, NOT the
>    installed `git nook`, until the branch merges and you reinstall via
>    `./install.sh`. (A plain installed `git nook materialize` would try to put
>    the checkout back under `.git/`.)
> 2. The migrated `.beads` checkout is a real directory at `<repo>/.beads`
>    (home recorded in local-only `nook.<slug>.home`). Other machines/clones
>    must upgrade to the worktree-home git-nook and run `git nook materialize`
>    before touching beads there.
>
> Background: the `feat/nook-nested-content-dir` branch fixed a *separate* `br`
> guard (directory name must be `.beads`/`_beads`) by nesting the content dir;
> clearing that guard surfaced NGI-3 underneath, which the worktree-home layout
> (this section) resolved at the tool level. See
> `docs/superpowers/specs/2026-07-19-nook-nested-content-dir-FINDINGS.md` for
> the original write-up; its follow-up Discoveries are now filed in beads
> (`br-orphanage-vs4`, `-mrt`).

This project's own issues (beads) are tracked in exactly such a nook:

```bash
git nook list                 # see this repo's nooks (expect: beads)
git nook -n beads run status  # any git command works against the nook
```

> **Note:** this repo's own `beads` nook is fully migrated as of 2026-07-22 —
> both the identity/slug layout (config is slug-keyed
> `nook.beads.86d.happycollision.git_nook.dir`) and the worktree-home checkout
> relocation (`.beads` is now a real directory outside `.git/`, home recorded
> in local-only `nook.<slug>.home`). `br` works here. Use `./bin/git-nook`
> until `feat/nook-worktree-home` merges (see warning above).

The daily beads flow on this repo (working again — use `./bin/git-nook` until
the branch merges; substitute `git nook` once reinstalled):

```bash
br sync --flush-only          # beads DB -> .beads/issues.jsonl
./bin/git-nook -n beads run add issues.jsonl
./bin/git-nook -n beads run commit -m "issues"
./bin/git-nook -n beads run pull --no-rebase   # only needed when another machine pushed
./bin/git-nook -n beads run push
```

If a pull merges `issues.jsonl` from another machine, do NOT hand-resolve
JSONL conflicts; run the helper script committed on the beads nook itself
(see `git nook -n beads run ls-files` for its name) — it re-imports through the
real `br` (per-issue, newest-wins, tombstone-protected).

### Worktrees

A nook's inner repo (`.git/nook/<slug>.git`, the objects/refs) lives once in
the common git dir and is shared by every worktree. Its *checkout* — the
actual files — is a real directory (the "primary home") at `<toplevel>/<dir>`
in whichever worktree first created or adopted it; that location is recorded
in local-only git config `nook.<slug>.home` and is never pushed to a remote.
Every other worktree exposes the same nook as a symlink to that home instead
of a second copy — there is still exactly one live checkout.

After a fresh `git clone`, or after `git worktree add <path>`, run
`git nook materialize` in that working tree:

- If that worktree is the recorded home, it ensures the real directory is
  present (restoring content from the inner repo if the dir was emptied).
- If another worktree owns the recorded home, it creates a symlink here to
  that home.
- If the recorded home has vanished (its worktree was removed, or its content
  dir was deleted), it **promotes** this worktree: re-checks-out HEAD from the
  surviving inner repo and re-records `nook.<slug>.home` to point here.

Thereafter `git nook` and `br` work normally from that worktree. All
worktrees still share one nook state — one inner repo, one live checkout.

## Planning (designs and implementation plans)

Track designs and implementation plans **in beads**, not as committed markdown in
`docs/plans/` on `master`. The whole point of this tool is tracking project work
without leaving a trace on the main repo — so planning artifacts belong on the
beads nook, and `master` stays pristine. (Bonus: it dogfoods the tool.)

- Model a design as an `epic`, and each plan step as a child `task`/`feature` via
  `br create --parent <epic>`.
- Chain the steps with `blocks` deps (`br dep add <step> <prev-step>`) so
  `br ready` surfaces one step at a time, in order. Split a step into subagent
  sub-tasks as further children when needed.
- Beads descriptions are plain-text JSONL (not rendered markdown), and the issue
  is the *only* record — so inline the full detail: files touched, key code, exact
  test assertions.
- After creating them, publish via the session protocol and verify the nook's
  ref received them (`git nook -n beads run show origin/main:issues.jsonl | grep <id>`).
  Do **not** commit the design/plan markdown to `master`.

## Discoveries (follow-ups, out-of-scope work, tangents)

Any follow-up, out-of-scope work, or tangential discovery you make while working
— a deprecation warning, a refactor you resisted, a bug you noticed but didn't
fix, a "we should probably..." — must be filed as a **`Discovery:`** issue in
beads rather than dropped in chat or a commit message. Prefix the title with
`Discovery:` so they're greppable (`br search "Discovery:"`).

- Create with `br create --title="Discovery: <what>" --type=<bug|task|chore|docs>
  --priority=<0-4>`.
- **Include all relevant context in the description** — beads is the only record.
  Inline: where you found it (file:line, PR, commit SHA), why it's out of scope
  of the current work, what you'd do to address it, and any verification already
  done. Someone should be able to act on it without this conversation.
- File it when you find it; don't wait for session end. Then publish via the
  session protocol so it survives.

## Observation

Since we develop `git-nook`, always use it and observe its behavior. After
any `git nook -n beads run push`, verify the ref actually updated:

```bash
git ls-remote origin 'refs/nook/*'
git nook -n beads run status -sb  # expect: up to date with origin/main
```

If anything seems off, open an issue with `br create` and push the nook.
