# ga-3risy2 — a supported hold for the managed Dolt ("down on purpose, nobody starts it")

## Contents

• State · What the patch does · The city side (usable before the window)
• Decisions worth challenging · Tests and what they prove · Applying in the window
• Verifying after the window · Rolling back · What is NOT covered / NOT tested

Patch: `ga-3risy2-dolt-hold.patch` (13 files: 8 edited, one of them a test file; 5 new, three of them tests). NOT applied.
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
  `gc dolt restart`, the supervisor and launchd all walk through. When the sibling `dolt-hold.sh`
  is not readable (focused test harnesses only; production always ships it) the script falls back
  to a small reader that is **stricter, never looser**: it does not read `expires_at` (the file's
  mere presence holds, so it can hold where the helper has released an expired hold), and anything
  it cannot see clearly (a dangling symlink, an unsearchable or non-directory parent, no path at
  all) is a hold. Only "the parent is gone" or "the parent is a searchable directory without the
  file" releases. A test holds it to that against the real helper, case by case.
* `examples/dolt/commands/restart/run.sh`: refuses BEFORE its stop step (a restart that stopped a
  running Dolt and then failed to start it would be the worst outcome). `--force` does not
  override a hold. If `dolt-hold.sh` is not readable the early check is skipped **and says so on
  stderr**; `gc-beads-bd.sh start` still refuses, but only after the stop.

## The city side (usable before the window)

* `scripts/dolt-hold-lib.sh`: the same reader for shell. `dolt_hold_blocks` is byte-identical to
  the engine helper (the selftest compares them against this patch).
* `scripts/dolt-hold.sh on|off|status`: places the hold atomically (a hard link, so it never lands
  over a hold in force; with nothing at the destination, of two concurrent `on` calls one wins and
  the other exits 3), default expiry 2 h (cap 12 h unless `--no-expiry`). `--ttl-secs` is decimal:
  `07200` is 7200 s, not octal; it excludes `--no-expiry` (exit 2), and an option's value cannot
  be another option (`--reason --no-expiry` is exit 2, not a reason). An unreadable clock refuses
  (exit 4). `--reason` is capped at 1000 bytes and `--owner` at 200 (exit 2, counted in bytes:
  600 `ã` are 1200), and `expires_at` is written BEFORE them, because both readers see only the
  first 4096 bytes. It never deletes anything: the hold is published with `ln`, which fails when
  the destination exists, so a valid hold that arrived while this `on` was preparing its own is
  left alone (exit 3), and an EXPIRED file left in place is refused too (exit 3, "run `off`"):
  it is released for the guards, but removing another operator's file is not something `on` does.
  After writing it reads back the first 4096 bytes (what the
  readers see, not the whole file) and requires both "a hold in force" and the `expires_at` it
  asked for (or none, with `--no-expiry`); a failed read-back is exit 4, never "no expiry". The
  temporary file is removed on any exit, including TERM/INT/HUP. `off` re-asks the reader after
  removing and exits 4 if a hold still blocks (for instance a hold file that exists but sits in an
  unsearchable directory), instead of reporting "nothing to remove".
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

**A hold over a HEALTHY Dolt is not quiet either.** `com.gastown.dolt-server` is a one-shot
launcher with `KeepAlive {Crashed, SuccessfulExit=false}`. Today `gc dolt start` against a running
Dolt exits 0 and launchd leaves it alone. With the patch and a hold, `start` refuses even when Dolt
is up (see Decisions), so it exits 1 and launchd relaunches the launcher about every 10 s until the
hold is removed or expires: one refused `gc dolt start` and one line in
`.gc/logs/dolt-server-launchd.err` per relaunch (roughly 360 an hour). Dolt itself is untouched and
keeps serving. It is bounded by the hold's expiry (2 h by default, 12 h at most unless
`--no-expiry`), and `dolt-hold.sh off` ends it. Read from the plist and the code, not exercised
live. If a long hold on a healthy Dolt is ever wanted, bootout the launchd job for that time (as
`hqswap.sh` does) rather than leave it looping.

## Decisions worth challenging

* **Unreadable = held.** A hold file that cannot be read or parsed blocks, like an active one: what
  it guards (starting or killing a Dolt on a directory being swapped) is the destructive act.
  Cost: a typo in `expires_at` keeps Dolt down until someone fixes the file; the message says so.
  Only an absent file (ENOENT) or a passed `expires_at` releases.
