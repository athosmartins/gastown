## Contents

- What it fixes
- Apply order and base
- Tests (A/B on the MBP)
- Not covered / follow-ups

## What it fixes

A scripts-only config drift (`.gc/scripts` CopyFiles content hash) drained
`wake_mode=fresh` pool sessions that were holding a live `in_progress` bead.

The drift drain already has a "live assigned work" guard
(`sessionHasOpenAssignedWorkForReachableStore`, logs `Skipping config-drift
drain for 'X': live assigned work found`). It looks in the agent's configured
store only. `assignedWorkRoutingStoreRefForAgent` resolves a rig only when the
agent has `dir` or a `work_dir` INSIDE a rig (gt-69j2v). An agent whose
`work_dir` is outside every rig, with no `dir` and no `scope`, resolves to `""`
(city store), so the guard searched the city store while the bead it claimed
lives in a rig store.

Measured in `~/.gc/supervisor.log`: `wa-worker-remote-gawispqzvrh`, assignee
`wa-worker-remote-1`, bead `wa-p7ag21.14.2.3` `in_progress` in the WA store,
drained twice with no "Skipping" line; `wa-worker-adhoc-*` (work_dir inside the
rig) logged "Skipping ... live assigned work found" for the same drift.
Same shape (work_dir outside any rig): `wa-worker-remote`, `dog-remote`,
`kimi-worker-remote`, `dog`.

The patch adds `sessionHasLiveAssignedWorkForConfigDrift`
(`cmd/gc/session_drift_assigned_work.go`) and uses it at the drift drain site
only. It is the old probe plus ONE case: when the session resolves to the city
store (`storeRef == ""`), every attached rig store is searched too. Three
states, none guessed: a hit anywhere = has work (defer the drain); every store
read cleanly = no work; a store that cannot be read = can't know, so the error
is returned and the drift site skips the drain this tick (already its behavior
on an error). A session whose rig IS resolved keeps the single-rig answer.

## Apply order and base

- Base: engine HEAD `8f1be0e2b3` (origin/main, 2026-10-23).
- It does not depend on the v1 patch (`ga-epdbe3-...-resume-wake-accept.patch`)
  and applies in either order: checked with `git apply --check` alone on
  `8f1be0e2b3` and after v1's `session_reconciler.go` hunks. Its tests are in a
  NEW file (`session_reconciler_drift_cityscope_work_test.go`) on purpose.
- v1 (`ga-epdbe3-...-resume-wake-accept.patch`) was re-anchored on `8f1be0e2b3`
  by ga-meokeks (12/11): its test hunk used to be rejected at
  `session_reconciler_scripts_drift_test.go:263` (the gt-69j2v test became the
  last function). The file now applies clean on `8f1be0e2b3` alone, and in
  either order with this patch (`git apply --check`, checked both orders).
  Only hunk headers and `index` lines changed; the added code is the same.

## Tests (A/B on the MBP)

New file `cmd/gc/session_reconciler_drift_cityscope_work_test.go`, awake fresh
session, scripts-only drift. Run on the MBP with `mbp-run.sh --exec --go`.

Same test file (sha256 `849651e9...`) on two trees, both on the MBP via
`mbp-run.sh --exec --go`, `go test ./cmd/gc -count=1 -v`:

| Tree | Result |
|---|---|
| HEAD `8f1be0e2b3` + v1 (src + tests), WITHOUT this patch's fix | rc=1. FAIL: the incident shape (4 subtests: assignee = session name / session id x in_progress / open), the city-scoped agent with work in a rig store, and the unreadable-rig-store test. PASS (controls): work in the city store, no work anywhere, work of another session, closed work, rig-resolved agent with work only in another rig. |
| same + this patch | rc=0, `ok cmd/gc 20.5s`: the new tests plus every existing ConfigDrift / ScriptsDrift / ScriptsOnly / ResumeWake test (92 PASS lines) |

The patched `session_reconciler.go`, `session_drift_assigned_work.go` and test
file hash-match the tree the MBP ran (v1 src hunks + this patch).

Note for test authors: `MemStore.Create` ignores the Status and ID it is given
(always "open", "gc-N"). The helper applies the status with `Update` and asserts
it. A first version of the tests missed this, which made the `closed` and
`in_progress` cases vacuous; the A/B above is of the corrected file.

## Not covered / follow-ups

- Same blind spot, NOT changed here: the other callers of
  `sessionHasOpenAssignedWorkForReachableStore` (drain-ack close gate, max-age
  restart, drained-slot close, `closeSessionBeadIfReachableStoreUnassigned`).
  For a work_dir-outside-rig agent they can close a session bead or restart a
  session that owns rig-store work. Widening the shared helper changes close
  behavior city-wide; left as its own bead.
- `claude-headless-*` drains in the same log are NOT explained by this cause:
  it is rig-scoped (alias `whatsapp_automation/claude-headless-1`), so its rig
  resolves. Probably drained while holding no assigned bead; unconfirmed.
- Not built, not swapped, not kickstarted.
