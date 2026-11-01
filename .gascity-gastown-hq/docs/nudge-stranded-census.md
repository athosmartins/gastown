## Contents
- [What this covers](#what-this-covers)
- [Rule: stranded PENDING nudges](#rule-stranded-pending-nudges)
- [Census (the detector)](#census-the-detector)
- [Outcomes, exit codes and who hears them](#outcomes-exit-codes-and-who-hears-them)
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

The rule is only safe while stranded items stay pointers. That assumption is what the census watches, and it only
helps if a human hears it (see "Outcomes, exit codes and who hears them").

## Census (the detector)
`assets/scripts/nudge-stranded-census.py` never writes the queue and never touches a bead. It resolves every fence to a
session bead (`bd show`; `gc session list` has no closed sessions, so it cannot say "ended") in three states — `viva`,
`encerrada`, `nao-sei` — and every message to a class from a closed allowlist, else `outro`. `viva` is a bead whose
status is present and not `closed` (the test `quality-gate-dispatcher.sh` uses too), so a status nobody has seen is
`viva`, the quiet direction. A bead row without a readable `status`, a purged bead, a `bd` error and a fence the time
budget never reached are all `nao-sei`, never `encerrada`.

**Allowlist** (case-insensitive substring; `outro` is anything else). A new shape needs a measured row here and in
selftest A; the selftest also pins texts that only resemble a shape.

| class | pattern | basis |
|---|---|---|
| tarefa-gate | `QUALITY GATE REVIEW` anywhere in the text | measured 2026-11-01; the reviewer task header, see `bead-token-meter.py` |
| ponteiro-bead | `Bead nova para voc` | measured; `pilot-dispatcher.sh` assignment nudge |
| | `GATE-FEEDBACK` | measured |
| | `has passed gate` | measured; no emitter found in this repo |
| | `Gate FAILED` (also covers `QUALITY GATE FAILED for branch …`) | measured on `oracle-wa` (parent bead); `quality-gate-dispatcher.sh` author nudge, names the gate run |
| | `Your branch` | not in the measured table; `quality-gate-dispatcher.sh` author notices, name the source bead |
| | `blocker .* closed` | not in the measured table; no emitter found in this repo |
| aviso-transit | `DISK CRITICAL` | measured; `dolt-disk-floor-guard.sh` |
| | `DISK LOW`, `disk .*floor` | not in the measured table; no emitter found in this repo |

Three outcomes, never two — a census that says nothing must mean "looked, nothing there":
- **ALARM (`STRANDED-INFO`, rc 1)**: class `outro` AND fence `encerrada` (confirmed, never `nao-sei`) AND under 6 h of TTL
  left. An item of a shape nobody has seen, addressed to a session that is gone, about to expire — its text may be the
  only copy. **If it ever fires, reconsider the rule above; do not silence the alarm.** An `expires_at` that is zero or
  already past counts as no time left, so such an item alarms (once; see below).
- **CANNOT TELL (rc 2)**: something that could be an alarm was not decided. Whole run: the queue state is unreadable or
  not an object, its directory is missing, `bd` resolved no fence at all (or the 150 s budget ran out first), or the census
  crashed. Per item, listed by id: an `outro` item with a closed fence and an unreadable `expires_at` (`ttl-unreadable`); an
  `outro` item under 6 h of TTL, or with an unreadable TTL, whose fence could not be resolved (`fence-unreadable`: a run
  that is only partly blind is not a clean run); a pending entry that is not an object (`unreadable-items`). Known-class
  items need no fence and are only counted.
- **CLEAN (rc 0)**: everything that could matter was decided and none of it is an alarm. A queue dir with no
  `state.json`, a 0-byte one and a JSON `null` are an empty queue, as the engine's `LoadState` and
  `nudge-queue-hygiene.py` read them.

## Outcomes, exit codes and who hears them
The exit code alone reaches nobody. `scripts/order-exec-failure-watchdog.sh`, the only generic reader of failed orders,
alerts only when the same order has a NEW `failed: exit status N` line in two consecutive 5-minute sweeps and resets at
the first sweep without one; this order runs once per 3 h, so one failing run is a count of 1 and then a reset, forever.
So the census tells a human itself through `notify` (ntfy), as `nudge-stranded-detector.py` does. The order's wrapper
passes `--notify`; run by hand, the census only prints and writes nothing.

| rc | outcome | what a human gets |
|---|---|---|
| 0 | clean | nothing |
| 1 | STRANDED-INFO | `Censo de nudge preso: STRANDED-INFO (n)`: id, agent, fence, `expires_at` of each NEW item (8 shown, then a count), never the nudge text (it may hold anything). Once per nudge id while it stays pending |
| 2 | cannot tell | `Censo de nudge preso: cego`: the reasons (`state-unreadable`, `bd-unusable`, `fence-unreadable`, `ttl-unreadable`, `unreadable-items`, `crashed`) and the ids. Once per reason-set per 300 min, so a census that stays blind says so about every other run (3 h cadence), not every run |
| 3 | a notice was due and could not be delivered or recorded | nothing can be sent; stderr says `ALARM NOT DELIVERED` or `could not write the ledger`, the summary says `notices` / `ledger_write`. Nothing is recorded as sent, so the next run tries again |

An ALARM and a CANNOT TELL in the same run end rc 1 with two notices. An exception while reading or deciding is CANNOT TELL
(`crashed`), one while delivering is rc 3: never an uncaught exception, whose exit code 1 would read as STRANDED-INFO. The
notice text is ASCII (ntfy sends the title as an HTTP header).

## Where to look
- Order `nudge-stranded-census` (every 3 h, `timeout = "240s"`) runs `assets/scripts/nudge-stranded-census.sh`. The 3 h
  interval is so two runs see every item inside the last 6 h of its 24 h TTL. The `timeout` is declared because an order
  without one gets the engine's 300 s SIGKILL, which would leave no summary, no log and no notice; it fits the 150 s `bd`
  budget plus two 30 s notify calls.
- State dir: `$GC_PACK_STATE_DIR`, else `$GC_CITY_RUNTIME_DIR/packs/town-deltas`, else `<city>/.gc/runtime/packs/town-deltas`.
  In it: `nudge-stranded-census.jsonl` (one json line per run, with `rc`, the matrix, `notices` and `duration_s`) and the
  ledger `nudge-stranded-census-seen.json` (the nudge ids already alarmed and the time of each blind notice).
- Selftest: `assets/scripts/nudge-stranded-census.selftest.sh` (a canned `bd` and a fake `notify`; no BSD-only calls, so it also
  runs on the Linux node); `NSC_CENSUS_UNDER_TEST` runs it against a mutated copy.

## Not verified
- "Fence ended" rests on the session's bead (`gc session list` has `closed: 0` and cannot show it).
- 15 of the stranded gate-review messages carry no gate-run id, so they could not be tied to a run bead; the
  class is judged from the text only.
- The class patterns are looser than a strict reading (33 vs 20 matches for "QUALITY GATE REVIEW"). An unknown text that
  merely contains a known phrase is classed as a known pointer and can never alarm — the quiet direction. It could not
  be re-measured when this was fixed (the Hetzner node has no city), so the allowlist was only pinned by tests, not tightened.
- The live queue changed between the two measurements (2 of the 5 `oracle-wa` PENDING items had become DEAD, expired).
- The cost of a run on the live city is not measured (built on the Hetzner node, which has no city): the first runs of
  the jsonl log carry `duration_s`. The 150 s budget and the 240 s timeout are bounds, not measurements.
- Not run on the mini: `notify` resolving in the order's PATH, the mini's `python3` version (tested on 3.12 only), and what
  the engine does with the cooldown of a run that exited non-zero (taken from the watchdog's own header).
