# ga-4ytmas (item 2) — a create the wake budget keeps deferring is waiting, not dead

Patch: `ga-4ytmas-wake-budget-hold.patch` (4 files, all under `cmd/gc/`: 2 edited, 2 new).
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it.
The engine window stays Mayor-coordinated. Independent of `ga-4ytmas-proc-snapshot-unknown.patch`
(that one only touches `internal/runtime/tmux/`); either can go in alone, order does not matter.

## What happened to oracle-wa on 10/10 (from `supervisor.log`)

The supervisor DID keep trying to recreate the crew (`oracle-wa`, `min_active_sessions = 1`):
beads `gan8qym8`, `ga2shbta`, `gai5cqij`, then `gayupf2o` (-> `provider_error`), and the Mayor
recreated `gahvbdkx`. But the starts were `deferred_by_wake_budget` (`max_wakes_per_tick = 2`,
and each start takes 1-2.5 min under load), so a create sat in the start queue and was NEVER
attempted. After `pendingCreateNeverStartedTimeout` (10 min) the reconciler rolled it back
("rolling back pending create oracle-wa-ga2shbta: lease expired and no live runtime"). The
replacement bead has a fresh `CreatedAt`, which is the wake-fairness key of a never-woken session
(`wakeFairnessTime`): it joins the BACK of the queue and the wait starts over. A queue that never
drains faster than 10 min therefore never reaches the crew.

## What the patch does

* `session_wake_budget_hold.go` (new): a small in-memory table `session_name -> last time the wake
  budget deferred it`. `markWakeBudgetDeferred` is called at BOTH `deferred_by_wake_budget` sites in
  `executePlannedStartsTraced` (the per-candidate site and the whole-wave early-exit site).
  `wakeBudgetHoldsPendingCreate` is true for a never-started create (no `last_woke_at`) that was
  deferred within `wakeBudgetDeferralHold` = 5 min.
* `session_reconciler.go`: `pendingCreateNeverStartedLeaseExpired` returns false for such a create.
  This is the ROOT predicate on purpose; its consumers are `pendingCreateLeaseExpiredForRollback`
  (the two rollback sites), `pendingCreateLeaseActive` (heal, pool-slot sweep) and the stuck-creating
  reaper in `session_beads.go`, which would otherwise close the queued bead from under the queue.
* The hold is renewed every tick the session is still deferred and lapses 5 min after it stops being
  deferred, so a create that stopped being a candidate is dead again and rolls back as before.
  A create that was already attempted (`last_woke_at` set) keeps the old "attempt went stale" rule.

## Tests (`session_wake_budget_hold_test.go`, 4 tests, budget = 1)

* `TestWakeBudgetDeferral_KeepsNeverStartedCreateFromLeaseExpiry` — the 10/10 shape: 11 min old
  never-started create, deferred this tick => not lease-expired through all four predicates.
* `..._OnlyProtectsTheSessionThatWasDeferred` — controls: an undeferred dead create and a deferred
  create that already had its start attempt and went stale both still roll back.
* `..._HoldLapsesWhenTheDeferralStops` — held at +4 min, lapsed at +6 min, held again after a new deferral.
* `..._WholeWaveSkippedByBudgetIsHeld` — a wave the budget never reached (dependency wave) is held too.

The tests use only APIs that exist at `4f4837703`, so they compile there and fail by assertion. With the
two hooks and `session_wake_budget_hold.go` removed all 4 FAIL (e.g. `a create the wake budget deferred this
tick reads as lease-expired: the reconciler would roll it back and its replacement would join the back of the
queue`, `pendingCreateLeaseActive is false for a create the wake budget deferred this tick`); with the patch all 4
PASS. Run (needs the cgo ICU flags on this host):

```
git apply --check ga-4ytmas-wake-budget-hold.patch      # clean on 4f4837703, consolidated/engine-window-20260919,
                                                        # -20260926, -20261011, -20261011-cp and the stack HEAD c0d0f9b14;
                                                        # also clean AFTER ga-4ytmas-proc-snapshot-unknown.patch is applied
CGO_CPPFLAGS=-I/opt/homebrew/opt/icu4c@78/include CGO_LDFLAGS=-L/opt/homebrew/opt/icu4c@78/lib \
  go test -count=1 -run 'TestWakeBudgetDeferral' ./cmd/gc
```

## Limits (read before relying on it)

* In memory only: a supervisor restart drops the table and restores the old behaviour for one tick
  (the next tick that defers the create re-arms it).
* It only protects the queue wait. If the queue itself never reaches the create (budget always spent on
  longer-waiting sessions) the create still starts late; it just no longer loses its place every 10 min.
* Config alternative, not changed by me: `[daemon] max_wakes_per_tick` (2 today) is the direct knob for
  how fast the queue drains; raising it trades start storms under load for latency. That is the
  Mayor's/Athos's call.
* The two `deferred_by_wake_budget` sites in `executePlannedStartsTraced` are the only places in `cmd/gc`
  at `4f4837703` that defer a start for the budget (`git grep`), and both are marked. A create that is held
  back for any OTHER reason (dependencies not ready, rate limits, `provider_error`) is not covered and keeps
  the old 10 min rule.

## After the window

`/usr/bin/grep -c 'rolling back pending create' ~/.gc/supervisor.log` for a named crew should stop
growing while `deferred_by_wake_budget` lines for it are present, and the crew should come up on its turn.
