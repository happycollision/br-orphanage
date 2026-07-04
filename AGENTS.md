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
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->

## This project

...is a wrapper for `br`. Everything above is true, but this project also adds a subcommand called `orphanage` (or `o` for short) to the `br` utility.

`br orphanage --help` for details.

This project's own issues are tracked on an orphan branch using this tool.

`br orphanage sync` runs `br sync --flush-only` under the hood, then manages actually syncing to origin. (So yes, these commands do in fact run some git commands, contrary to the docs for `br` proper.)

In a nutshell, the point of this project is to give users a nice, repeatable way to use beads on repos where they don't want to leave a trace of the fact that they use beads at all. (You can, after all, target a completely separate repo for your beads sync, unlike this one.)

## Observation

Since we develop this `br-orphanage` tool, it is important that we use it and always observe its behavior. Whenever you use the tool, check that it actually did what you expected it to do. For example, if you run `br o sync`, please check that the orphan branch you expect gets the changes you expect. If anything seems off, open an issue using beads.

Any time you use beads, please then run `br o sync`. We always want the remote orphan branch to get all our issues.