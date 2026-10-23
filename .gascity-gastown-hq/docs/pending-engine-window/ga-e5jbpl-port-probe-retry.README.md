# ga-e5jbpl — the managed-Dolt port probe stops reading "slow" as "down" (bd on port 0 under load)

## Contents

• State · What the patch does · Decisions worth challenging
• Tests and what they prove · Applying in the window · Verifying after the window · Rolling back
• What is NOT covered / NOT tested

Patch: `ga-e5jbpl-port-probe-retry.patch` (5 files: 3 production, 2 test; 355 added, 26 removed). NOT applied.
No build, no binary swap, no supervisor kickstart and no Dolt restart was done to produce it. The engine
window stays Mayor-coordinated. Base: `consolidated/engine-window-20261023` (`8f1be0e2b`, the live
`engwin-1023`). `git apply --check` is clean on that base (forward), and `--reverse` is clean on the patched tree.
No other pending patch in this directory touches `connection.go`, `portprobe.go` or `beads_provider_lifecycle.go`
(checked by file header); the only one that names them, `ga-3risy2-dolt-hold.patch`, is already in the base.

## State

On 23/10 at load ~84 (swap 4.5 GB) `bd` calls from dog-remote-3, hetzner-idle-session-reaper and
child-priority-janitor failed with `Dolt server unreachable at 127.0.0.1:0: ... can't assign requested
address` while Dolt was alive (pid up since 22/10, LISTEN on the port, `dolt-state.json` valid, the hang
watchdog saying "saturation, NOT a hang").

Chain, read in the code: `ResolveDoltConnectionTarget` → `readManagedRuntimePort` → `validManagedRuntimeState`
→ `contractPortReachable`, one `net.DialTimeout` of 250ms. On a saturated host the dial can take longer
(a full accept queue drops the SYN and the kernel retransmits after 1s), so it returned false and the
state was discarded as `ErrManagedRuntimeUnavailable`. `bdRuntimeEnvWithError` treats that as recoverable,
calls `clearProjectedDoltEnv` and returns an env without `GC_DOLT_PORT`; `bd` then runs its own discovery
and lands on port 0, whose error message looks like a broken config, not like load. A refused connection
(nobody listening) and a dial that never finished were the same `false`.

## What the patch does

* `internal/beads/contract/portprobe.go` (new): `ProbePort(host, port)` returns one of three answers —
  `PortProbeReachable`, `PortProbeRefused` (ECONNREFUSED, or a port that is not 1..65535: nothing to dial),
  `PortProbeInconclusive` (every attempt timed out or failed some other way). Only a refusal is final and is
  never retried. Anything else is retried with budgets of 250ms (the old single attempt, so a healthy
  server costs what it always cost), 1s, 2s and a 50ms pause between attempts; the 2s last attempt
  outlasts one SYN retransmit. A non-local host (`DoltHostIsLocal` false) is probed once, as before.
* `connection.go` `validManagedRuntimeState`: `contractPortReachable` is gone. A refusal → state invalid
  (unchanged). Reachable → valid. Inconclusive → valid **only when the host is local and the state's PID is
  alive** (the PID check that already ran is the corroboration); on a non-local host there is no PID, the
  probe is the only evidence, and an inconclusive probe stays "unavailable". Effect: `bd` gets the real
  port from the state file, dials it with its own timeout, and if that fails its error names
  `127.0.0.1:<real port>` instead of `:0`.
* `cmd/gc/beads_provider_lifecycle.go` `doltPortReachable`: same probe, same retry; still a bool
  (inconclusive → false, as today). This is the sibling 250ms probe behind `validDoltRuntimeState`.

## Decisions worth challenging

1. **Item (2) of the bead is met by behaviour, not by the literal text.** The bead asked for an error saying
   "runtime state valid but port X did not answer in N ms". The patch instead keeps the state and hands bd
   the real port, so the error bd prints is the true one. Reason: a new error type that is not
   `IsManagedRuntimeUnavailable` turns a transient miss into a hard failure for callers that return any
   other error (`bdRuntimeEnvWithError` does), and one that is would still end in its swallow-and-clear-env branch. If the explicit sentence is
   wanted, it is a follow-up in `bd_env.go`, not in the probe.
2. **A saturated-but-alive Dolt is no longer "recovered" through this branch.** Before, a slow probe made
   `resolvedRuntimeCityDoltTarget` (with recovery allowed) try `healthBeadsProvider` — the path that can
   restart Dolt. Now it returns the target. A genuinely hung Dolt is still caught by the reactive bd retry
   (`recoverManagedBDCommand`, with its cooldown), the controller tick and `dolt-hang-watchdog`; this branch
   was the one that could restart a Dolt that was only slow, which is the outcome to avoid.