* **Expired ≠ removed.** Nothing deletes an expired file; readers treat it as released. That
  includes `dolt-hold.sh on`: over an expired leftover it refuses (exit 3) and says to run `off`
  first. The earlier behaviour (delete the expired file, then publish) was a check-then-act on a
  file that is not the tool's to delete: two `on` calls started together with an expired hold in
  place collided in 18 of 60 runs (10 with both exiting 0 and one hold silently replaced by the
  other, 8 with one exiting 4), and a valid hold arriving between the check and the `rm` was
  deleted. With `on` unable to delete, 60 of 60 runs were exact in each situation (nothing at the
  destination: one exits 0 and the other 3; an expired file in place: both exit 3 and the file is
  unchanged). Cost: one extra step (`off`, then `on`) when a forgotten expired hold is lying there.
* **`start` refuses even if a Dolt is already running.** Simpler to reason about than a partial
  carve-out. `ensure-ready` answers "already healthy" before it reaches `start`, so a running
  Dolt under a hold keeps serving.
* **Exit 1, not 2.** `runProviderOp` treats exit 2 as "not needed, success".
* **A forgotten hold is the main hazard.** Hence the 2 h default expiry in the tool. A bare
  `touch` has no expiry on purpose; use the tool.
* **The reader looks at the first 4 KiB.** Both readers (Go and shell) cap the read, so a file
  whose `expires_at` line sits past byte 4096 is read as having no expiry (an unexpired hold that
  never releases), and one cut in the middle of the digits reads as a shorter, probably already
  past, time. The tool used to be able to produce that itself (an unbounded `--reason` was written
  before `expires_at`, and its read-back looked at the whole file, so it reported success). Now
  `--reason`/`--owner` are capped, `expires_at` comes first, and the read-back uses the same 4096
  bytes the readers do. A hand-made file can still hit it; the tool cannot.
* **Boot with a hold on:** Dolt does not start (`gc dolt start` is refused), so the city cannot
  come up until the hold is released or expires. Expected from the code, not exercised. The
  expiry is what bounds this.

## Tests and what they prove

Run on the MBP (`mbp-run.sh --exec --go`): `go vet ./cmd/gc/` clean; the new Go tests and the
restart tests pass; `go test ./cmd/gc/ -run "Dolt|GCBeadsBd|BeadsProvider|BdEnv|BdCommand|ManagedBD"`
and `./examples/...` pass except 6 tests that fail identically on the untouched base `de525d882`
(3 `TestBackupScript…` — `flock` is missing on the MBP — and 3 `examples/gastown` TOML tests). The new tests **fail without the production change** (checked by reverting
only the production files): `RecoverManagedBDCommandAllowedRefusesUnderHold`,
`BdCommandRunnerWithManagedRetryDoesNotRecoverUnderHold`,
`EnsureManagedDoltPublishedForTickSkipsHealthUnderHold`, `HealthBeadsProviderDoesNotRecoverUnderHold`,
`ManagedDoltLifecycleEntryPointsRefuseUnderHold`, `GCBeadsBdRefusesStartAndRecoverUnderHold`
(real `gc-beads-bd.sh`, asserts no lock/pid/state file was created), and
`TestRestartRefusesUnderHoldBeforeStopping`. `TestReadManagedDoltHoldStates` runs every case
through the Go reader AND the shell helper and requires them to agree.
After the first gate review, three more were added test-first and watched failing against the
earlier code: `TestReadManagedDoltHoldUnreadableBlocks` gained a symlink whose target is missing
and a parent that is such a symlink (the Go reader said "no hold", the shell one held);
`TestGCBeadsBdFallbackHoldReaderNeverBlocksLessThanHelper` (11 situations, the fallback must hold
wherever the helper does; it failed for the dangling symlink, the dangling or regular-file parent,
the unsearchable parent and the missing path); `TestRestartWarnsWhenHoldHelperIsMissing`.
After the second gate review the same was done for a directory ABOVE the parent: the shell readers
(the engine helper, the city lib and the `gc-beads-bd.sh` fallback) read `[ -e parent ]` false as
"the parent is gone" even when the cause was EACCES or ENOTDIR on a component above it, while Go
held; and Go in turn read a dangling symlink above the parent as "no hold" while the shell held.
`TestReadManagedDoltHoldUnreadableBlocks` gained four subtests (unsearchable ancestor, a file in
place of an ancestor, a dangling-symlink ancestor, and the control: a symlink that resolves with
nothing under it must still read as "no hold" in both readers) and the fallback test gained three
situations (14 now) plus a `wantBlock` field so a scenario where the helper lets the path through
cannot pass vacuously. Each was run red first (the shell subtests against the previous helper,
the Go one against the previous reader, the fallback ones against the previous fallback).
After the third gate review the Go reader was fixed for a value it could not represent. It turned
`expires_at` into a `time.Time` and decided with `!now.Before(t)`; `time.Unix` adds 62135596800 to
the seconds, so from `expires_at=9223371974719179008` up the sum wraps to the year -292277022657
and the hold read as long expired, while the shell compares int64 seconds and held. A hand-written
"forever" (`9223372036854775807`) therefore released the hold on the engine side (controller tick,
`bd` retry, `gc dolt start/restart`) and kept it on the city guards. The hold now stores
`ExpiresUnix int64` and expiry is `ExpiresUnix <= now.Unix()` on both sides; `time.Unix` is only
used to print a date, and only up to year 9999 (later values are printed as raw seconds).
`TestReadManagedDoltHoldStates` gained five rows (MaxInt64, near-MaxInt64, the two seconds around
the wrap, 9e18), each run through the Go reader AND the shell helper; the city lib's
`dolt-hold.selftest.sh` gained the same five rows (those pass on both the old and the new shell
code: they pin the side Go has to match, they are not a red test). Two of that review's
non-blocking findings were fixed in the same pass because they share the class "the two readers
do not read the same bytes the same way": the Go reader trimmed with `strings.TrimSpace`, which
also trims Unicode spaces (U+00A0, U+0085) that the shell keeps, so a past expiry followed by a
no-break space read as expired in Go and as unreadable (hold) in the shell; it now trims the C
locale `[:space:]` set (`" \t\n\v\f\r"`) — three subtests. And `os.Open` on a FIFO at the hold path
blocks until a writer shows up, which would hang the controller tick; the reader now `Stat`s first
and answers "not a regular file → cannot tell → hold" without opening it
(`TestReadManagedDoltHoldFIFOBlocksWithoutHanging`, which fails after 5 s if the reader hangs).
Mutation check on the MBP, each applied to the finished reader and run against the tests that name
it: deciding with `time.Unix` again fails MaxInt64, near-MaxInt64 and the first second after the
wrap; `strings.TrimSpace` again fails the three no-break-space subtests; removing the
regular-file check fails the FIFO test; the unmutated reader passes all of them.

