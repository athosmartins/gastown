# ga-5aovajz.1 — a nudge queued before the recipient's session restarts is dead-lettered as "session fence mismatch"

## Contents

• State · What was measured · Root cause · What the patch does · Tests · What it does NOT fix · Until the window · Apply / verify

Patch: `ga-5aovajz.1-nudge-fence-readdress.patch` (2 files under `cmd/gc/`: `cmd_nudge.go` edited, `cmd_nudge_readdress_test.go` new; +235 lines).
Base: `consolidated/engine-window-20261023` (`8f1be0e2b3`), the commit the running binary (`gc-1.1.1-engwin1023`) was built from.
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it. The engine window stays Mayor-coordinated.

## State

`git apply --check` passes on a clean checkout of the base, and the patch applies. Validated on the MBP: `go vet ./cmd/gc` ok; the 3 new tests pass with the patch and the
restart tests FAIL without it (RED proven on base); `go test ./cmd/gc -run 'Nudge|Poll|Queued|Fence|Wait'` passes. `gofmt` clean on both files.
**Not verified on a running patched binary**: that can only happen after the window; the check is in "Apply / verify".

## What was measured

Closed `gc:nudge` beads re-pulled on 2026-11-11 (783 of them; the bead quoted 805 for its own 7-day window):

| close state | count |
|---|---|
| accepted_for_injection | 413 |
| failed | **136** (17.4%) |
| injected | 117 |
| expired | 113 |
| superseded | 4 |

All 136 failures are `session fence mismatch` / "nudge failed: queue terminalization rejected delivery". By source: **130 `session`, 6 `mail`, 0 `wait`**.
The sender got "Queued" and exit 0 for each of them and was never told. One was a P0 gate-FAIL notice that sat for 28 h.

## Root cause

A nudge is stamped at enqueue with the recipient's session bead id **and** `continuation_epoch`. A fresh wake (`shouldBumpContinuationEpoch`: `continuation_reset_pending`, or
`wake_mode=fresh` with `last_woke_at`) bumps the epoch on the SAME session bead (the mayor went 201 -> 209 in a week). A nudge enqueued under the older epoch then fails
`queuedNudgeMatchesTargetFence` in `splitQueuedNudgesForTarget`, goes to `failedQueuedNudge`, and is dead-lettered permanently. The nudge text was addressed to the agent
(a person or role), not to one particular conversation, so the fence drops a message the live conversation should still get.

## What the patch does

`splitQueuedNudgesForTarget` keeps the fence, then re-addresses a mismatched item to the live conversation when `queuedNudgeReaddressableToTarget` says so. All of these must hold:

1. `Source` is `session` or `mail` (addressed to the agent).
2. The item has no session id, or the same session id as the live target (same session bead, only the epoch moved).
3. Both epochs parse as integers.
4. The item epoch is strictly **older** than the live epoch.

Anything else keeps the previous behavior (rejected). That includes an unreadable epoch or a newer item epoch (the E12 three-state "cannot tell" rule: keep the old outcome, do not guess).
The change sits in the shared split, so both delivery paths get it: the hook path (`gc nudge drain --inject`, the most common one) and `tryDeliverQueuedNudgesByPoller`.

## Tests

`cmd/gc/cmd_nudge_readdress_test.go`:

- `TestSplitQueuedNudgesForTarget_ReaddressesOlderEpochOfSameSession`: 10 cases. Deliver: session source, mail source, no session id (all older epoch). Keep the fence: `wait` source, empty source, newer item epoch, unreadable item epoch, unreadable live epoch, different session, target without a session.
- `TestCmdNudgeDrainDeliversNudgeQueuedBeforeSessionRestart`: end to end through `cmdNudgeDrainWithFormat` (plain, hook-inject session, hook-inject mail). Enqueue at epoch 1, bump the session bead to epoch 2, drain: the text is delivered, the queue is empty, the nudge bead is terminal with no "fence mismatch" and state != `failed`.
- `TestCmdNudgeDrainStillFencesWaitNudgeAfterSessionRestart`: a `wait` nudge from the older epoch is still NOT delivered (pins the unchanged behavior).

Without the patch (base `8f1be0e2b3`): the 3 split cases and the 3 restart cases FAIL; the other 7 split cases and the wait test pass. The existing `TestClaimDueQueuedNudgesForTargetClaimsSameSessionStaleEpoch` (source `wait`) still expects rejection and still passes.

## What it does NOT fix

- A nudge whose `SessionID` differs from the live session (a different session bead) is still rejected and expires. That is a different conversation, not a restart of this one.
- `wait` nudges stay fenced on purpose: they belong to the conversation that registered the wait (`cmd_wait.go` checks `registered_epoch` itself).
- Senders that do not go through `nudge_author_with_fallback` still get no failure report when a nudge is dropped for some other reason (expiry, different session). This patch removes the dominant cause of the drops; it does not add a sender-side failure return.
- "Delivered" for a hook-injected nudge means handed to the hook transport (`accepted_for_injection`), as before; the patch does not add a read receipt.
- Nudges already dead-lettered (`failed`) before the window are not replayed.

## Until the window

Senders that care (a gate FAIL, a P0) should keep a mail fallback or re-send when the recipient restarts; nothing in the running binary changes. No action is needed from crews.

## Apply / verify

```
cd <gascity checkout at consolidated/engine-window-20261023>
git apply --check "$GC_CITY_PATH/docs/pending-engine-window/ga-5aovajz.1-nudge-fence-readdress.patch" && git apply "$GC_CITY_PATH/docs/pending-engine-window/ga-5aovajz.1-nudge-fence-readdress.patch"
gofmt -l cmd/gc/cmd_nudge.go cmd/gc/cmd_nudge_readdress_test.go          # empty
# Go runs on the MBP only (scripts/mbp-run.sh --exec --go), never on the mini:
go vet ./cmd/gc && go test ./cmd/gc -run 'Readdress|BeforeSessionRestart|StillFences|Nudge|Poll|Queued|Fence|Wait'
```

After the engine window, verify on the live binary. The fraction of `session`/`mail` nudges that close as `failed` with a fence mismatch should fall to about 0:

```
bd list --label gc:nudge --status closed --include-infra --json --limit 0 --closed-after <window-date>
# count metadata.state == "failed" with last_error containing "fence mismatch", grouped by metadata.source; expect 0 for session/mail
```

Remaining `failed` rows from `wait` or a different session id are expected.
