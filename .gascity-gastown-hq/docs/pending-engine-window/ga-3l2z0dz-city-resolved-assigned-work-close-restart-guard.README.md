## Contents

- What it fixes
- Design (and why it is narrower than "storeRef == ''")
- Apply order and base
- Tests (A/B on the MBP)
- Tradeoffs
- Not covered / follow-ups

## What it fixes

Source bug: ga-3l2z0dz (follow-up of ga-gn35963). The "does this session still
hold live assigned work?" guard (`sessionHasOpenAssignedWorkForReachableStore`
and its siblings `sessionHasAwakeAssignedWorkForReachableStore`,
`firstOpenAssignedWorkBeadForReachableStore`, `collectSessionAssignedWork`)
read ONLY the city store whenever the session's agent resolved to the city
scope (`storeRef == ""`). `workdirutil.RoutingRigName` also returns `""` for an
agent whose `work_dir` is outside every rig (wa-worker-remote, dog-remote,
kimi-worker-remote, the `dog` pool: `work_dir = ".gc/agents/dogs/{{.AgentBase}}"`),
yet those agents claim from a rig store. Their `in_progress` bead was invisible,
so these paths concluded "no work" and closed or restarted a session holding a
live bead:

1. drain-ack close gate (`finalizeDrainAckStoppedSession`);
2. max-age restart;
3. drained pool-slot close;
4. `closeSessionBeadIfReachableStoreUnassigned`.

(The config-drift drain is the same guard; ga-gn35963 fixed that one call site.)

## Design (and why it is narrower than "storeRef == ''")

New `assignedWorkSearchesEveryStore(cityPath, cfg, session)` in
`cmd/gc/session_reconciler.go`: true when the agent template is not resolvable
(already the behavior) OR when `storeRef == ""` AND the agent has no `dir` AND a
non-empty `work_dir` (the "outside every rig" class). In that case the open /
awake / first-open / collector variants search the city store and every rig
store, using the existing `...InStores` helpers. `assignedWorkAgentForSession`
was split out of `assignedWorkStoreRefForSession` (same logic, no behavior
change) so the helper can read the agent.

`RoutingRigName == ""` means three different things; only the third is widened:

- no dir, no work_dir (genuine city-scoped, runs at the city root): city store
  only. KEPT. Pinned by `TestReconcileSessionBeads_{CloseGate,DrainAckedOrphanClose,SuspendedClose}IgnoresUnreachableRigAssignedWork`.
- dir set but no rig matches: untouched.
- no dir, work_dir outside every rig: WIDENED (the incident class).

A first draft widened every `storeRef == ""`. The full-suite run broke those 3
pins (a genuine city-scoped pool session was retained by rig-store work), so it
was narrowed. That draft is not in the patch.

Three states, none guessed (E12, `vazio -> sem trabalho; falhou/ilegivel -> erro`):
a hit in any store = has work; every store read cleanly = none; a store that
cannot be read = error, so the caller neither closes nor restarts (inert).

## Apply order and base

- Base: engine HEAD `8f1be0e2b3`. Apply from the engine repo root with `git apply`.
- Files: `cmd/gc/session_reconciler.go` (modified), and a NEW test file
  `cmd/gc/session_reconciler_citywide_assigned_work_test.go` (helpers prefixed
  `cwaw` to avoid collisions in package `main`).
- `git apply --check` OK on `8f1be0e2b3` alone, and for every order of this patch
  with ga-gn35963 and ga-epdbe3 (v1): mine alone; gn35963->mine; mine->gn35963;
  epdbe3->mine; mine->epdbe3; gn35963->epdbe3->mine; mine->gn35963->epdbe3;
  epdbe3->gn35963->mine; mine->epdbe3->gn35963. All 9 OK (applied sequentially
  in a scratch worktree, not just `--check` against the base).
- Independent of gn35963: after both, `sessionHasLiveAssignedWorkForConfigDrift`
  is partly redundant (it still also fans out for a genuine city agent at the
  drift site, as before; that behavior is unchanged).

