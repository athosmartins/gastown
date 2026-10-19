# ga-2hd02v.1.22 — a manual session that `idle_timeout` put to sleep stays asleep

## Contents

• What was measured (19/10) · Root cause · What the patch does · Tests · What it does NOT fix · Apply / validate · After the window

Patch: `ga-2hd02v.1.22-manual-idle-timeout-stays-asleep.patch` (2 files under `cmd/gc/`: 1 edited, 1 new test file).
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it.
The engine window stays Mayor-coordinated.

## What was measured (19/10)

`dog-remote-1/2/3` (Hetzner node) sat 47–60 min with no `in_progress` bead and were still `active` in `gc session list`
and in the provider's `list-running`, although `agents/dog-remote/agent.toml` has `idle_timeout = "15m"`.
`hetzner-capacity.py verdict` was `local:node_full` on every sweep since node-first went on (15:25): 0 beads reached the node.

From the city events and the session beads, per session: `session.idle_killed` fires at ~15 min (the engine DOES kill it,
`sleep_reason=idle-timeout`, `state=asleep`), and the same session is woken again 1–9 min later as a fresh claude with no bead.
Same loop for the `gate-reviewer-remote-adhoc-*` sessions.

## Root cause

The Pilot opens `dog-remote` sessions with `gc session new`, so their session beads carry `session_origin=manual`
(`isManualSessionBead`). In `ComputeAwakeSet` (`cmd/gc/compute_awake_set.go`, tag `engwin-20261011b`) the "Manual sessions"
pass does:

```go
if !bead.ManualSession || bead.State == "closed" || bead.Drained { continue }
if _, ok := agentsByName[bead.Template]; ok { desired[bead.SessionName] = "manual" }
```

so a manual session is desired no matter why it is asleep. The idle kill in `session_reconciler.go` (`SleepPatch(..., "idle-timeout")`)
is therefore undone by the next reconcile, which wakes the bead as a new process. Nothing else can stop it:

* idle-sleep (`sleep_after_idle` / `ChatIdleTimeout`) does not apply: the class is `interactive_fresh` and the provider capability
  is `timed_only`, so the effective policy is `off`, and `reconcileDetachedAt` clears `detached_at`;
* `configWakeSuppressed` returns false for `sleep_reason=idle-timeout` on purpose (an idle-timeout kill is a *recycle* for sessions
  that still have a reason to exist: pool demand, min_active, named-always, assigned work).

For a pool agent whose sessions are all manual (`min_active_sessions = 0`, opened by the Pilot) there is no such reason, and the
recycle is a resurrection.

## What the patch does

One guard in the Manual-sessions pass: a manual, non-closed, non-drained session with `state == "asleep"` and
`sleep_reason == "idle-timeout"` is **not** put in `desired` as `"manual"`. It stays asleep until a pass that carries real demand
wakes it, all of which already exist and run before/after that pass:

| wake path | where | reason in the result |
|---|---|---|
| `gc session wake` (what node-first does for an asleep alias) | `ExplicitWake` pass | `explicit-wake` |
| work assigned to the session (bead or session name) | assigned-work pass | `assigned-work` |
| controller create claim | `PendingCreate` pass | `pending-create` |
| pending interaction / attached client | overrides after `desired` | `pending` / `attached` |

Side effect (wanted): the `explicit-wake` reason is no longer overwritten with `manual` for such a session.

Narrow on purpose: any other `sleep_reason` (empty, `idle`, `city-stop`, `drained`, `runtime-missing`...) keeps the old behavior;
`state` `creating`/`active` is untouched — `preWakeCommit` keeps `sleep_reason=idle-timeout` until the replacement has really started,
but it moves `state` to `creating`, so a start in flight is not blocked; non-manual (pool) sessions are untouched.

## Tests (`compute_awake_set_manual_idle_timeout_test.go`, 10 tests)

* RED without the guard (3): `StaysAsleep`, `StaysAsleepAcrossTicks`, `ExplicitWakeWakes` (reason is `manual`, not `explicit-wake`).
  Measured on the MBP at tag `engwin-20261011b`: `session "s-mc-1" should be asleep but is awake (reason: manual)`.
* Controls that pass either way and pin the boundaries (7): assigned work, pending create, pending interaction and attached still wake;
  `state=creating` with `sleep_reason=idle-timeout` still wakes; every other sleep reason is still `manual`; an `active` session is unaffected.

## What it does NOT fix

* The first 15 min. The patch only changes what happens after `idle_timeout` fires; until then an idle remote dog is alive (as designed).
* `_pilot_node_pick_alias` (pilot-dispatcher.sh) only picks aliases that are `new` or `asleep`. After the patch the idle-killed aliases
  ARE `asleep`, so they become pickable; before it, an awake-idle alias blocks dispatch. The oracle fix (`hetzner-capacity.py`, same bead)
  already stops reporting `node_full` for idle sessions, but it cannot make the Pilot pick an *awake* idle alias.
* A start that fails after an explicit wake: `preWakeCommit` keeps `sleep_reason=idle-timeout` on retry, and a consumed `wake_request`
  is not re-issued by this patch. Assigned work re-wakes by itself; for node-first the next dispatch sweep calls `gc session wake` again.

## Apply / validate

```
git apply --check ga-2hd02v.1.22-manual-idle-timeout-stays-asleep.patch   # clean on engwin-20261011b, consolidated/engine-window-20261011,
                                                                           # -20260926 and the local stack HEAD 64dc28fcc
# Go only on the MBP (ga-edkfip); cmd/gc needs go.mod go.sum internal cmd examples third_party schemas schemas_embed.go test
scripts/mbp-run.sh --exec --go --push go.mod --push go.sum --push internal --push cmd --push examples --push third_party \
  --push schemas --push schemas_embed.go --push test -- sh -c 'cd in && go test ./cmd/gc -run "TestManual_|TestIdleSleep_" -count=1 -v'
```

## After the window

* `grep -c session.idle_killed` for `dog-remote-*` in the city events should keep appearing, and the same session should **not** be
  followed by a `session.woke`/start within minutes without a bead; `gc session list --json` should show idle dog-remote sessions as
  `asleep`, not `active`.
* Then node-first can dispatch to the node: `scripts/hetzner-capacity.py --json verdict` → `node` and Pilot `node_first` lines with a pick.
