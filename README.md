# git-nook

**Git for a sub directory you don't want others to deal with.**

`git-nook` gives a directory of files real git tracking — status, commits,
diffs, log, branches, merges, conflicts, push, pull — even when the host
repo cannot or should not track them itself. Each tracked directory (a
"nook") is backed by a genuine git repository hidden inside the host repo's
`.git/`, and published to a custom ref that appears in no branch listing, no
host web UI, and no default clone. Once a nook exists, every day-to-day
operation is a plain git command you already know; the tool's only jobs are
creating nooks and handing your git invocations to the right one.

When you add a nook, you don't have to also PR a new line in `.gitignore`.
Instead, `git-nook` updates your local `.git/info/exclude` and you can get to
work instead of do the PR song and dance.

This is ideal for your personal IDE settings, planning documents, or anything
that is specific to you and not something you want to foist upon your
collaborators.

Nooks can be stored at the origin of the repo your are working on, or you can
go fully external and point your Nook's upstream at any repo you have write
access for.

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

### Versioning

`git nook --version` reports what it was built from: `git-nook vX.Y.Z` for
a tagged release, `git-nook post-vX.Y.Z-dev` for a checkout or install
built on top of release `X.Y.Z` (i.e. master since that release), and
`git-nook v0.0.0-dev` only for raw, un-stamped source. The version string
is stamped into the installed copy at install/release time; the committed
source itself is never mutated.

## Quick start

```sh
git nook add notes origin
```

This creates a hidden inner git repository for a nook named `notes`, wires
its remote to a custom ref on `origin`, and gives you the nook's files at
`.notes/` (a symlink into the shared checkout, excluded from the host repo
via `.git/info/exclude`, so `git status` in the host repo never mentions
it). Edit files there like any other directory:

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

After a plain `git clone` of the host repo, the nook's config comes along
but its worktree symlink doesn't — run `git nook materialize` once to link
every configured nook (`.notes/` and friends) into the fresh clone.
Likewise, after `git worktree add <path>`, run `git nook materialize`
inside that new worktree to create its symlinks; every worktree then
shares the same underlying nook checkout.

## How it works

A nook is three paths:

```
.git/nook/notes.git    # the inner bare repository (hidden inside your .git)
.git/nook/notes.nook/  # the one real checkout, shared by every worktree
.notes/                # a symlink to the checkout above; excluded via .git/info/exclude
```

The real files live once, under `.git/nook/<name>.nook/` in the host repo's
*common* git dir. Each worktree of the host repo exposes those files
through a plain symlink at the configured path (`.notes/` by default) —
the symlink itself, not a directory, is what's excluded via
`.git/info/exclude`, so `git status` in the host repo never mentions it.
Because every worktree's symlink points at the same checkout, `git
worktree add` and any other linked worktree all see the same nook state:
one checkout, one set of refs, one `HEAD`. Run `git nook materialize` in a
worktree that doesn't have the symlink yet (see "Quick start" and
"Commands" below).

`.notes/` has no `.git` file of its own — `git nook add` never runs a
plain `git init` inside the content dir, so the host repo sees only a
plain excluded symlink: no gitlink, no submodule confusion, no trace that
another repository is involved at all. The inner repository is reachable
only through the wrapper:

```
git nook <name> <any-git-args...>
# ≈ git --git-dir=.git/nook/<name>.git --work-tree=.git/nook/<name>.nook <any-git-args...>
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
--import-only` to load the fetched issues into the local database. If
you're instead cloning a repo that already has the nook configured (or
adding a worktree with `git worktree add`), skip straight to `git nook
materialize` to link `.beads/` into place.

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
git nook materialize             # link configured nooks into this worktree
git nook <name> <git-args...>    # run any git command against the nook
git nook --help | --version
```

`add` creates and wires a nook; `list` shows every nook configured in the
current repo (flagging any that aren't linked into the current worktree);
`show <name>` prints its resolved checkout path, link state, remote URL,
push refspec, and current branch/tracking state; `remove <name>` drops the
nook's config entry and exclude line but — deliberately — never deletes the
checkout or the inner repo's history, so nothing is destroyed silently;
`materialize` creates the missing symlink(s) for already-configured nooks
in the worktree you run it from — use it after `git clone` or after `git
worktree add`; everything else is passthrough git.

## Releasing

Maintainer procedure for cutting a release:

1. Bump the `VERSION` file to the new number (e.g. `0.3.0`) and commit it
   on master.
2. Tag it and push the tag:

   ```sh
   git tag v0.3.0
   git push origin v0.3.0
   ```

   The tag must be `v` + the exact contents of `VERSION`; a mismatch fails
   the release.
3. The tag push triggers the Release workflow, which verifies the tag
   matches `VERSION`, runs shellcheck and the test suite, stamps a clean
   `vX.Y.Z` into a built copy of `bin/git-nook`, generates
   `git-nook.sha256`, and publishes both as a GitHub Release.
4. `install.sh` always fetches the latest published release, so the
   curl one-liner picks up the new version immediately.
5. Until the next bump, master-checkout builds report
   `post-vX.Y.Z-dev` — built on top of the release you just shipped.

Every push to master and every PR also runs shellcheck and the test suite
via CI, independent of releasing.

## Privacy model

`git-nook` hides content from *view*, not from *access*. A hidden ref is
absent from branch listings, host web UIs, and default clones, but it is
still an ordinary ref on whatever remote you targeted — anyone who already
has read access to that remote can enumerate it with `git ls-remote` and
fetch it like any other ref, and nothing about the content is encrypted.
Choose the target accordingly: same-repo `origin` for "keep this out of my
way," a private repo you control for real access-control separation.
