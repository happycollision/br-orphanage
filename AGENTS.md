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
git nook beads add --all          # Stage issue data in the nook
git nook beads commit -m "issues" # Commit it (skip if nothing changed)
git nook beads push               # Publish the hidden ref
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
never appears in branch listings or default clones.

This project's own issues (beads) are tracked in exactly such a nook:

```bash
git nook list                 # see this repo's nooks (expect: beads)
git nook beads status         # any git command works against the nook
```

The daily beads flow on this repo:

```bash
br sync --flush-only          # beads DB -> .beads/issues.jsonl
git nook beads add --all
git nook beads commit -m "issues"
git nook beads pull --no-rebase   # only needed when another machine pushed
git nook beads push
```

If a pull merges `issues.jsonl` from another machine, do NOT hand-resolve
JSONL conflicts; run the helper script committed on the beads nook itself
(see `git nook beads ls-files` for its name) — it re-imports through the
real `br` (per-issue, newest-wins, tombstone-protected).

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
  ref received them (`git nook beads show origin/main:issues.jsonl | grep <id>`).
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
any `git nook beads push`, verify the ref actually updated:

```bash
git ls-remote origin 'refs/nook/*'
git nook beads status -sb     # expect: up to date with origin/main
```

If anything seems off, open an issue with `br create` and push the nook.
