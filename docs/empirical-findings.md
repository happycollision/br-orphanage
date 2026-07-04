# Empirical findings (br 0.2.16)

Behaviors of the real `br` binary that `br-orphanage` relies on, verified by
observation. These are background rationale for the sync logic described in
the [README](../README.md); they don't change how you use the tool.

- `br init` does **not** touch a top-level `.gitignore` at all (it only
  creates `.beads/`, which has its own internal `.beads/.gitignore`). The
  wrapper's snapshot/revert logic is a safety net for a behavior the older
  Go `bd` had, kept in case a future `br` reintroduces it.
- Tombstone protection is real: importing a stale pre-deletion snapshot
  reports "Tombstone protected" and does not resurrect the issue.
- `br sync --import-only` and `--flush-only` never touch
  `interactions.jsonl` at all — verified by truncating it and running both;
  it stayed untouched. That file is written only by `br audit record`, so
  it's resolved by the three-way rule like `config.yaml`/`metadata.json`,
  never by import.
- Tombstones serialize asymmetrically: the machine that deletes an issue
  exports its tombstone without `closed_at`, but a machine that imports
  that tombstone backfills `closed_at` and exports it with the field
  present. Without a countermeasure this flaps the published tree hash
  between machines on every alternate sync — see "byte-convergence
  adoption" in the README.
- A non-forced `br sync --flush-only` only exports rows it considers dirty.
  After an inbound merge clobbers `issues.jsonl` with the remote's version
  and imports it, a non-forced flush would silently omit local issues that
  were already flushed (and thus non-dirty) before the merge. The wrapper
  always force-flushes after an inbound merge to guarantee a full,
  correct union.
</content>
</invoke>
