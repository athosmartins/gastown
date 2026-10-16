# Gate Marker Recipe (CORRECT) — for builder-agents submitting to the gate

## Contents

• Correct submission · `-t chore`, NOT `-t task` (this line used to be wrong)

The quality-gate-dispatcher extracts fields from the marker's **DESCRIPTION**
(via `extract()` = `grep "^field:"` on `$DESC`), NOT from labels. A marker with
the fields only in labels → BEAD_ID/BRANCH extract EMPTY → author unresolvable →
`gate-status:deferred` forever (observed: wa-14w76/wa-oly1 stuck 2026-06-25).

## Correct submission

```bash
HQ=/Users/athos/gt/.gascity-gastown-hq
BEAD=wa-xxxx; BR=crew/wa-worker/$BEAD; RIG=whatsapp_automation
# ga-iwcu23: fetch BEFORE computing base_commit, and abort rather than submit
# an empty/stale one. A base_commit computed from a stale local cache (or a
# branch ref that was never actually pushed) can resolve to something real in
# YOUR worktree while being absent from origin — every downstream consumer
# (reviewers cloning from origin, the gate's rebase-distance circuit-breaker)
# then measures against a base it can't resolve. Measured live in ga-jvzpb:
# exactly this produced a base_commit origin rejected with "not our ref",
# which fed a wrong "117 commits behind" into the circuit-breaker (the real,
# freshly-fetched distance was 36) and permanently parked the marker.
git -C ~/gt/$RIG fetch origin main "$BR" --quiet || { echo "ERROR: fetch failed — refusing to compute base_commit from a stale cache"; exit 1; }
BASE=$(git -C ~/gt/$RIG merge-base origin/main origin/$BR)
[ -z "$BASE" ] && { echo "ERROR: merge-base origin/main origin/$BR returned empty — base_commit unresolvable, do NOT submit a marker without one"; exit 1; }
MID=$(bd -C "$HQ" create "ready-for-gate: $BR" -t chore \
  --description "branch: $BR
bead_id: $BEAD
author: wa-worker
base_commit: $BASE
rig: $RIG
bead_rig: $RIG
submitted_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | grep -oE 'ga-[a-z0-9]+' | head -1)
# ga-ni22de: a NEW marker is born `gate-status:ready`, never `queued`. The guard
# only discovers `ready`; it claims the marker, runs the vetting (E11 size cap,
# Step 4b dedup/supersede, A/B base test, bash-3.2 check) and only THEN parks it
# as `queued` for the dispatcher. Born `queued`, the marker skips all of that,
# and the guard rejects it (gate-status:error) when it finds one with no
# claim/park stamp.
for L in type:quality-gate-marker gate-status:ready \
         "branch:$BR" "source-bead:$BEAD" "bead-rig:$RIG"; do
  bd -C "$HQ" label add "$MID" "$L" -q
done
bd -C "$HQ" dolt commit -m "submit $BEAD to gate"
```

`queued` is a state the guard writes, not one a submitter writes. The only hand
edit that touches it is re-queueing an EXISTING, already-vetted marker that went
to `error` (`label remove gate-status:error && label add gate-status:queued`) —
that marker already carries the guard's stamps, so it is not rejected. A marker
the guard itself rejected as born-queued has no such stamps and must go back as
`ready` (`label remove gate-status:error && label add gate-status:ready`), so the
guard vets it; the rejection comment on the marker says the same.

## `-t chore`, NOT `-t task` (this line used to be wrong)

`bd create` defaults to `task`. **Every marker the gate has actually processed is
`chore`** — verified 2026-08-11 across the 8 most recent real markers
(`ga-k7ecg`, `ga-ithy0`, `ga-lw3zv`, `ga-k65qc`, `ga-b2glh`, `ga-apa3x`,
`ga-m3hh5`, `ga-db7tv`): `issue_type=chore`, no exceptions. The guard creates its
own beads the same way (`quality-gate-guard.sh` L3487: `-t chore`).

The failure mode is **silent**: a `task` marker with every label and description
field correct sat 1h22 in `queued` while the guard claimed markers submitted
*after* it, and `grep <marker-id> quality-gate-guard.log` returned **zero**
mentions — the guard never saw it. Zero log mentions ≠ slow queue; it means
invisible. Confirm pickup within ~5 min:

```bash
grep <marker-id> "$HQ/.gc/logs/quality-gate-guard.log"   # 0 hits = invisible, not queued
```

Fix without recreating: `bd -C "$HQ" update <marker> -t chore` (preserves labels
and description).

⚠️ Do NOT pass `--ephemeral`. Under bd 1.1.0 ephemeral = INFRA, which is hidden
from `bd list` by default — the bead goes invisible to every monitor and watchdog
in the city, which then report "no active run" while a run is happening (the
guard carries this same warning at L3480).

The DESCRIPTION fields are MANDATORY: `branch:`, `bead_id:`, `author:`,
`base_commit:`, `rig:`, `bead_rig:`. Labels (`source-bead:`, `branch:`,
`bead-rig:`) are secondary/display, but real markers carry them — include them.
Safety net: a `crew/wa-worker/*` branch with unresolved author now falls back to
author=mayor (commit d8f2d7e7a) — but the description must still carry branch+bead_id.
