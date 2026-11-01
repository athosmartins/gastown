## Contents
- [What this covers](#what-this-covers)
- [Rule: stranded PENDING nudges](#rule-stranded-pending-nudges)
- [Census (the detector)](#census-the-detector)
- [Pollers dir prune](#pollers-dir-prune)
- [Where to look](#where-to-look)
- [Not verified](#not-verified)

# Nudge state hygiene (ga-9uv1xps)

## What this covers
Two leftovers in the engine's nudge state that no order covered, found while looking at `oracle-wa`
(5 PENDING items fenced to an old session) on 2026-10-31:
1. PENDING nudges fenced to a session that has already ended.
2. `<city>/.gc/nudges/pollers/` growing without bound (32,639 files on 2026-11-01).

The third item of the bead (patch `ga-j96y0n` never marked applied) was only bookkeeping: the patch is in the
engine since the 2026-10-23 window (commit `8f1be0e2b`, tag `engwin-20261023`, which is what `gc version` prints),
so the file is now `docs/pending-engine-window/ga-j96y0n-nudge-dead-ttl.patch.APLICADO-20261023`.

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

It prints `STRANDED-INFO ...` and exits 1 only when ALL of: class `outro`, fence `encerrada` (confirmed, never
`nao-sei`), and under 6 h of TTL left. That is an item of a shape nobody has seen, addressed to a session that
is gone, about to expire — its text may be the only copy. **If it ever fires, reconsider the rule above; do not
silence the alarm.** An `outro` item whose `expires_at` cannot be read does not alarm but is listed
(`outro_ttl_unreadable`). Exit 2 = cannot tell (state unreadable, or `bd` resolved no fence at all).

## Pollers dir prune
The engine writes `<stem>.pid`, `<stem>.pid.lock` (empty flock file) and `<stem>.log` per poller and never removes
them. `assets/scripts/nudge-pollers-prune.py` removes a stem only when it is dead, untouched for 7 days and unlocked:
- Liveness comes from `ps`, never from the files. Signal a: a live `gc nudge poll --session S <agent>` whose
  `sha256(S + "\0" + agent)[:8]` is the stem's 16-hex suffix (the engine's own `PollerFileStem`; checked against
  all live pollers on 2026-11-01). Signal b: the stem's `.pid` names a live process whose command line has
  `nudge poll`. Either keeps the stem.
- A `ps` that fails, is empty, or does not list the script itself, or a live `nudge poll` whose target cannot be
  parsed, makes the run delete nothing (exit 2). An empty process list is not "no pollers".
- Only names matching `<stem>-<16 hex>.(pid|pid.lock|log)` that are regular files are touched. `os.unlink`, no `rm`.
- First run (2026-11-01): 14,862 stems / 27,147 files removed, 0 errors; 6 live pollers kept intact.
  Growth is about 700 files/day, so without the order the dir is back to ~30k in six weeks.

## Where to look
- Order `nudge-state-hygiene` (every 3 h) runs both with `assets/scripts/nudge-state-hygiene.sh`; its exit code
  is the worst of the two.
- Logs (one json line per run): `$GC_CITY_RUNTIME_DIR/packs/town-deltas/nudge-pollers-prune.jsonl` and
  `nudge-stranded-census.jsonl`.
- Selftest: `assets/scripts/nudge-state-hygiene.selftest.sh` (75 assertions, ~12 s); `NSH_PRUNE_UNDER_TEST`,
  `NSH_CENSUS_UNDER_TEST`, `NSH_WRAPPER_UNDER_TEST` run it against a mutated copy.

## Not verified
- The bead said `polecat-churn-watcher.sh` reads `polecat-*.pid` from the pollers dir. The script was not found
  in the known script dirs, `~/.gastown`, launchd or docs, and there are no `polecat-*` files in the dir today.
  The prune treats every stem the same, so a reader of those files would see them only after 7 days dead.
- 15 of the stranded gate-review messages carry no gate-run id, so they could not be tied to a run bead; the
  class is judged from the text only.
- The class patterns are looser than a strict reading (33 vs 20 matches for "QUALITY GATE REVIEW").
- A stem whose file times cannot be read is kept and counted (`kept_undecided`); no fixture can make `stat` fail
  on a listed regular file, so that branch has no test.
