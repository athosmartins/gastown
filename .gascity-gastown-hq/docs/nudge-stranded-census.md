## Contents
- [What this covers](#what-this-covers)
- [Rule: stranded PENDING nudges](#rule-stranded-pending-nudges)
- [Census (the detector)](#census-the-detector)
- [Where to look](#where-to-look)
- [Not verified](#not-verified)

# Nudge stranded census (ga-9uv1xps.3)

## What this covers
PENDING nudges fenced to a session that has already ended, found on `oracle-wa` (5 PENDING items fenced to an
old session) on 2026-10-31. This is point 1 of bead `ga-9uv1xps`; the pollers directory is `ga-9uv1xps.2` and the
`ga-j96y0n` patch bookkeeping is `ga-9uv1xps.1`.

## Rule: stranded PENDING nudges
**Do not re-fence, move or delete a PENDING nudge because its session ended. The engine's 24 h TTL is its
garbage collector.** Measured on the live queue on 2026-11-01 (census run: 50 pending): 46 were fenced to a session whose bead is
closed, and all 46 were pointers to a bead that holds the durable record:

| class (by the text) | stranded | durable record |
|---|---|---|
| gate-review task | 32 | the gate-run bead |
| bead pointer ("Bead nova para você", GATE-FEEDBACK, "has passed gate", "Gate FAILED") | 11 | the bead itself |
| transient advisory (DISK CRITICAL) | 3 | stale after minutes |
| anything else | 0 | |

Why not re-fence: the ad-hoc reviewers/workers have `agent == session`, so there is no successor session to
move the item to (about 33 of the 46). `nudge-queue-hygiene.py` also keeps a deliberate invariant — it never touches
non-warning items — and this rule keeps it.

The rule is only safe while stranded items stay pointers. That assumption is what the census watches.

## Census (the detector)
`assets/scripts/nudge-stranded-census.py` is READ-ONLY. It resolves every fence to a session bead (`bd show`;
`gc session list` has no closed sessions, so it cannot say "ended") in three states — `viva`, `encerrada`,
`nao-sei` — and every message to a class from a closed allowlist of the shapes above, else `outro`.
A bead row without a readable `status` is `nao-sei`, never `encerrada`.

It prints `STRANDED-INFO ...` and exits 1 only when ALL of: class `outro`, fence `encerrada` (confirmed, never
`nao-sei`), and under 6 h of TTL left. That is an item of a shape nobody has seen, addressed to a session that
is gone, about to expire — its text may be the only copy. **If it ever fires, reconsider the rule above; do not
silence the alarm.** An `outro` item whose `expires_at` cannot be read does not alarm but is listed
(`outro_ttl_unreadable`). Exit 2 = cannot tell (state unreadable, or `bd` resolved no fence at all).

## Where to look
- Order `nudge-stranded-census` (every 3 h) runs `assets/scripts/nudge-stranded-census.sh`; its exit code is the
  census's (0 clean, 1 STRANDED-INFO, 2 cannot tell). The 3 h interval is so two runs see every item inside the
  last 6 h of its 24 h TTL.
- Log (one json line per run): `$GC_CITY_RUNTIME_DIR/packs/town-deltas/nudge-stranded-census.jsonl`.
- Selftest: `assets/scripts/nudge-stranded-census.selftest.sh` (23 assertions, no BSD-only calls, so it also runs on the
  Linux node); `NSC_CENSUS_UNDER_TEST` runs it against a mutated copy.

## Not verified
- "Fence ended" rests on the session's bead (`gc session list` has `closed: 0` and cannot show it).
- 15 of the stranded gate-review messages carry no gate-run id, so they could not be tied to a run bead; the
  class is judged from the text only.
- The class patterns are looser than a strict reading (33 vs 20 matches for "QUALITY GATE REVIEW").
- The live queue changed between the two measurements (2 of the 5 `oracle-wa` PENDING items had become DEAD, expired).
