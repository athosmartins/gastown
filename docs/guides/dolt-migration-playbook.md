# Dolt Migration Playbook

Replaces the v1 swap-migration template used in bead `dc-bkp1` (2026-05-24, deacon→hq). The v1 plan succeeded mechanically but stranded 3 beads because it assumed write quiescence without enforcing it.

This document is the canonical reference for any future dolt database rename, merge, or restructure across the town.

## When this playbook applies

Any operation that:
- Renames a dolt database directory under `~/gt/.dolt-data/`
- Swaps two database directories
- Drops or recreates a database
- Changes which dolt database a rig's `.beads/metadata.json` points to

It does **not** apply to:
- Routine `bd compact` / `dolt gc` (no rename, no rig-pointer change)
- Backups (read-only)
- Schema migrations within a single db (separate concern)

## Core principle

**Quiescence is not assumable. It must be enforced.** Patrols, polecats, crew sessions, mail-poller, and external automation all write to town dbs on intervals from seconds to minutes. Any migration window longer than the shortest write interval will overlap with at least one writer.

## Strategy selection

For each migration, pick exactly one of:

### Strategy B — Merge (default)
Best for nearly every case. Dolt is git-like at the row level — merge is a first-class operation and the idiomatic choice.

**Applicability:** requires a common ancestor between the two dbs. If the two dbs were forked from a shared point (the common case for sibling town dbs), B works. If they are truly independent (no shared history), fall through to A.

1. Set freeze (see "Freeze mechanism" below).
2. `dolt merge <source-branch>` with the target db as the base. Resolve conflicts on duplicate IDs (typically: newer `updated_at` wins, or escalate to a human).
3. Verify both dbs' issue/wisp/event counts are reflected in the merge result.
4. Clear freeze.

### Strategy A — Freeze + Swap (exception)
Use **only** when source has zero value to preserve OR merge is infeasible because the two dbs share no common ancestor. Higher risk because it discards one branch wholesale.

1. Take a baseline diff (`bd export` from both dbs) at T0.
2. Set freeze.
3. Take a second diff (T1). If non-empty between T0 and T1 → freeze leaked; abort.
4. Stop dolt, swap dirs, restart dolt.
5. Repeat diff at T2 against backup → confirm zero new writes during the window.
6. Clear freeze.

### Strategy C — Reconcile (recovery only, never a plan)
Use only when A or B failed in flight and the migration completed under loss conditions. Never select C upfront — that is choosing to lose data.

1. Diff backup vs active db.
2. For each stranded record: port-via-`bd create` (new ID + notify owner) or leave-as-historical.
3. File every loss explicitly so it does not silently degrade trust in the data.

## Freeze mechanism

`gt migrate freeze` and `gt migrate thaw` enforce the freeze at the gt CLI layer. They block `gt mail send`, `gt nudge`, `gt sling`, and `gt assign` town-wide via a `MIGRATION-FREEZE` sentinel file at the town root. Read commands and services-management commands (`gt hook`, `gt mail inbox`, `gt dolt`, `gt daemon`, etc.) keep working so you can diagnose mid-migration.

**The bd CLI is NOT yet gated.** A human typing `bd create` directly will still write — rely on the playbook's plist-unload step to stop continuous bd writers (mail-poller, daemon patrols). Follow-up bead tracks bd-side enforcement.

**Order matters:** unload writer plists BEFORE stopping dolt, because `com.gastown.dolt-server` has `KeepAlive` and will restart dolt within ~2 minutes if its plist is still loaded when you stop the server.

```bash
# 1. Set the gt write-freeze (blocks gt mail send / nudge / sling / assign):
gt migrate freeze -r "<migration description>"

# 2. Unload every gastown writer plist (covers bd writers + dolt restart).
#    macOS 13+ prefers bootout over unload:
for plist in ~/Library/LaunchAgents/com.gastown.*.plist; do
  label="$(basename "$plist" .plist)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
    || launchctl unload "$plist" 2>/dev/null
done

# 3. Hard verify: list MUST be empty for gastown writers
remaining=$(launchctl list | awk '/com\.gastown\./ {print $3}')
[ -z "$remaining" ] || { echo "FREEZE FAILED — still loaded: $remaining"; exit 1; }

# 4. Cron writers (often missed)
crontab -l 2>/dev/null | grep -E '(dolt|bd |gt )' && echo "WARNING: cron writes detected, suspend manually"

# 5. Stop gt daemon (patrols)
gt daemon stop

# 6. Crew/polecat sessions are async — gt nudge from this point will refuse
#    (the freeze blocks it). For agents already mid-task, also set DND:
for s in $(tmux list-sessions -F '#S' | grep -E '(crew|polecat|witness|refinery)'); do
  gt dnd on --target "${s#*-}" 2>/dev/null || true
done

# 7. SMOKE TEST the freeze. The gt-side gate has a built-in test:
gt nudge mayor "freeze probe" 2>&1 | grep -q "town is frozen" \
  && echo "✓ gt freeze active" || { echo "✗ FREEZE NOT WORKING"; exit 1; }
# For bd-side, confirm the plists you care about are not loaded (step 3 above
# is the proof). A freeze that is not verified is decorative.
```