3. **Worst-case wait: about 3.4 s** for a local port that neither answers nor refuses (250ms + 1s + 2s +
   two 50ms pauses; measured at 3.37 s on a black-holed address before the non-local carve-out). The
   healthy path and the refused path are unchanged. If that is too long for a hot caller, shorten the last
   entry of `portProbeTimeouts`; the tests assert it stays above 1s.
4. **`doltPortReachable` stays a bool.** Its callers (`validDoltRuntimeState` → port selection, state
   publication, rig endpoint, order store) decide things where "assume it is alive" is not obviously safe.
   Each needs its own audit before it can take the third state.

## Tests and what they prove

All run on the MBP (`mbp-run.sh --exec --go`), none on the mini.

* `portprobe_test.go` (8 tests, stubbed dial/sleep): refused is final and not retried; a timeout is retried
  and then connects; exhausted timeouts give Inconclusive and never Refused, with the per-attempt budgets
  asserted and the last one required to exceed 1s; EADDRNOTAVAIL (the exact error bd printed) is
  Inconclusive; refused after a timeout is final; a non-dialable port never dials; a non-local host is
  probed once; real sockets for reachable and closed.
* `connection_test.go` (4 new): a valid state with an inconclusive probe resolves to the state's port, for
  the city and for an inherited rig; a refused port is still `ErrManagedRuntimeUnavailable`; a non-local
  host with an inconclusive probe is still unavailable.
* Existing `TestResolveDoltConnectionTargetManagedCity_EnvOverrideAppliesToReachability` failed on my first
  version (it blackholes `192.0.2.1`); that is what produced the local-PID condition and the non-local
  single attempt above.
* Mutants (each reverts one rule; run on the MBP against the committed patch, tree restored after):
  A, inconclusive → down again: 2 new tests fail. B, one 250ms attempt: 3 fail. C, refused retried like
  any failure: 5 fail, among them the pre-existing `...RejectsManagedRuntimeStateWithUnreachablePort`.
  The unmutated patch: `ok`.
* `cmd/gc`: `go vet ./cmd/gc/ ./internal/beads/...` clean, and `go test ./cmd/gc/ -run 'Dolt|BdEnv|BDEnv|ManagedRuntime|OrderStore'`
  is `ok` (62 s on the MBP), which includes the existing `validDoltRuntimeState` tests that use real listeners.
  The rest of the `cmd/gc` suite was not run: it is long and the change there is one function.

## Applying in the window

`git apply docs/pending-engine-window/ga-e5jbpl-port-probe-retry.patch` on the window base, build on the
MBP, swap as usual. No data, config or script ships with it.

## Verifying after the window

1. The running binary has it: `strings $(readlink -f $(which gc)) | grep -c 'contract.ProbePort'` is at least 1.
2. Under load (the 23/10 condition: load above 60), run 50 `gc bd list --limit 1` and count
   `unreachable at 127.0.0.1:0` in stderr: expect 0. A failure should now name the real port.
3. `com.gascity.child-priority-janitor` stops reporting `unreadable_stores` on load spikes.

## Rolling back

`git apply --reverse` the patch and rebuild, or point `/opt/homebrew/bin/gc` back at
`~/.local/libexec/gc-1.1.1-engwin1023`.

## What is NOT covered / NOT tested

* Not reproduced under real saturation: load 84 cannot be summoned on demand. The behaviour is proven with a
  stubbed dial; the real-socket tests only cover reachable and refused.
* Other 250ms probes of the same family, left alone on purpose: `internal/doctor/checks.go`
  (`validPublishedManagedDoltDoctorState`, a report, so a false "not published" under load is cosmetic),
  `cmd/gc/cmd_dolt_cleanup.go` `probeDoltPort` (cleanup refuses on a miss, which is the inert side),
  `cmd/gc/dolt_wait_ready.go` (a poll loop that retries by itself).
* `test/integration/review_check_scripts_test.go` records an intermittent "unreachable at 127.0.0.1:0" in CI
  with the same shape; I did not check whether this patch removes it.
* The port-0 fall-through itself (bd's own discovery ending at port 0 when `GC_DOLT_PORT` is cleared) is not
  changed. With this patch the clear is reached less often; it is still reached for a refused or stale state.
