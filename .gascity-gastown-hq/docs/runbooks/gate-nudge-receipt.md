## Contents
- [What it does](#what-it-does)
- [Where the state lives](#where-the-state-lives)
- [Reading what happened](#reading-what-happened)
- [Knobs and kill switch](#knobs-and-kill-switch)
- [Not covered](#not-covered)
- [Not verified](#not-verified)

# Gate author-nudge receipt (ga-5aovajz)

## What it does
`gc session nudge --delivery wait-idle` exits 0 both when it types the text and when it only queues it. A queued item is dropped
silently when the target's session restarts first (bead closes `state=failed`, `last_error "queued nudge session fence mismatch"`:
136 of 805 nudges in the 7 days to 11/11) or expires unseen after 24 h (`state=expired`: 114). The gate's FAIL notice to a live named
crew is the worst case: the dispatcher keeps the crew as owner on the strength of that nudge, so nobody else picks the bead up
(wa-2h615v.7, a P0, sat 28 h).

`nudge_author_with_fallback` (quality-gate-dispatcher.sh) now asks for `--json`. `outcome: delivered` = typed into the session: done.
Anything else (queued, or rc 0 with no readable outcome) is written to a spool by `gate-nudge-receipt.lib.sh`. Each gate sweep
(`gate_nr_sweep`, right after the post-merge sweep) looks the nudge up as a `gc:nudge` bead and decides:

| what the sweep finds | what happens |
|---|---|
| `state=injected` | settled, nothing sent |
| `failed`, `expired`, `superseded`, or closed in any other state | the author is mailed now |
| still queued / not found / the beads unreadable, once the record is 30 min old (`GATE_NR_PENDING_MAX_S`) | the author is mailed, worded as "could not be confirmed", never as "failed" |
| the source bead is closed or `gate:passed` | moot: settled, nobody mailed |

The mail goes through `notify_author_with_fallback` (the recipient that accepted the nudge first, the Mayor only when nobody can be
mailed). The source bead gets one `GATE-NUDGE-RECEIPT` comment saying what happened. Nothing re-sends the nudge and nothing writes the
engine queue: mail is the durable channel, and it survives the restart that killed the nudge.

## Where the state lives
- Spool: `$GC_CITY/.gc/runtime/gate-author-nudge/pending/<bead>__<recipient>.{rec,msg,chk}` (the record, the text, the time of the
  last look) and `settled/<key>.<epoch>.{rec,msg}` (kept 30 days; the `verdict=` line says how it ended). One record per bead and
  recipient: a later notice for the same pair replaces the earlier one.
- Events: `$GC_CITY/.gc/quality-gate.jsonl`, `event=author_nudge_receipt`, `verdict` = `delivered` | `mailed` | `escalated` (the author
  could not be mailed, the Mayor was) | `moot`.
- Dispatcher log: every line starts with `ga-5aovajz:`. A queued send says so at send time; a sweep with a lib that did not load says
  `gate-nudge-receipt.lib.sh did not load ... NOT being verified`.

## Reading what happened
- What is waiting: `ls $GC_CITY/.gc/runtime/gate-author-nudge/pending/`.
- How often the safety net acts: `jq -r 'select(.event=="author_nudge_receipt") | .verdict' $GC_CITY/.gc/quality-gate.jsonl | sort | uniq -c`.
  `mailed` and `escalated` are the nudges that did not land; `delivered` is a queued one that did.
- One bead: its `GATE-NUDGE-RECEIPT` comment, and `bd show` of the mail the author got.

## Knobs and kill switch
Environment of the dispatcher (defaults in the lib header): `GATE_NR_PENDING_MAX_S` 1800, `GATE_NR_MIN_AGE_S` 90 (no look before the
queue had a chance), `GATE_NR_RECHECK_S` 300 (per record), `GATE_NR_MAX_PER_SWEEP` 5, `GATE_NR_BUDGET_S` 90 (no new record is started
once a sweep spent this long: the sweep runs under the gate lock), `GATE_NR_DIR`. Off: `GATE_NR_ENABLED=0` or the file
`$GC_CITY/.gc/gate-nudge-receipt.off`; nothing is recorded and no sweep acts, records already written stay. `DRY_RUN=1` does neither.

## Not covered
- The engine (front 1 of ga-5aovajz): the queue should deliver a fenced item to the live continuation of the same session, or leave it
  in dead-letter where `gc nudge status` shows it. That is a patch under `docs/pending-engine-window/` and a window, not this.
- Senders that do not go through `nudge_author_with_fallback`: the rebase nudges (`session nudge "$REBASE_AUTHOR"` / `"$OWNER"`) and the
  Mayor pings in the same dispatcher, and every other script that nudges. They still treat rc 0 as "told".
- An ephemeral pool author is not recorded: its session is gone by design and the bead returns to the pool by itself.

## Not verified
Built on the Hetzner node, which has no city and no Dolt. Taken from other code in this repo, not seen live: the `--json` shape of
`gc session nudge` (`{"ok":true,"delivery":"wait-idle","queued":true,"outcome":"queued"}`, from `pool-idle-nobead-guard.sh`; it carries
no nudge id, so the sweep matches the first line of the text and the time), the nudge bead states (`queued`, `accepted_for_injection`,
`injected`, `failed`, `expired`, `superseded`, from `wisp-reaper.sh`, `nudge-queue-hygiene.py` and one closed bead, `ga-wisp-dkkuz`), and the `bd list` flags
(`--include-infra --status --limit 0 -l gc:nudge --closed-after <date>`, all used elsewhere in the dispatcher or in the witness query of
the bead). First thing to check after the merge: one queued FAIL nudge appears in `pending/`, and its receipt settles.
