# Beads Orphanage (br-orphanage)

A standalone companion command for
[`br`](https://github.com/Dicklesworthstone/beads_rust) that syncs each
project's beads issue data to an **orphan branch** on a git repo you choose,
per project. Issue data never has to live in - or leak from - a repo you
didn't pick for it. The name: orphan branches live in the orphanage.

`br-orphanage` handles orphan-branch setup and publication. Normal issue work
still uses the real `br`: `br ready`, `br list`, `br create`, `br close`, and
the rest of beads' own command surface.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/happycollision/br-orphanage/master/install.sh | bash
```

This installs the command directly to `~/.local/bin/br-orphanage`, creating
`~/.local/bin` when needed, and `chmod +x`s it. It changes no shell startup
files and never installs anything named `br`. If `~/.local/bin` is not on
`PATH`, it prints focused PATH guidance and the full path to invoke instead.
Running it again is safe; it refreshes the executable in place.

To install somewhere else:

```sh
BR_ORPHANAGE_INSTALL_PATH=/opt/bin/br-orphanage bash install.sh
```

For a cautious install, download `install.sh`, inspect it, then run it. Release
downloads verify the `br-orphanage` executable against the release
`br-orphanage.sha256` file. That protects against corrupt downloads or asset
mismatches, but not against a compromised release account that replaces both
files. Once release automation exists, GitHub artifact attestations or
Sigstore/cosign signatures should provide the stronger provenance signal; for
GitHub attestations, the expected shape is `gh attestation verify ... -R
happycollision/br-orphanage`.

Use it directly:

```sh
br-orphanage init
br-orphanage target origin
br-orphanage sync
```

**Local dev mode:** running `install.sh` from a checkout of this repo copies the
local command instead of downloading it, so contributors and the test harness
exercise the local source.

**Update:** To update the command, re-run the one-liner (or `install.sh` in a
checkout). `br-orphanage --version` prints what you currently have installed.

## Quick start

```sh
# Private repo: host issues on the project's own origin.
br-orphanage init --target origin

# Public project: keep issues elsewhere, private.
br-orphanage init --target git@github.com:you/private-issues.git

# Anytime after that:
br-orphanage sync

# Every known project on this machine, in one run:
br-orphanage sync --all

# Normal issue work stays on the real br:
br ready
br list --status=open
br create --title="..." --type=task --priority=2
br close <id> --reason="Completed"
```

## Commands

| Command | Behavior |
|---|---|
| `br-orphanage init [--target <t>] [args...]` | Runs the real `br init`, then reverts any top-level `.gitignore` changes it made (deleting it if it didn't exist before), and adds `.beads/` to the repo's exclude file (`git rev-parse --git-path info/exclude`, worktree/submodule-safe). Unrecognized args pass through to the real init. `--target` sets the sync target inline (stripped before the real init sees the args). |
| `br-orphanage target` | Print the resolved target, URL, and branch. Exits 1 with guidance if unset. |
| `br-orphanage target <remote-or-url> [--branch <template>] [--namespace <ns>]` | Store the target (and optional overrides) in the project's git config. A bare word naming an existing remote is stored as a remote name; anything else is stored as a literal URL. A named remote must exist at set time. |
| `br-orphanage sync` | Converge this project with its orphan branch. Records the project's absolute path in the machine-local index. |
| `br-orphanage sync --all` | Iterate the machine-local index; for each entry, `cd` to the recorded path and sync. Stale/missing paths, non-repos, missing `.beads/`, and unconfigured targets are skipped with a warning rather than failing the run. Exits 0 iff no known project's sync actually failed. |
| `br-orphanage --help` | Print usage. |
| `br-orphanage --version` | Print the wrapper version. Bare `br-orphanage` prints usage (which includes the version). |

## Configuration

Stored in the **project's own git config** (`.git/config`) — per-clone,
machine-local, never committed, so a private target URL never ends up
inside a public project repo.

| Key | Meaning | Default |
|---|---|---|
| `beadsOrphanage.target` | A remote name (resolved to a URL at run time — `origin` naturally means "this project's own repo") or a literal git URL. Precedence is remote-first: a value that names an existing remote wins even if it also looks URL-shaped. | unset → hard error on sync |
| `beadsOrphanage.branch` | Branch-name template. Tokens: `<namespace>`, `<owner>`, `<project>`. | `<namespace>/<owner>/<project>` |
| `beadsOrphanage.namespace` | Value substituted for the `<namespace>` token. | `orphanage` |

`<owner>`/`<project>` are parsed from the **origin** remote URL (e.g.
`git@github.com:happycollision/foo.git` → owner `happycollision`, project
`foo`; `https://` URLs parse the same way; `.git` suffix stripped). With no
origin remote, `<project>` falls back to the toplevel directory name and
`<owner>` falls back to `local`. Tokens never resolve empty.

Configuration is **per-clone**: each new clone or machine runs
`br-orphanage target` once (or passes `--target` to `br-orphanage init`).
That's the point — a private target URL lives only in that machine's
`.git/config`, never in anything committed, so it can't leak through a
public project repo.

## How sync works

Everything happens as plumbing inside the project's own `.git` — no managed
clones, no temporary worktrees, no temp directories. The local ref
`refs/orphanage/pushed` records the commit this machine last published; it
anchors objects against gc and serves as the merge base for divergence
detection and the three-way rule below.

1. Flush the local DB to JSONL (`br sync --flush-only`), resolve the
   target and branch, then fetch the branch tip into a dedicated ref
   (`refs/orphanage/fetched` — never `FETCH_HEAD`, which a concurrent
   unrelated fetch could clobber).
2. If the fetched tip differs from `refs/orphanage/pushed` (the remote has
   changes this machine hasn't merged), merge inbound:
   - **Issues** merge through the real `br`'s own import: per-issue,
     newest-wins, tombstone-protected (see below). The remote's
     `issues.jsonl` is extracted over the local one, `br sync
     --import-only` runs, then `br sync --flush-only --force` re-exports
     the full merged DB. The `--force` matters: a non-forced flush only
     exports *dirty* rows, so without it the just-clobbered file would
     silently drop already-flushed local issues instead of reflecting the
     full post-merge union.
   - **Non-issue files** (`config.yaml`, `metadata.json`, `README.md`, and
     `interactions.jsonl`) use a cheap three-way rule by blob SHA, with
     base = the file's blob in the `refs/orphanage/pushed` tree:
     local-unchanged-since-base takes the remote version (convergence);
     remote-unchanged keeps local (propagates on this sync); both changed
     keeps local **and warns**, e.g. `kept local config.yaml; remote
     version preserved at <tip-sha> — view it with git cat-file blob
     <tip-sha>:config.yaml`. Local wins on conflict because recoverability
     is asymmetric: the remote version is committed on the branch and
     lives in its history forever, while the local edit exists nowhere
     else (`.beads/` is excluded from the project's own git) and would be
     destroyed with no undo.
   - **Byte-convergence adoption:** br 0.2.16 serializes tombstones
     asymmetrically — a machine that *creates* a tombstone (`br delete`)
     exports it without `closed_at`, but a machine that *imports* that
     tombstone backfills `closed_at` and exports it with the field. Left
     alone, this flaps the published tree hash between machines forever.
     So: if the inbound import made no DB changes (no `Created:`/`Updated:`
     lines) and the freshly-flushed file contains exactly the same
     issue-id set as the remote tip's `issues.jsonl`, the wrapper adopts
     the remote file's bytes verbatim — the two files are semantically
     identical at that point and differ only in serialization. Any guard
     failure just degrades to keeping the force-flushed bytes: correct
     union, possibly one extra commit, never data loss.
3. Build a tree from the tracked files present in `.beads/` and compare
   its SHA to the fetched tip's tree. Identical → "Already in sync",
   `refs/orphanage/pushed` advances, no commit. Different → commit (with
   the fetched tip as parent, or no parent for a brand-new branch) and
   push with no force. History on the branch is linear and
   fast-forward-only; a non-fast-forward push rejection means another
   machine synced in the window between fetch and push — the error
   advises re-running.

Tracked files: `config.yaml`, `interactions.jsonl`, `issues.jsonl`,
`metadata.json`, `README.md`. Never synced: `beads.db` (SQLite is local
state; JSONL is the source of truth), `.jsonl.lock` (transient), and
`.beads/.gitignore` (regenerated by init).

## Bootstrap & retargeting

A fresh clone (or a machine that has never synced this project) has no
`.beads/` yet. Set a target and sync:

```sh
br-orphanage target <remote-or-url>
br-orphanage sync
```

This requires the orphan branch to already exist at the target — it
extracts the branch's tracked files into a freshly-initialized `.beads/`
and imports them. For a **brand-new** project with no branch yet, run
`br-orphanage init` (optionally with `--target`) instead, which creates the
orphan root on the first sync.

A bootstrap that fails partway cleans up after itself (removes the
partially-created `.beads/`) rather than stranding the project — just fix
the underlying problem and re-run `br-orphanage sync`.

**Retargeting** is nothing special: set a new target and sync. A branch
that doesn't exist yet at the new target receives the full current state as
its orphan root.

## Privacy notes

- There is **no fallback target**. A project with none configured fails
  sync hard, pointing at `br-orphanage target` — nothing can silently
  publish issue data to an unintended place.
- **Orphan ≠ hidden.** An orphan branch shares no history with any code
  branch, but pushing it to a *public* repo still publishes the issues.
  The explicit, per-project target is the privacy guard — not the branch
  shape.

## Multi-machine notes

- **Version skew:** machines update their wrapper independently, so two
  machines can run different `br-orphanage` versions against the same
  branches. The branch layout is deterministic
  and the payload is just `br`'s own JSONL, so skew is expected to be
  harmless — but nothing enforces lockstep. Re-run the installer on a
  machine to bring it current.
- **Deletions propagate as tombstones**, not absences: `br delete`
  rewrites the JSONL line with `status: tombstone` rather than removing
  it, so the deletion merges like any other change and importing a stale
  pre-deletion snapshot does **not** resurrect the issue (`br` reports
  "Tombstone protected").
- **Avoid `br delete --hard` in multi-machine use.** It prunes the
  tombstone immediately, turning the deletion into a true absence — a
  stale snapshot from another machine that hasn't synced recently *will*
  resurrect it on import.
- No tombstone GC/retention exists in br 0.2.16; tombstones persist until
  hard-pruned. If a future `br` adds auto-expiry, machines that haven't
  synced within the retention window could resurrect old deletions on
  import — worth re-checking this note against future `br` versions.

## The machine-local index

`~/.local/share/br-orphanage/project-paths` (respecting `$XDG_DATA_HOME`) —
one `name<TAB>absolute-path` line per project, written on every successful
sync (including no-ops). It powers `br-orphanage sync --all`, which
iterates it, skipping with a warning (not a failure) for a stale recorded
path, a path that's no longer a git repo, a missing `.beads/`, or a project
with no target configured. Only real per-project sync failures make the
run's exit code nonzero.

## Testing

`tests/run.sh` is a self-contained, sandboxed end-to-end harness: fake
`HOME`/`XDG_DATA_HOME`, bare git repos standing in for every remote (project
origins and orphan-branch targets), and the real `br` binary from your
`PATH` providing all issue-tracker behavior. It never touches your real
home directory, beads data, shell rc files, or any real remote. Run it from
anywhere:

```sh
tests/run.sh
```

It runs `shellcheck` on `bin/br-orphanage`, `install.sh`, and itself when `shellcheck`
is available on `PATH`, skipping gracefully otherwise.

## Further reading

- [Empirical findings (br 0.2.16)](docs/empirical-findings.md) — observed
  `br` behaviors the sync logic depends on.