City side: `scripts/dolt-hold.selftest.sh` (102 checks, also under macOS `/bin/bash` 3.2), plus HOLD sections added to
`dolt-hang-watchdog.selftest.sh` and `dolt-disk-floor-guard.selftest.sh`; the HOLD assertions
fail against the pre-change guard scripts. After the third review the watchdog's hold block also
stopped hiding a failed `rm` of its old state (strikes, CPU-veto counter, PID baseline): it now logs
`WARN: HOLD — não consegui apagar o estado velho ...` and still exits inert, with two selftest
cases (the control with a working `rm` has no warning; with a read-only state directory the old
state stays, the warning is in the log, and there are 0 restarts and 0 probes).

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
* **Shell reader vs Go reader:** they agree on every tested case, including a dangling symlink at
  the hold path, as its parent or anywhere above it, an unsearchable directory anywhere above the
  hold, and a regular file in place of any ancestor (all hold), a symlink above the parent
  that resolves with nothing under it (both read "no hold"), every `expires_at` up to
  `9223372036854775807` (both compare int64 seconds; both hold), and a FIFO or other non-regular
  file at the hold path (both hold; Go does not open it). One known difference, with Go as the
  STRICTER reader (the shell can only release when the number it reads has really passed), from
  reading the code and not exercised: Go trims
  only the C-locale space set around `key`/`value`, while the shell's `[:space:]` follows the
  locale it runs in (launchd runs C), so a value with a no-break space next to the digits is
  unreadable (hold) in Go and, in a UTF-8 shell that counts that space as blank, a plain number
  in the shell. Residual, from reading the code and
  NOT exercised: `[ -e ]` cannot say WHY a stat failed. The shell tells ENOENT from EACCES/ENOTDIR
  by looking at the nearest component it can see; a failure of another kind in the middle of the
  path (EIO, a stale network mount) is invisible to it and reads as "gone", while Go (`os.Open`)
  holds.
* **A hold the readers cannot read is silent beyond the log.** The watchdog logs a line on every
  tick under an unreadable hold and stays inert (it also drops its strikes/veto/PID baseline each
  tick); nothing counts or pages "N ticks held-unreadable". Fail-closed is the choice, so a bad
  path or wrong permissions leave a real Dolt hang unrecovered with no signal other than that
  log line. A counter/page for it is a follow-up.
* **`kill -9` between `mktemp` and the publish** leaves `.dolt-hold.XXXXXX` next to the hold file.
  No reader looks at it (only `dolt-hold` counts); TERM/INT/HUP clean it up.
