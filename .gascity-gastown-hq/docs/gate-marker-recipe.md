# Gate Marker Recipe (CORRECT) — for builder-agents submitting to the gate

## Contents

• Correct submission · Label-routed markers (oracle-wa's shape) · `-t chore`, NOT `-t task` (this line used to be wrong)

The quality-gate guard and dispatcher extract fields from the marker's **DESCRIPTION**
(via `extract()` = `grep "^field:"` on `$DESC`) first. A marker with the fields
nowhere (neither in the description nor in the labels below) → BEAD_ID/BRANCH
extract EMPTY → the guard refuses it (`gate-status:error`, with a "Gate guard
rejected marker:" comment). See "Label-routed markers" for the one case where the
labels are read.

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

## Label-routed markers (oracle-wa's shape)

A marker whose routing sits ONLY in its labels (`branch:<val>`, `source-bead:<val>`,
`bead-rig:<val>`) and whose description is prose has no `branch:` / `bead_id:` /
`rig:` line. Both the guard (ga-nt0b18f) and the dispatcher (ga-9oxah) read such a
field from its label, and only when its description line is empty or missing, so
a canonical marker is untouched and the description always wins. In the guard,
what a label supplies goes through Step 4's validators like any other value
(branch characters, bead-id shape, registered rig), and each fallback is logged
("resolved from label"), so the sweep log names the bead.

The point is that the guard vets the marker before the dispatcher reviews it:
dedup, the E11 caps, the A/B base test, the bash 3.2 and skill-token checks and
the hard checks 2b-2e (step 2e draws and records the bead's arm). Before
ga-nt0b18f the guard refused such a marker WITHOUT a comment (the comment waited
for `bead_id`), `gate-recovery-watchdog` took the `gate-status:error` for a
transient one and re-queued it (`grw-requeue:1`), and the dispatcher reviewed it
with none of that. The 24/11 arm-coverage alarm saw it as 8 of 71 beads without
an arm, all `crew/oracle/*`. The description is still the canonical channel; `/gate-done`
writes it, and `author:` / `base_commit:` / `bead_rig:` have no label to fall
back to (the claim receipt records `base_commit: unknown`). Step 4b dedup also
reads description lines only, so a label-routed sibling is never superseded.

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
`bead-rig:`) are the fallback routing and the painel's display (see "Label-routed
markers"); real markers carry them — include them.
Safety net: a `crew/wa-worker/*` branch with unresolved author now falls back to
author=mayor (commit d8f2d7e7a) — but the description must still carry branch+bead_id.
