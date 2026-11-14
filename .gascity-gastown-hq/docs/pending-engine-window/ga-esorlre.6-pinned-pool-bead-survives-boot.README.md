## Contents

- What it fixes
- What the patch changes
- What was verified, and what was not
- How to land it
- What it does not do

## What it fixes

After the reboot of 13/11 the oracle-wa crew came back on a NEW conversation
(`7a02a6dc`) instead of the one armed for it (`a157fe65`, about 272k tokens).
Its session bead `ga-ltrmh9p` had `pin_awake=true`, `state=asleep`,
`sleep_reason=city-stop` and the armed `session_key`, and was closed by
`session swept: no assigned work in any rig` 8 minutes after boot (bead
`ga-esorlre.6`).

Two halves of the engine disagreed about that bead:

1. `ComputeAwakeSet` revives an asleep `city-stop` pool bead of a template with
   `min_active_sessions>0` ("min-active", #2739). It wanted this bead awake.
2. `reusablePoolSessionBead` skipped EVERY asleep bead, so pool realization
   planned a fresh bead next to it. The asleep bead dropped out of
   `desiredState`, `sweepUndesiredPoolSessionBeads` saw "undesired, no assigned
   work" and closed it. `pin_awake` was never consulted on that path.

The conversation armed on the bead (`session_key`, `session.resume_armed_id`)
went with it.

## What the patch changes

| File | Change |
|---|---|
| `cmd/gc/build_desired_state.go` | `reusableAsleepCityStopPoolBead`: an asleep bead IS reusable when `sleep_reason=city-stop`, the template has `min_active_sessions>0` and fewer beads than that minimum are already taken this tick (the same set `ComputeAwakeSet` revives). `reusablePoolSessionBeads` orders live beads before asleep ones. Every other asleep bead keeps the old rule. |
| `cmd/gc/city_runtime.go` | `sweepUndesiredPoolSessionBeads` skips a bead with `pin_awake=true` (`sessionPinnedAwake`). `gc session unpin` makes it sweepable again. |
| `cmd/gc/build_desired_state_test.go` | `TestSelectOrCreatePoolSessionBead_ReusesAsleepCityStopBeadWithinMinActive` (5 subtests: reused / idle-timeout / no reason / no minimum / minimum already met). |
| `cmd/gc/city_runtime_test.go` | `TestSweepUndesiredPoolSessionBeads_SkipsPinnedAwakeBead` (pinned kept, unpinned control swept, `pin_awake=yes` swept). |

Base: engine `origin/main` `8f1be0e2b3`. The patch avoids `session_reconciler.go`
on purpose: the engine-window branch (`d479473c81`) changes it.

## What was verified, and what was not

Verified:

- `git apply --check` passes on `origin/main` `8f1be0e2b3` AND on the window
  HEAD `d479473c81`.
- `gofmt -l` is clean on the four files.
- The cause was read in the engine source, not reproduced.

NOT verified: the Go tests have NOT been run. The runbook sends engine Go tests
to the MBP (never the mini) and the MBP was unreachable (`mbp-run.sh --check`
rc 98) on every check of the session, the last at 17:48 -03 on 14/11 after a
25-minute wait. So:

- the new tests were not run, and not shown to fail on the base;
- the neighbouring tests (`TestSweepUndesiredPoolSessionBeads*`,
  `TestSelectOrCreatePoolSessionBead*`, `TestComputeAwakeSet*`) were not run;
- the package was not built.

Treat the patch as unvalidated until the steps below pass.

## How to land it

1. Apply it to the window tree (`git apply <patch>`).
2. On the MBP: `scripts/mbp-run.sh --exec --go --push go.mod --push go.sum --push internal --push cmd -- sh -c 'cd in && go test ./cmd/gc -run "TestSweepUndesiredPoolSessionBeads|TestSelectOrCreatePoolSessionBead|TestComputeAwakeSet" -count=1'`, then the full `./cmd/gc` package.
3. A/B: revert only `build_desired_state.go` and `city_runtime.go` (keep the two
   test files) and confirm `..._ReusesAsleepCityStopBeadWithinMinActive/city-stop...`
   and `..._SkipsPinnedAwakeBead/pinned_is_kept` FAIL on that base. If either
   passes there, the test proves nothing: fix the test before landing.
4. Build and swap only in the engine window, by the Mayor.

Timing: the next nightly reboot is 14/11 23:40. The current oracle-wa bead
(`ga-ugfq9pl`) has the same shape, so unless this lands in the engine before
that boot the crew is exposed to the same sweep again.

## What it does not do

- The acceptance of `ga-esorlre.6` (post-boot `sessionId` equals the captured
  one, with a line in the `ga-esorlre.5` table) can only be filled after a
  reboot that runs the patched engine.
- It does not widen the assignee match to the session alias. Pool beads are
  matched by ID, `session_name` and `configured_named_identity` in both the sweep
  helper and the awake-set, and the two must stay aligned.
- The arm side (a zero-usage `<synthetic>` stub accepted as "0 tokens") is a
  separate fix, shipped through the gate as `ga-esorlre.6.1`.
