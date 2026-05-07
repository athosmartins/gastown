# Post-mortem: deacon rig sync (dc-w7zc)

**Bead:** dc-w7zc
**Operator:** crew/batista (whatsapp_automation rig)
**Started:** 2026-05-07
**Strategy:** fast-forward (zero local divergence)

## Discovery

The deacon rig at `~/gt/deacon/` is **not a separate fork** — it shares the
same `athosmartins/gastown` (fork) and `steveyegge/gastown` (origin) remotes
as the canonical gastown source clone at `~/go/src/gastown/` and the
mayor/rig clone at `~/gt/gastown/mayor/rig/`. It's just a different working
directory on the local filesystem with deacon-specific runtime artifacts
(heartbeat.json, dogs/, mayor/, witness/).

This means the bead's premise — "fazer fork sync similar ao dc-bsza" — was
overstated. There is no separate fork to sync. Only the deacon's local
`main` branch pointer needed to advance to match `fork/main` (which already
contains the dc-bsza merge, dc-kwgc refinery rig-DB fix, and downstream
upstream commits).

## Pre-sync state

- deacon `main` @ `3ff01043` (`fix(witness): separate LIFECYCLE:Shutdown
  from POLECAT_DONE to prevent silent work loss`) — pre dc-bsza
- 0 commits ahead of `fork/main`
- 209 commits behind `fork/main`
- `fork/main` already contained: dc-bsza merge (`2b8e8bb1`), dc-kwgc
  refinery fix (`2cef69ef`), dc-5gah subprocess cleanup (`28715d67`),
  upstream commits to `cfbdf3c2`-and-prior

## Backup

No new backup branch needed. The fork-level
`backup-fork-main-pre-sync-2026-05-06` @ `9c374c4e` (created during dc-bsza)
covers the recovery scenario for the entire fork, not just the gastown
source clone.

## Working-tree handling

The deacon clone had one uncommitted modification: a single line added to
`.gitignore` (`.land-worktree/`). This was not in `fork/main` and would
have conflicted with the FF on the .gitignore file. CLAUDE.md prohibits
`git stash`, so the change was preserved on a wip branch:

```
git checkout -b wip-2026-05-07-deacon-gitignore
git commit -am "wip: .gitignore add .land-worktree/ entry (deacon clone, pre dc-w7zc sync)"
```

The branch lives locally only (not pushed). If `.land-worktree/` is
needed in `.gitignore`, cherry-pick from that branch:

```
git cherry-pick wip-2026-05-07-deacon-gitignore
```

Untracked runtime files (`.deacon-heartbeat`, `dogs/`, `embeddeddolt/`,
`heartbeat.json`, `mayor/`, `metadata.json`, `witness/`) were left
in place — they're rig-local state, not version-controlled.

## Execution

```
cd ~/gt/deacon
git fetch --all --prune       # 4 new commits on origin since dc-bsza
git pull fork main --ff-only  # FF main from 3ff01043 to 28715d67
```

## Verification

- `gt --version`: `v0.5.0-4177-g2cef69ef-dirty` (post-dc-kwgc binary,
  already installed system-wide; no rebuild needed for this clone)
- Key commits present in deacon's history:
  - `2cef69ef` — dc-kwgc refinery rig-DB fix
  - `2b8e8bb1` — dc-bsza upstream merge
- No daemon restart performed; existing deacon agent will pick up the
  newer binary on next session boundary

## What this means for future deacon work

- Deacon agent no longer sees the regression where MRs with `wa-`/`<rig>-`
  prefix were stuck because refinery scanned the wrong DB
- Deacon agent has all upstream features through `cfbdf3c2`-and-prior
  (effort-based patrol routing, canonicalSessionStartPoint, Bitbucket
  PR support, etc)
- No deacon-specific customizations were lost — there were none

## Refs

- dc-bsza (gastown fork sync — created the merge that fork/main inherited)
- dc-kwgc (refinery query rig DB)
- dc-4sks (beads fork sync — separate repo, not affected by this)
- dc-4dix (BEADS_NO_AUTO_IMPORT escape hatch — bd binary, not gastown)
