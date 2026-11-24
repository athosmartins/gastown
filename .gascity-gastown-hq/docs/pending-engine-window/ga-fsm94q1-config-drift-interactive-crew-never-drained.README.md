# ga-fsm94q1 — config drift drains an interactive crew (peter-wa) in the middle of the Athos's conversation

## Contents

• State · What was measured · Root cause · What the patch does · Tests · What it does NOT fix · Until the window · Apply / verify

Patch: `ga-fsm94q1-config-drift-interactive-crew-never-drained.patch` (5 files under `cmd/gc/`: `session_reconciler.go` and `soft_reload.go` edited, `session_drift_interactive_crew.go` and two test files new; +535 / -8).
Base: `consolidated/engine-window-20261023` (`8f1be0e2b3`), the commit the running binary (`gc-1.1.1-engwin1023`) was built from according to the READMEs of 11/11 (not re-checked on the mini for this patch).
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it. The engine window stays Mayor-coordinated.

## State

`git apply --check` is clean on the base alone and, in BOTH orders, with `ga-epdbe3`, `ga-gn35963` and `ga-3l2z0dz` and with the three stacked (throwaway index). `go vet ./cmd/gc` and `gofmt` are clean (`golangci-lint`/`gofumpt` are not installed on the node: the repo's `misspell` US-locale rule was checked by hand). RED is proven on the unpatched base: the 4 "spared" behavior tests FAIL by assertion there and pass with the patch (table in "Tests"). All 10 mutants were killed. The full `./cmd/gc` package has no red that the unpatched base does not also have.
Built and run on the Hetzner node (Go 1.26.5 linux/arm64) from the exact base tarball, not on the MBP or the mini. **Not verified on a running patched binary**: that can only happen after the window; the check is in "Apply / verify".

## What was measured

Reported by the bead (not re-measured here): on 24/11 13:39 the root-reconciler fast-forwarded the city to `14f98941f`; at 13:41:43 peter-wa logged `session.draining: config drift detected` (with wa-worker-remote-1/2/3 and 2 auto-refiners) and went `asleep` with reason `config-drift`; it left the Claude app while the Athos was working with it through Remote Control; the Mayor woke it at 13:51.

Measured on this node:

- `14f98941f` changes four files: `scripts/child-priority-janitor.py`, its selftest, a runbook and a plist, i.e. content of the city `scripts/` tree. Nothing in peter's own `agents/peter-wa/agent.toml` or in a provider changed. The bead's reading ("the commit did not touch crew config") is right, but the tree it touched is part of every agent's fingerprint:
- at the base, `resolveTemplate` (`cmd/gc/template_resolve.go:195-201`) stages the city `scripts/` directory into every session as a probed CopyFiles entry (`RelDst=".gc/scripts"`, `ContentHash = HashPathContent(scriptsDir)`), and probed entries are hashed into the core fingerprint by content. Any edit under `scripts/` therefore changes the core hash of every session whose agent stages scripts (`docs/runbooks/config-drift-wake.md` says the same: "toda mudança em `.gc/scripts` dispara config-drift"). **The field of `core_hash_breakdown` the bead asks about is, most likely, `CopyFiles` (the `.gc/scripts` entry)**. This is an inference from the commit and the code; the live line that proves or refutes it is in "Apply / verify".
- the repo does not mark `ga-epdbe3` (scripts-only drift of a resume-wake crew) or `ga-gn35963` (drift guard for out-of-rig pool workers, the wa-worker-remote-* case) as applied: both `.patch` files in this directory have no `APLICADO-` suffix. That is what the repo says, not what the live binary contains.
- reproduction on the unpatched base (`TestRemoteControlCrewSparedFromConfigDriftDrain` and its scripts-only sibling): an alive, idle, unpinned, unattached, non-named resume-wake session whose launch command carries `--remote-control` and whose config drifts gets `beginSessionDrain(reason=config-drift)`. The same session with the patch: no drain.

NOT measured (this node has no `supervisor.log`, no `.gc/`, no live binary): the drifted fields in peter's live log, which engine build is running, and whether the drain came from the reconciler or from the controller's watch-reload pass.

## Root cause

The drift paths protect a session only through signals that cannot see a Remote Control conversation:

1. Reconciler, alive session in drift (`session_reconciler.go`, drift branch): `sessionAttachedForConfigDrift` spares a session that is **pinned** (`pin_awake=true`) or has a **tmux client** attached (its doc comment says "including an external/Remote Control tmux client", i.e. a human attaching with tmux; the Claude app's Remote Control bridge is not a tmux client, as the comment of `ga-epdbe3` says). Nothing in the config pins a crew that is born fresh per touchpoint (peter, `city.toml` comment on `wa-14p4c`). Peter WAS drained, so by this guard it was neither pinned nor tmux-attached at 13:41 (a pinned or attached session is spared). After that the named-session branch does not apply (the crews are not `[[named_session]]`), and the ordinary branch only defers for a **pending interaction**, **live assigned work** in the agent's own store, a **gate-reviewer verdict** and an **ephemeral async start**. Between two turns a conversation has none of these, so the branch reaches `beginSessionDrain(... "config-drift")`.
2. Controller config reload (`city_runtime.go` tick, then `soft_reload.go` `acceptConfigDriftForProtectedSessions`): on a config change that is not an explicit `gc reload --soft` (the controller's own `source="watch"` reload, or a plain `gc reload`), the tick runs this acceptance pass BEFORE the reconciler. It accepts drift in place only for sessions `sessionProtectedFromConfigDrift` calls protected: always-on named, attached/pinned, pending interaction, named + recently active. An RC crew is none of those, so it is left to the reconciler (path 1). Only `gc reload --soft` accepts every open session, and the drift watcher's request for it waits for the single reload slot (`config-drift-watcher.sh` header: a held slot lasts 8-10 min under load), so until it lands the reconciler can see the drift first. Which of the two paths drained peter on 24/11 cannot be told from this node; the patch closes both.

`ga-epdbe3` (pending) closes only part of path 1: a **scripts-only** drift of a resume-wake crew is accepted in the reconciler. Any other drifted field still drains, and path 2 is untouched.

## What the patch does

New `cmd/gc/session_drift_interactive_crew.go`:

- `commandLaunchesRemoteControl(command)`: true when an argv token of the resolved launch command is `--remote-control` or `--remote-control=<name>`. The command is split with `shellquote.Split`, so a quoted argument that only mentions the flag (a prompt, a settings blob) is one token and does not match. A longer flag (`--remote-controller`, `--no-remote-control`) does not match. A false positive can only withhold a drain, never cause one.
- `sessionInteractiveCrewForConfigDrift(...)`: true when the agent's wake mode is `resume` (not `fresh`), the session is not in its creating window, it is not a gate-reviewer, and the command launches Remote Control. These are the same class conditions `ga-epdbe3` uses for "resume-wake interactive crew". It is a pure predicate over values the caller already read: no probe, no timing, so it has no false negative to destroy a conversation (same argument as `sessionIsAlwaysOnNamed`).
- `sessionInteractiveCrewForDriftAcceptance(...)`: the same, for the watch-reload pass, resolving agent and pre-heal state from the session bead and the desired-state entry.

`session_reconciler.go`: one new block in the alive-drift branch, between the attached/pinned deferral and the `recentlyDeferred` check (the hunk context does not overlap `ga-epdbe3`'s, which is why both stack in either order). For an interactive crew it cancels an in-flight config-drift drain, records trace outcome `deferred_active` with `active_reason=interactive_crew`, and `continue`s. It does NOT rewrite `started_config_hash`: the drift stays pending and the new config lands at the session's next natural restart. It writes nothing to the store, so a long-pending drift costs no Dolt commits (the attached deferral stamps do).

`soft_reload.go`: `acceptConfigDriftForProtectedSessions` also accepts in place (rebaselines the hash, cancels a stale drain) an interactive crew, so the next reconcile sees no drift. The crew clause is checked after `sessionProtectedFromConfigDrift`, adds no probe call and holds when the attachment probe errors or reads idle. The two comments that described the old rule are updated.

Scope is deliberately narrow: only resume-wake agents launched with Remote Control (the named crews: providers `claude-rc-*`). A fresh-wake pool worker is still recycled on drift (even if its command carried the flag). A resume-wake session without Remote Control keeps today's behavior (a tmux attach or a pin is already honored).

Three-state notes (E12): an agent missing from the config, an unknown template or an empty command is "not a crew" and keeps the existing handling, never a new drain; an unreadable state does not remove the protection (only `creating` does, as in `ga-epdbe3`); the attach-probe error path still returns before the new block, so a probe error still skips the tick.

## Tests

Run on the node: `go test ./cmd/gc -count=1 -v -run 'RemoteControl|InteractiveCrew'` (the pattern also catches 3 older `TestResolveTemplate…RemoteControl…` tests, which pass on both trees).

`session_reconciler_drift_interactive_crew_test.go` drives `reconcileSessionBeads` and `acceptConfigDriftForProtectedSessions` on an in-memory store and the fake runtime, with the shape of peter's session. It uses only helpers that already exist, so it compiles and runs on the unpatched base too:

| test | unpatched `8f1be0e2b3` | patched |
|---|---|---|
| `TestRemoteControlCrewSparedFromConfigDriftDrain` (Command drift; also asserts the process keeps running and `started_config_hash` is left stale = drift pending) | **FAIL**: drain begun, reason `config-drift` | pass |
| `TestRemoteControlCrewSparedFromScriptsOnlyConfigDriftDrain` (the 24/11 shape: only the `.gc/scripts` content hash changes) | **FAIL**: drained | pass |
| `TestRemoteControlCrewConfigDriftDrainInFlightIsCanceled` | **FAIL**: drain left in flight | pass |
| `TestRemoteControlCrewConfigDriftAcceptedInPlaceOnWatchReload` (acceptance pass, then a reconcile) | **FAIL**: `Updated=0` | pass |
| control `TestResumeCrewWithoutRemoteControlStillDrainsOnConfigDrift` | pass | pass |
| control `TestFreshWakeWorkerWithRemoteControlStillDrainsOnConfigDrift` | pass | pass |
| control `TestResumeCrewWithoutRemoteControlNotAcceptedOnWatchReload` | pass | pass |
| control `TestFreshWakeWorkerWithRemoteControlNotAcceptedOnWatchReload` | pass | pass |

`session_drift_interactive_crew_test.go` (unit; needs the new symbols): `TestCommandLaunchesRemoteControl` (14 cases: named, unnamed, `=name`, quoted name, quoted flag, and the misses: no flag, empty, blank, `--remote-controller`, `--no-remote-control`, a settings blob, a quoted prompt that mentions the flag), `TestSessionInteractiveCrewForConfigDrift` (7 cases: crew, unknown state, creating, fresh-wake, no flag, agent missing, gate-reviewer) and `TestSessionInteractiveCrewForDriftAcceptance` (6 cases: template from either source, none, agent missing, creating, fresh-wake). Patched run: all pass.

Mutation check: 10 single-edit mutants of the patched tree, one at a time, each proven to change the file (`git diff` non-empty before the run), run against the tests above:

| # | the one edit | killed by |
|---|---|---|
| M1 | reconciler block disabled (`if false && …`) | the 3 reconciler "spared" tests |
| M2 | in-flight drain not canceled (`drainCanceled := false`) | `…DrainInFlightIsCanceled` |
| M3 | watch-reload clause off (`!sessionInteractiveCrewForDriftAcceptance(…)` → `true`) | `…AcceptedInPlaceOnWatchReload` |
| M4 | wake-mode requirement dropped | the fresh-wake unit cases and both fresh-wake controls |
| M5 | creating-window exclusion dropped | the creating cases (crew predicate and acceptance wrapper) |
| M6 | gate-reviewer exclusion dropped | the gate-reviewer case |
| M7 | token match relaxed to `strings.Contains` | `longer flag`, `quoted prompt`, `flag only inside a longer quoted token` |
| M8 | `--remote-control=<name>` form dropped | `equals form` |
| M9b | `strings.Fields` instead of `shellquote.Split` (import kept so it still builds) | `flag itself quoted`, `quoted prompt`, `flag only inside a longer quoted token` |
| M10 | an unknown state loses the protection (`!= StateActive`) | `unknown state does not remove the protection` |

(A first M9 swapped the splitter without keeping its import used: BUILD-FAIL, not a kill. It was redone as M9b.)

Stacked: base + `ga-epdbe3` + `ga-gn35963` + `ga-3l2z0dz` + this patch, `go test ./cmd/gc -count=1 -v -run 'Drift|RemoteControl|InteractiveCrew|ScriptsOnly|ResumeWake|CityScope|Citywide|SoftReload|WatchReload'`: `ok`, 179 top-level PASS, 0 FAIL (the other three patches' own tests included, and all 11 new tests).

Full package: `go test ./cmd/gc -count=1 -parallel 6 -timeout 40m` on the patched tree (446 s): 6 FAIL, and the same 6 fail on a pristine `8f1be0e2b3` tree on this node (the six re-run there by name). None touches drift code. Four are the known reds of the 14/11 baseline run on this node (`TestCmdSlingInlineBeadRigScopedBdProvider`, `TestCmdSlingInlineBeadBareTargetFromRigCwdBdProvider`, `TestConfigWatchRegistrar_DoesNotWatchDoltBackupChildren`, `TestResolveTemplateAssignedReadyQueryUsesBD105Compatibility`). The other two (`TestDoInitFromDirPreservesPermissionsForLegacyTopLevelScripts`, `TestDoInitFromDirPreservesRealTopLevelScriptsForPackV2Template`) fail on both trees with `permissions = 700, want 755` because the session's umask is 077; under `umask 022` they pass on the patched tree. Nothing else in the package fails.

The patched files hash-match the tree the tests ran on: applying the `.patch` to pristine copies of the two edited base files gives the same sha256 as the tested tree for all five files.

## What it does NOT fix

- A config-drift drain that was ALREADY acked before this binary runs (a drain registered by the previous supervisor and left as `GC_DRAIN_ACK` on the tmux session): the drain-ack path still finishes it. New drains of an interactive crew are no longer started; the in-memory tracker does not survive a supervisor restart. Rare (a window swap with a drain in flight); guarding it needs the pre-heal state, which that site does not have.
- Remote Control is recognized by the launch flag, which is how this city enables it for every crew (the city's `--settings` carries `remoteControlAtStartup=false`, so the flag is what wins). RC turned on another way is not seen.
- A resume-wake session WITHOUT Remote Control, not attached and not pinned, mid-turn: unchanged (no such crew in this city).
- The `wa-worker-remote-*` and auto-refiner drains of the same event: `ga-gn35963` (pending) and the fresh-wake pool design. The watcher/reconciler race remains for pool sessions.
- Drift lands late by design: an interactive crew keeps its old config until its next natural restart (the nightly reboot per the `city.toml` note on the 23:1x crew change, `gc session restart <crew>`, an idle sleep/wake). Nothing in the patch restarts it.

## Until the window

`gc session pin <crew>` is honored today by the live guard (`sessionAttachedForConfigDrift`: `pin_awake`) and needs no engine change. It is per session: a crew born fresh at a touchpoint is unpinned again. Whether to pin is the Mayor's call; nothing here pins anything.

## Apply / verify

```bash
P="$GC_CITY_PATH/docs/pending-engine-window/ga-fsm94q1-config-drift-interactive-crew-never-drained.patch"
git -C <engine-tree> apply --check "$P" && git -C <engine-tree> apply "$P"        # clean on 8f1be0e2b3; stacks with ga-epdbe3 / ga-gn35963 / ga-3l2z0dz in any order
```

`ga-4ytmas-wake-budget-hold` and `ga-h9xpwb-read-mail-not-work` do not apply to `8f1be0e2b3` even alone (they target other bases); their `session_reconciler.go` hunks (`@@ -649`; `@@ -2877`, `-3042`, `-3223`) are far from this patch's `@@ -1854`, so there is no textual overlap to expect.

Three read-only checks for the mini, NOW, because this node cannot make them and they decide whether the bead's own hypothesis ("local edits in `city.toml`/`agents/*.toml`") or the `scripts/` explanation holds. The patch protects the crew whichever field drifted; the answer only changes what else to chase:

1. Which field: `grep -n 'config-drift-diag' ~/.gc/supervisor.log | tail -60`, then read the block printed for peter's session next to the 24/11 13:41 `Draining session '…': config-drift` line. Expected if this README is right: `drifted fields: CopyFiles` and a `CopyFiles[N]: RelDst=".gc/scripts"` line. A different field name (`Command`, `Env`, `OverlayDir`, ...) means the local-edits theory is the cause.
2. Which patches are live: `strings $(readlink -f $(which gc)) | grep -c -e resumeWakeScriptsOnlyConfigDrift -e sessionHasLiveAssignedWorkForConfigDrift`. `0` = neither pending patch is in the running binary (consistent with the incident); more than `0` = at least one is, and the drain came through a different field or path.
3. Peter's launch: `ps -o command= -p $(pgrep -f 'remote-control Peter' | head -1)` shows `--remote-control Peter`, the literal this patch keys on.

After the window: `strings $(readlink -f $(which gc)) | grep -c sessionInteractiveCrewForConfigDrift` returns more than `0` AND the supervisor was restarted after the swap; then commit a harmless change under `scripts/` while a crew is in a Remote Control conversation and confirm the crew is not drained (supervisor log: `config-drift-diag` for it, no `Draining session '<crew>': config-drift`; trace: `deferred_active` / `interactive_crew`).
