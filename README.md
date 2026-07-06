# git-nook

**Git for a hidden directory.**

`git-nook` gives a directory of files real git tracking — status, commits,
diffs, log, branches, merges, conflicts, push, pull — even when the host
repo cannot or should not track them itself. Each tracked directory (a
"nook") is backed by a genuine git repository hidden inside the host repo's
`.git/`, and published to a custom ref that appears in no branch listing, no
host web UI, and no default clone. Once a nook exists, every day-to-day
operation is a plain git command you already know; the tool's only jobs are
creating nooks and handing your git invocations to the right one.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/happycollision/git-nook/master/install.sh | bash
```

This installs `git-nook` to `~/.local/bin/git-nook` (override with
`GIT_NOOK_INSTALL_PATH`), making it callable as `git nook` anywhere git looks
for subcommands on your `PATH`. Running the one-liner again upgrades it in
place.

From a checkout of this repo, run the local copy instead of downloading a
release:

```sh
./install.sh
```

## Quick start

```sh
git nook add notes origin
```

This creates a hidden inner git repository for a nook named `notes`, wires
its remote to a custom ref on `origin`, and gives you a worktree at
`.notes/` (excluded from the host repo via `.git/info/exclude`, so `git
status` in the host repo never mentions it). Edit files there like any
other directory:

```sh
echo "today's notes" > .notes/today.md
git nook notes status
git nook notes add --all
git nook notes commit -m "today's notes"
git nook notes push
```

On another machine (or a fresh clone of the host repo), one command
bootstraps the whole thing — inner repo, exclude entry, and content —
straight from the published ref:

```sh
git nook add notes origin
```

If the ref already has history, `add` fetches it and materializes `.notes/`
automatically; there's nothing else to run.

## How it works

A nook is two paths:

```
.git/nook/notes.git   # a real git repository (hidden inside your .git)
.notes/               # its worktree; excluded via .git/info/exclude
```

`.notes/` has no `.git` file — `git nook add` never runs a plain `git init`
inside it, so the host repo sees only plain excluded files: no gitlink, no
submodule confusion, no trace that another repository is involved at all.
The inner repository is reachable only through the wrapper:

```
git nook <name> <any-git-args...>
# ≈ git --git-dir=.git/nook/<name>.git --work-tree=<content-dir> <any-git-args...>
```

So `git nook notes log -p`, `git nook notes branch`, `git nook notes stash`
— anything git can do — works exactly as it would in a normal checkout.
Local branches, stash, reflog, your merge tool: all available. The one
branch-shaped constraint is that publication is single-ref — `add` bakes a
push refspec that always publishes the inner repo's `main` branch to one
custom ref, so `push`/`pull` and tracking output (`ahead 1`, `behind 2`)
work out of the box without you configuring anything.

Conflicts are ordinary git conflicts: markers land in your working files,
you resolve them with whatever tooling you already use, and you commit the
resolution — no special merge mode, no policy machinery.

## Choosing a target and ref

`git nook add <name> <target> [--dir <dir>] [--ref <template>]`

`<target>` is either the name of an existing remote in the host repo (most
commonly `origin`) or a literal git URL, resolved to a URL once, at `add`
time.

- **Same-repo `origin` (the default posture)** — hidden in plain sight.
  Nothing shows up in branch listings or the web UI, but anyone with read
  access to the repo can still discover the ref with `git ls-remote
  origin`. This is the right choice when the goal is keeping clutter out of
  normal git workflows, not restricting who can see the content.
- **A private repo you own** — full access-control separation. Point
  `add` at a URL (or a remote name) for a repo whose access list you
  control independently of the host repo's. The host repo stays exactly as
  traceless either way; only the target changes.

By default the published ref is `refs/nook/<owner>/<project>/<name>`, with
`<owner>` and `<project>` derived from the host repo's `origin` URL. Pass
`--ref` to override the template:

- A value starting with `refs/` is used verbatim — e.g. `--ref
  refs/heads/notes` publishes to a normal, browsable branch instead of a
  hidden custom ref.
- Anything else is treated as a branch name and prefixed with
  `refs/heads/` automatically (useful for hosts that restrict which ref
  namespaces can be pushed).

`--dir` sets the content directory (default `.<name>/`); use it to put a
nook's files somewhere other than the default, e.g. `--dir .beads`.

## Worked example: hidden issue tracking with beads

A common motivating case: tracking [beads](https://github.com/Dicklesworthstone/beads_rust)
(`br`/`bd`) issues for a project without adding a `.beads/` directory to the
project's own git history. Point a nook's content dir straight at `.beads`:

```sh
git nook add beads origin --dir .beads
```

`br` already ships its own `.beads/.gitignore` that excludes local state
(`*.db*`, lock files, daemon files, and so on) — the inner repo honors it
natively, since filtering authority always belongs to the nook's own
`.gitignore`. The one thing worth excluding from tracking entirely is that
`.gitignore` file itself, since `br` regenerates it and syncing it across
machines just invites version churn. Add one line to the *inner* repo's own
exclude file (not the host repo's `.git/info/exclude`, which never applies
here):

```sh
echo .gitignore >> "$(git rev-parse --git-common-dir)/nook/beads.git/info/exclude"
```

A typical session:

```sh
br sync --flush-only          # flush the local beads DB to issues.jsonl
git nook beads add --all
git nook beads commit -m "issues"
git nook beads pull            # reconcile if another machine pushed since
git nook beads push
```

On a fresh machine, `git nook add beads origin --dir .beads` bootstraps
`.beads/` from the published ref; run `br init` first if the local `br`
workspace files (config, DB) aren't present yet, then `br sync
--import-only` to load the fetched issues into the local database.

## Prior art

The standard community answers to "track files the host repo can't track"
are: a nested repo in an excluded subdirectory; a separate repo elsewhere
plus symlinks; the classic dotfiles bare-repo trick (`git
--git-dir=<repo> --work-tree=<dir>` behind a shell alias); or a worktree
checked out on a dedicated branch. `git-nook`'s architecture *is* the
bare-repo technique — deliberately, since it's the strongest of the four —
with a few deltas:

- **Remote-side hiding.** The other three approaches still need a second,
  visible repository to push to, which is itself a trace. `git-nook`
  publishes to hidden custom refs on an *existing* remote, even the host's
  own `origin`: no second repo, no branch listing, no UI footprint, same
  transport and credentials you already use.
- **A scoped worktree.** The dotfiles technique sets the whole home
  directory (or repo) as the work-tree and needs
  `status.showUntrackedFiles no` to stay usable, which blinds `status` to
  your own new files and makes `clean` dangerous. A nook's worktree is just
  the content directory, so `status`, `add --all`, and `clean` all behave
  with full fidelity.
- **History survives `git clean -fdx`.** A nested repo's `.git` lives
  inside the host's working tree and dies with an aggressive clean. A
  nook's git-dir lives under the host's own `.git/`, which `clean` never
  touches.
- **One-command setup.** `git nook add` encodes the whole per-machine
  ritual — exclude entry, byte-identity config, refspecs, branch tracking,
  safety refusals, bootstrap from an existing ref — that the alias
  approach leaves as a wiki page for you to remember.

The remaining trade-offs are per-nook choices, not tool limitations:

- **Hidden refs get no host UI.** No web view, no PRs, no CI triggers.
  When browsability matters more than invisibility, `--ref
  refs/heads/...` publishes to a normal branch on the target today.
- **Hidden is not secret.** Anyone with read access to the target can
  `ls-remote` the refs, and nothing is encrypted. When access control
  matters, point `add` at a private target you control — see "Choosing a
  target and ref" above.

## Commands

```
git nook add <name> <target-url-or-remote> [--dir <dir>] [--ref <template>]
git nook list
git nook show <name>
git nook remove <name>
git nook <name> <git-args...>    # run any git command against the nook
git nook --help | --version
```

`add` creates and wires a nook; `list` shows every nook configured in the
current repo; `show <name>` prints its resolved directory, remote URL, push
refspec, and current branch/tracking state; `remove <name>` drops the
nook's config entry and exclude line but — deliberately — never deletes the
content directory or the inner repo's history, so nothing is destroyed
silently; everything else is passthrough git.

## Privacy model

`git-nook` hides content from *view*, not from *access*. A hidden ref is
absent from branch listings, host web UIs, and default clones, but it is
still an ordinary ref on whatever remote you targeted — anyone who already
has read access to that remote can enumerate it with `git ls-remote` and
fetch it like any other ref, and nothing about the content is encrypted.
Choose the target accordingly: same-repo `origin` for "keep this out of my
way," a private repo you control for real access-control separation.