## Tests (A/B on the MBP)

All via `scripts/mbp-run.sh --exec --go` (full push set incl. `test`), same test
file sha256 `881bcaa7c470dc12246ad0f7f7496cd89b4066d96e6518ddaa7e47f6b83e51d9`.
`session_reconciler.go` sha256: baseline `54ef4d0a...`, fixed `02b1aaa0...`
(verified on the MBP before each run).

| Tree | Command | Result |
|---|---|---|
| A: HEAD `8f1be0e2b3`, no fix | `-run` the new tests + the 3 pins | rc=1. FAIL (6): `TestCityResolvedSessionGuardSeesRigStoreWork`, `...FailsClosedWhenRigStoreUnreadable`, `TestFinalizeDrainAckStoppedSession_CityResolvedSessionWithRigWorkIsNotClosed`, `TestCloseSessionBeadIfReachableStoreUnassigned_CityResolvedSessionWithRigWork`, `TestMaxSessionAge_CityResolvedSessionWithRigWorkIsNotRestarted`, `TestDrainedPoolSlot_CityResolvedSessionWithRigWorkIsNotClosed`. PASS (controls): `...StillSeesCityStoreWork`, `...ReleasesWhenNoWorkAnywhere`, `TestRigResolvedSessionGuardStillScopedToItsOwnRig`, `TestGenuineCityScopedSessionGuardStaysCityOnly`, and the 3 `...IgnoresUnreachableRigAssignedWork` pins. |
| B: same + fix | `go vet ./cmd/gc` + full `go test ./cmd/gc -count=1 -v` | vet rc=0. All 6 failing tests above PASS, the 3 pins PASS, 6183 PASS lines. 10 FAIL, all unrelated (below). |
| C: gn35963 + epdbe3-v1 + this patch | `go vet` + `-run` ConfigDrift/ScriptsDrift/ScriptsOnly/ResumeWake/CityScope/ReconcileSessionBeads + the new tests | vet rc=0, `ok cmd/gc 40.3s`, 307 PASS, 0 FAIL. |

The 10 failures in B are environmental/pre-existing: the same 10 fail on
unpatched `8f1be0e2b3` on the same MBP (`TestGcBeadsBdStart*` x5 incl. 2
subtests, `TestCLIDocsFreshness`, `TestCmdSlingInlineBeadRigScopedBdProvider`,
`TestCmdSlingInlineBeadBareTargetFromRigCwdBdProvider`,
`TestResolveTemplateAssignedReadyQueryUsesBD105Compatibility`). Not caused by
this patch.

MBP note: `mbp-run.sh` does not wipe `~/gt-remote/exec/<slot>/in` at the START on
the MBP (only at the end). A first A run was contaminated by a stale foreign
`cmd/gc/session_close_gate_cityscope_work_test.go` (extra `TestCloseGate*` tests
that are not part of this patch; origin unknown, possibly another session's
debris or work on the same bug). That run was discarded; the slot was wiped and
the runs above contain no `close_gate` file.

## Tradeoffs

- A stale OPEN bead assigned to the session's name/id in a rig store can now
  defer a close or restart for an out-of-rig-work_dir agent. Before, it was
  invisible.
- An unreadable rig store now blocks close and restart for those sessions
  (fail-closed, E12). Genuine city-scoped sessions are unaffected.
- Detection is by config shape (no dir + non-empty work_dir). `dog`'s work_dir
  comes from a pack template; the tests use a literal out-of-rig work_dir
  (`.gc/agents/wa-worker-remote`) and do not exercise the pack template
  expansion.

## Not covered / follow-ups

- Agents with `dir` set that matches no rig: unchanged, no test.
- Redundancy of `sessionHasLiveAssignedWorkForConfigDrift` once both patches are
  in: a cleanup for after the window, not needed for correctness.
- Not built, not swapped, not kickstarted. Engine window is Mayor-scheduled.
