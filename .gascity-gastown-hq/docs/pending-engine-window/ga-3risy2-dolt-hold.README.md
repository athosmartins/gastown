# ga-3risy2 — a supported hold for the managed Dolt ("down on purpose, nobody starts it")

## Contents

• State · What the patch does · The city side (usable before the window)
• Decisions worth challenging · Tests and what they prove · Applying in the window
• Verifying after the window · Rolling back · What is NOT covered / NOT tested

Patch: `ga-3risy2-dolt-hold.patch` (12 files: 8 edited, one of them a test file; 4 new, two of them tests). NOT applied.
No build, no binary swap, no supervisor kickstart and no Dolt restart was done to produce it.
The engine window stays Mayor-coordinated. Base: `consolidated/engine-window-20261016`
(`de525d882`, the live `engwin-1016`). `git apply --check` is clean on that base, and the patch
stacks with `ga-k7o6ou-dolt-bind-loopback.patch` in both orders (the only pending patch that
touches the same files: `gc-beads-bd.sh`, `dolt_start_managed.go`, `dolt_recover_managed.go`).

## State

Stopping the managed Dolt on purpose (swap a database directory, offline GC, restore drill) was
impossible without shutting the whole city down. Four things bring a stopped Dolt back within
seconds: the controller tick (`ensureManagedDoltPublishedForRuntime` → `healthBeadsProvider`
→ `recover`), the reactive bd retry (`recoverManagedBDCommandAllowed` → `recoverManagedBDCommand`),
the launchd job `com.gastown.dolt-server` (runs `gc dolt start`, `KeepAlive` on failure), and the
city's own watchdogs (`dolt-hang-watchdog`, `dolt-disk-floor-guard._resurrect_dolt`). `hqswap.sh`
works around it by booting out launchd jobs and suspending the city; a hold makes that
unnecessary for the Dolt part.

## What the patch does

A hold is the file `<pack-state-dir>/dolt-hold` (`GC_DOLT_HOLD_FILE` overrides). Optional
`key=value` lines: `expires_at=<unix secs>`, `owner=`, `reason=`. A bare `touch` holds until the
file is removed. While it holds, nothing starts, recovers or restarts the managed Dolt.

* `cmd/gc/dolt_hold.go` (new): the reader. Four states — none / active / expired / unreadable —
  and `Blocks()` is true for active **and** unreadable.
* `city_runtime.go` `ensureManagedDoltPublishedForRuntime`: no health preflight under a hold;
  one log line per 10 min per city instead of one per tick.
* `beads_provider_lifecycle.go` `healthBeadsProvider`: the health op still runs; a failure under a
  hold returns `errManagedDoltHeld` (wrapping the health error) **before** the recover-cooldown
  stamp, so a refused attempt spends nothing a real outage needs after the release.
* `bd_env.go` `recoverManagedBDCommandAllowed`: returns false first, before the gate file, so the
  cooldown stamp is untouched. The plain bd retry still happens; it just does not recover.
* `dolt_start_managed.go` / `dolt_recover_managed.go`: last line of defence. Every route that
  spawns Dolt ends in `startManagedDoltProcessWithOptions`; recover would STOP a running server
  before starting, so its check comes before the lifecycle lock.
* `examples/bd/assets/scripts/gc-beads-bd.sh` + new `dolt-hold.sh`: `op_start` and `op_recover`
  refuse with exit 1 (exit 2 reads as success to the Go caller). This is the door `gc dolt start`,
  `gc dolt restart`, the supervisor and launchd all walk through.
* `examples/dolt/commands/restart/run.sh`: refuses BEFORE its stop step (a restart that stopped a
  running Dolt and then failed to start it would be the worst outcome). `--force` does not
  override a hold.

## The city side (usable before the window)

* `scripts/dolt-hold-lib.sh`: the same reader for shell. `dolt_hold_blocks` is byte-identical to
  the engine helper (the selftest compares them against this patch).
* `scripts/dolt-hold.sh on|off|status`: places the hold atomically, default expiry 2 h (cap 12 h
  unless `--no-expiry`), refuses to overwrite a hold in force, verifies what it wrote.
* `dolt-hang-watchdog.sh`: under a hold, no probe, no strike, no restart, no death snapshot, and
  it clears strikes / CPU-veto / PID baseline so the first tick after the release starts clean.
* `dolt-disk-floor-guard.sh` `_resurrect_dolt`: no `gc dolt start`, and — before any escalation —
  no page for a "resurrection that failed".

⚠️ **Until this patch is in the binary, only those two guards honor the file.** The supervisor
tick, the bd retry and `com.gastown.dolt-server` would still bring Dolt back. Check with
`strings $(readlink -f $(which gc)) | grep -c dolt-hold`.

Order of use: `dolt-hold.sh on` → stop Dolt (`gc-beads-bd.sh stop`) → do the work → `dolt-hold.sh off`.
After `off`, launchd's retry brings Dolt up on its own: the plist sets no `ThrottleInterval`, so the
default 10 s applies, and under a hold each relaunch of `gc dolt start` is refused (cheap). Or run
`gc dolt start` by hand.

