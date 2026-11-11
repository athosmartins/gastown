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
(`gate_rcpt_sweep`, right after the post-merge sweep) looks the nudge up as a `gc:nudge` bead and decides:

| what the sweep finds | what happens |
|---|---|
| `state=injected`, or `accepted_for_injection` **and closed** | settled, nothing sent (the session took it; the hook transport hands it over at the session's next prompt) |
| `failed`, `expired`, `superseded` | the author is mailed now |
| closed in a state this check does not recognise | the author is mailed now, worded as "delivery cannot be confirmed" |
| still queued, `accepted_for_injection` still open, not found, or the beads unreadable, once the record is 30 min old (`GATE_RCPT_PENDING_MAX_S`) | the author is mailed, worded as "could not be confirmed", never as "failed"; younger than that, the sweep waits |
| the source bead is closed or `gate:passed` | moot: settled, nobody mailed |

When one recipient has several nudge beads in the window, the one addressed to that recipient (`metadata.agent` / `session_id` or the
`agent:<name>` label) is read first, then the oldest; identity only ranks, it never excludes, so a spelling that differs still matches.

The mail goes through `notify_author_with_fallback` (the recipient that accepted the nudge first; when nobody can be mailed, a mail to
the Mayor is attempted, and the text says it was attempted, not that it arrived). The source bead gets one `GATE-NUDGE-RECEIPT` comment saying what happened. Nothing re-sends the nudge and nothing writes the
engine queue: mail is the durable channel, and it survives the restart that killed the nudge.

## Where the state lives
- Spool: `$GC_CITY/.gc/runtime/gate-author-nudge/pending/<bead>__<recipient>.{rec,msg,chk}` (the record, the text, the time of the
  last look) and `settled/<key>.<epoch>.{rec,msg}` (kept 30 days; the `verdict=` line says how it ended). One record per bead and
  recipient: a later notice for the same pair replaces the earlier one.
- Events: `$GC_CITY/.gc/quality-gate.jsonl`, `event=author_nudge_receipt`, `verdict` = `delivered` | `mailed` | `escalated` (the author
  could not be mailed, a mail to the Mayor was attempted) | `moot`. A `delivered` event carries `via` (`injected into the session` or
  `accepted for hook-transport injection`).
- Dispatcher log: every line starts with `ga-5aovajz:`. A queued send says so at send time; a sweep with a lib that did not load says
  `gate-nudge-receipt.lib.sh did not load ... NOT being verified`.

## Reading what happened
- What is waiting: `ls $GC_CITY/.gc/runtime/gate-author-nudge/pending/`.
- How often the safety net acts: `jq -r 'select(.event=="author_nudge_receipt") | .verdict' $GC_CITY/.gc/quality-gate.jsonl | sort | uniq -c`.
  `mailed` and `escalated` are the nudges that did not land; `delivered` is a queued one that did (an `accepted_for_injection`
  bead that closed counts here: it is the usual success, not a loss).
- One bead: its `GATE-NUDGE-RECEIPT` comment, and `bd show` of the mail the author got.

## Knobs and kill switch
Environment of the dispatcher (defaults in the lib header): `GATE_RCPT_PENDING_MAX_S` 1800, `GATE_RCPT_MIN_AGE_S` 90 (no look before the
queue had a chance), `GATE_RCPT_RECHECK_S` 300 (per record), `GATE_RCPT_MAX_PER_SWEEP` 5, `GATE_RCPT_BUDGET_S` 90 (no new record is started
once a sweep spent this long: the sweep runs under the gate lock), `GATE_RCPT_DIR`. Off: `GATE_RCPT_ENABLED=0` or the file
`$GC_CITY/.gc/gate-nudge-receipt.off`; nothing is recorded and no sweep acts, records already written stay. `DRY_RUN=1` does neither.

## Not covered
- The engine (front 1 of ga-5aovajz): the queue should deliver a fenced item to the live continuation of the same session, or leave it
  in dead-letter where `gc nudge status` shows it. That is a patch under `docs/pending-engine-window/` and a window, not this.
- Which closed state means what is read from the bead's `state`; a state the check does not know mails at once rather than guessing it
  was delivered. The recipient is matched by identity for ranking only.
- Senders that do not go through `nudge_author_with_fallback`: the rebase nudges (`session nudge "$REBASE_AUTHOR"` / `"$OWNER"`) and the
  Mayor pings in the same dispatcher, and every other script that nudges. They still treat rc 0 as "told".
- An ephemeral pool author is not recorded: its session is gone by design and the bead returns to the pool by itself.

## Not verified
Seen live (2026-11-11, 799 closed `gc:nudge` beads, read-only `bd list --include-infra -l gc:nudge`): the nudge bead states and their
share: `accepted_for_injection` 425 (53%; closed with `close_reason "nudge accepted for hook-transport injection"`, empty
`terminal_reason`/`last_error`), `injected` 121, `failed` 136 (`last_error "queued nudge session fence mismatch"`), `expired` 113,
`superseded` 4; and the fields the sweep reads (`metadata.state`, `metadata.agent`, `metadata.session_id`, `metadata.message`,
`close_reason`, the `agent:<name>` label). The selftest fixtures are modelled on that shape.

Still taken from other code, not seen live: the `--json` shape of `gc session nudge`
(`{"ok":true,"delivery":"wait-idle","queued":true,"outcome":"queued"}`, from `pool-idle-nobead-guard.sh`; it carries no nudge id, so the
sweep matches the first line of the text and the time). A nudge bead's `created_at` is read as UTC ending in `Z` (fractions are
tolerated); any other offset is read as "not found", which waits for the 30 min rule and then mails. First thing to check after the
merge: one queued FAIL nudge appears in `pending/`, and its receipt settles.