Specific jobs the v1 plan missed (carry these names forward):
- `com.gastown.mail-poller` (5-min interval — writes mail beads)
- `com.gastown.dolt-server` (2-min interval — `KeepAlive` restarts dolt if stopped before its plist is unloaded)

Reload at the end (reverse order: launchd plists last, after dolt is healthy, **then** `gt migrate thaw`).

## Mandatory pre-flight

- [ ] `df -h ~/gt` — free space ≥ 2× source db
- [ ] Full tarball backup of `~/gt/.dolt-data/` to a path **outside** dolt-data (and outside `/tmp` for any wait > 1 day; use `~/gt/.dolt-data-backups/`)
- [ ] **Verify the tarball is readable**: `tar tzf <backup> > /dev/null && echo OK` — `tar czf` returning 0 is not proof the archive is sound
- [ ] Snapshot of every `metadata.json` and `daemon.json` that will be edited
- [ ] Diff scan: `bd export --all` from each affected db, saved with timestamp
- [ ] `gt doctor` baseline captured to file
- [ ] Identify every active agent/job that writes to the affected dbs (see Freeze mechanism — include cron)
- [ ] Identify the **shortest write interval** among active writers — your migration must complete inside it, OR the freeze must hold across it

## Mandatory post-flight (within 5 minutes of completing the swap)

- [ ] **Diff scan**: re-run `bd export` on both backup and new db, diff. Zero new records in backup-only set → success. Non-zero → recover via Strategy C immediately while context is fresh.
- [ ] `gt doctor` against the baseline — investigate every new warning/failure individually before declaring done
- [ ] Watch one full patrol cycle (≥ 5 min) and re-run doctor — confirms no auto-discovery side effects (e.g., a patrol materializing rig dirs from orphan dbs)
- [ ] Validate row counts in the new db against the source-db snapshot (issues, wisps, events at minimum)
- [ ] Test a representative write path (`bd create`, `gt mail send`) and a read path (`bd show`)

## Anti-patterns observed during dc-bkp1

1. **Leaving the rollback db inside `~/gt/.dolt-data/`** — daemon patrols (witness/refinery) auto-discover orphan dbs and materialize rig dirs (`~/gt/<dbname>/.beads/metadata.json`), which then fail every doctor cycle. Move rollback dbs to `~/gt/.dolt-data-backups/` immediately after the swap.
2. **Using `/tmp` for rollback artifacts with a >24h hold period** — macOS periodic cleanup will catch atime-aged files; use a Library or home-dir location.
3. **"24h cooling-off period" before deleting rollback** — incompatible with patrol auto-discovery on the same path. Either move out-of-path immediately or accept that doctor will warn during the period.
4. **Assuming quiescence** — root cause of every stranded-bead incident. There is no quiet period.
5. **Editing metadata.json by sed alone** — verify with `jq .` or `cat` after every edit. Migration day is the worst day to discover a malformed JSON.
6. **Crew consultation only at the abort gate** — consult crew (digo, thies, deacon) at design time, not when something has gone wrong. They catch race conditions you won't.
7. **Declaring "mechanically OK" before the post-flight diff** — matching row counts (e.g., 2913 issues / 636 wisps / 38038 events on both sides) is **not** evidence of zero loss. Two dbs can have the same counts and different rows. The diff is the only proof. Run it within 5 minutes while context is fresh.
8. **Stopping dolt before unloading the `dolt-server` plist** — `KeepAlive` restarts dolt within ~2 minutes. Always unload writer plists first, dolt second.

## Abort criteria

ABORT and roll back from tarball if any of:
- Tarball integrity check fails (`tar tzf <backup> > /dev/null` is non-zero or returns no entries)
- Diff scan shows writes during the freeze window (freeze leaked — investigate before any second attempt)
- Dry-run rename does not produce expected db visibility in `gt dolt status`
- **Any** new doctor warning or failure whose root cause you cannot name *with evidence* (not guessed). Use a 10-minute timebox per warning for the investigation; if time runs out without a named cause, that is an abort signal, not a license to ship
- **Row-count divergence between source snapshot and new db beyond the expected delta** (e.g., concurrent writes you accounted for). This is a hard signal — stronger than doctor warnings.

Rolling back from tarball is a known-good operation. Press it without ceremony if you hit any of the above.

## Cross-references

- Original v1 plan that this replaces: `/tmp/dolt-migration-plan-2026-05-25.md` (and bead `dc-bkp1`)
- Follow-up tooling work: bead `dc-qcd2` (P2 — implement `gt migrate freeze/thaw`)
- Lint rule revisit prompted by this migration: bead `dc-62si` (P3 — `rig-config-sync` should accept `rig.db == town.db`)
- Recovery example: bead `dc-7d00` (recreated `dc-owd7` after the dc-bkp1 strand)