## Decisions worth challenging

* **Unreadable = held.** A hold file that cannot be read or parsed blocks, like an active one: what
  it guards (starting or killing a Dolt on a directory being swapped) is the destructive act.
  Cost: a typo in `expires_at` keeps Dolt down until someone fixes the file; the message says so.
  Only an absent file (ENOENT) or a passed `expires_at` releases.
* **Expired ≠ removed.** Nothing deletes an expired file; readers treat it as released.
* **`start` refuses even if a Dolt is already running.** Simpler to reason about than a partial
  carve-out. `ensure-ready` answers "already healthy" before it reaches `start`, so a running
  Dolt under a hold keeps serving.
* **Exit 1, not 2.** `runProviderOp` treats exit 2 as "not needed, success".
* **A forgotten hold is the main hazard.** Hence the 2 h default expiry in the tool. A bare
  `touch` has no expiry on purpose; use the tool.
* **Boot with a hold on:** Dolt does not start (`gc dolt start` is refused), so the city cannot
  come up until the hold is released or expires. Expected from the code, not exercised. The
  expiry is what bounds this.

## Tests and what they prove

Run on the MBP (`mbp-run.sh --exec --go`): `go vet ./cmd/gc/` clean; the new Go tests and the
restart tests pass. The new tests **fail without the production change** (checked by reverting
only the production files): `RecoverManagedBDCommandAllowedRefusesUnderHold`,
`BdCommandRunnerWithManagedRetryDoesNotRecoverUnderHold`,
`EnsureManagedDoltPublishedForTickSkipsHealthUnderHold`, `HealthBeadsProviderDoesNotRecoverUnderHold`,
`ManagedDoltLifecycleEntryPointsRefuseUnderHold`, `GCBeadsBdRefusesStartAndRecoverUnderHold`
(real `gc-beads-bd.sh`, asserts no lock/pid/state file was created), and
`TestRestartRefusesUnderHoldBeforeStopping`. `TestReadManagedDoltHoldStates` runs every case
through the Go reader AND the shell helper and requires them to agree.

City side: `scripts/dolt-hold.selftest.sh` (57 checks), plus HOLD sections added to
`dolt-hang-watchdog.selftest.sh` and `dolt-disk-floor-guard.selftest.sh`; the HOLD assertions
fail against the pre-change guard scripts.

## Applying in the window

```
git -C <engine-tree> apply --check docs/pending-engine-window/ga-3risy2-dolt-hold.patch
git -C <engine-tree> apply        docs/pending-engine-window/ga-3risy2-dolt-hold.patch
```

The shell parts ride in the binary: `examples/bd` is embedded with `all:assets`, so the new
`dolt-hold.sh` is materialized next to `gc-beads-bd.sh` on the next start. Nothing else to
install. Validate Go on the MBP (never a cold build on the mini: `heavy-guard.sh`).

## Verifying after the window

Safe on a live Dolt (none of these touches it):

1. `ls .gc/system/packs/bd/assets/scripts/dolt-hold.sh`
2. `scripts/dolt-hold.sh on --reason "verify ga-3risy2" --ttl-secs 300`, then
   `gc dolt start` → must print `dolt start refused: dolt is on hold (...)` and exit 1;
   `gc dolt restart` → must refuse BEFORE stopping (Dolt keeps its PID);
   `scripts/dolt-hold.sh off`.
3. `scripts/dolt-hold.sh status` → exit 1, "sem hold".

The first real use (Dolt actually stopped, hold on, wait past a controller tick and a watchdog
cycle, Dolt stays down) belongs in a maintenance window, e.g. the hq swap.

## Rolling back

`scripts/dolt-hold.sh off` ends any hold at once. To drop the feature, revert the patch and
restore the previous binary (`gc` symlink). The city-side scripts are inert without a hold file.

## What is NOT covered / NOT tested

* **Never run against a really stopped Dolt.** Everything above uses stubs, fakes and a
  scratch city; doing it live would take the production data plane down.
* **Alarms that page when Dolt is down** (`gate-recovery-watchdog`, `throughput-stall-watchdog`,
  `pipeline-throughput-heartbeat`, `dolt-latency-alarm`, ...) are not silenced; they restart
  nothing, they only page. The window silences them the way `hqswap.sh` does today.
* **`bd` itself does not auto-start a server here** (`dolt.auto-start: false`,
  `BEADS_DOLT_AUTO_START=0` set by gc), so it is not a respawner; the hold does not cover a city
  where that is turned on.
* **`hqswap.sh` is not changed.** It still freezes launchd and suspends the city; adopting the
  hold there is a follow-up once this is live.
* **Shell reader vs Go reader:** they agree on every tested case; they differ only if a regular
  file sits further up the path than the immediate parent (Go: unreadable/blocks; shell: reads as
  "absent").
