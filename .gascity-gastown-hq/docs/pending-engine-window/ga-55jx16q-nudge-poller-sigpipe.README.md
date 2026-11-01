# ga-55jx16q — the `gc nudge poll` that `gc session nudge` starts dies of SIGPIPE, and the nudge stays PENDING

## Contents

• State · What was measured (31/10) · Root cause · What the patch does · Tests · What it does NOT fix · Until the window · Apply / verify

Patch: `ga-55jx16q-nudge-poller-sigpipe.patch` (2 files under `cmd/gc/`: `cmd_nudge.go` edited, `cmd_nudge_poller_resilience_test.go` new).
Base: `consolidated/engine-window-20261023` (`8f1be0e2b`), the commit the running binary (`gc-1.1.1-engwin1023`) was built from.
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it. The engine window stays Mayor-coordinated.
Repro harness for the root cause: `ga-55jx16q-nudge-poller-sigpipe.repro.py`.

## State

Validated on the MBP (`gofmt` clean, `go vet ./cmd/gc` ok, `go test ./cmd/gc -run 'Nudge|Poll'`: 206 pass, 0 fail, 5 pre-existing skips) and
mutation-tested (7 mutants, all killed). **Not verified on a running patched binary**: that can only happen after the window; the check is in "Apply / verify".
The bead's original premise (the idle detector is blind to the "Compacted while idle" banner or to a draft) was **measured and did not hold** on the pane examined.

## What was measured (31/10)

A wait-idle nudge to `digo-wa` (`nudge-504c91539b9f`, enqueued 23:53:22Z) was still `PENDING due=now`, attempts null, ~1 h 54 min later. `oracle-wa` showed 5 PENDING.

| Hypothesis (from dog-remote-1's hand-off) | Verdict | Evidence |
|---|---|---|
| H1 the detector reads the post-compaction pane as busy/unknown | **not the cause for this pane** | `tmux capture-pane` of `digo-wa`: prompt `❯`+NBSP with SGR-faint ghost text (not a human draft), banner above the prompt, footer without `esc to interrupt`. The live `WaitForIdle` rules (re-implemented in Python from `tmux.go` at `8f1be0e2b`, not the Go binary) return IDLE. |
| H2 the pane repaints, so the 3 s quiescence never arrives | **false** | `window_activity` unchanged over 15 s for `digo-wa` and `oracle-wa` (digo-wa silent for 13 min). |
| H3 the poller is not alive | **confirmed** | No `gc nudge poll` for `digo-wa`. Its PID file was written 20:53:27 local, 5 s after the enqueue; PID 74951 was dead. A poller started by hand with the same argv and stderr on a file delivered the nudge in < 25 s (queue 0/0/0; `digo-wa` went active, ctx 0 % → 18 %). |

The live binary has none of the upstream 3-state symbols (`ErrWaitUnobserved`, `ClassifyIdlePane`, `PaneShowsIdlePrompt`, `ErrIdleIndeterminate`), so the upstream detector fix is not in it; this bug is not about that code.

## Root cause

`ensureNudgePoller` (`cmd_nudge.go`) spawns the poller with `cmd.Stdout = cmd.Stderr = io.Discard`. `os/exec` turns any writer that is not an `*os.File` into a **pipe whose
read end stays in the parent**. `gc session nudge` is a short-lived CLI; once it exits the poller's fd 1/2 have no reader, and the Go runtime kills a process on its first write to a broken fd 1 or 2.
Every `gc` start prints a pack-drift warning to stderr, so that write comes at once.

Reproduced with the real binary and a harmless target (`ga-55jx16q-nudge-poller-sigpipe.repro.py`):

| stdio of the spawned `gc nudge poll` | result |
|---|---|
| pipes, parent-side reader closed (what the CLI path produces) | **dead, rc −13 (SIGPIPE), after 1.2 s** |
| `/dev/null` file (control) | alive after 20 s |

It is a race between the spawner's lifetime and the poller's first write. A poller whose spawner lingers survives until its next write: a live one (`gate-reviewer-remote-adhoc-ef8668b5a0`,
parent `launchd`, fd 1/2 = PIPE) was 1 h 44 m old; it is a latent time bomb. Nothing re-arms a dead poller: the enqueue is the only place that starts one, and the other drain
path (the `UserPromptSubmit` hook) only runs when someone submits a prompt, which an idle crew does not.

Secondary, also real: `cmdNudgePoll` exited `1` on ANY failed `workerObserveNudgeTarget`, and `shouldKeepNudgePollerAlive` read an unreadable queue as empty. The poller logs that still
exist (the session-submit spawn writes a `.log`) hold 14 such deaths: `gc nudge poll: getting session: … [mysql] packets.go:58 unexpected EOF` and `… dolt circuit breaker is open …`.

## What the patch does

1. `ensureNudgePoller`: stdout/stderr go to the session's `.log` (same file the submit poller uses); if it cannot be opened they stay `nil` (null device, a real fd), never `io.Discard`. A poller that dies now leaves its last words.
2. `cmdNudgePoll` → `runNudgePollLoop` + `decideNudgePollRound`: a failed observation is a third state ("unknown"), not "gone" and not "empty". The poller backs off (2 s doubling to 30 s), logs one line per failure streak and one on recovery, and exits only when the queue is **verified** empty, or (exit 1, logged) after 30 min of being unable to observe the session AND unable to read the queue. Startup reads (resolve the session, open the store) get 6 attempts (1+2+4+8+16 s).
3. `shouldKeepNudgePollerAlive`: an unreadable queue no longer counts as empty.

Unchanged on purpose: the screen detector. On the poller path it is not even consulted when `LastActivity` is known (3 s of silence decides), so the bead's proposed "deliver after a 120 s ceiling when the screen is unrecognised" is already how the queue path behaves once a poller is alive.

## Tests

`cmd/gc/cmd_nudge_poller_resilience_test.go`: 9 new tests plus 9 subtests, all pass. Each old behaviour was put back one at a time on the MBP:

| Mutant (old behaviour restored) | Killed by |
|---|---|
| M1 poller stdio back to `io.Discard` | `TestEnsureNudgePollerGivesThePollerRealFilesNotParentOwnedPipes`, `…FallsBackToNullDeviceWhenLogCannotBeOpened` |
| M2 a failed observation ends the poller | `TestDecideNudgePollRound` (4 subtests), `TestRunNudgePollLoop…` |
| M3 unreadable queue = empty in `shouldKeepNudgePollerAlive` | `TestShouldKeepNudgePollerAliveKeepsRunningWhenQueueUnreadable` |
| M4 unreadable queue = empty in the observe-error branch | `TestDecideNudgePollRound` (2 subtests) |
| M5 no backoff | `TestNudgePollErrorBackoff`, `TestRunNudgePollLoopSurvivesTransientObserveErrorsAndStillDelivers` |
| M6 startup read not retried | `TestRetryNudgePollStartup` |
| M7 give-up ceiling never fires | `TestDecideNudgePollRound` (ceiling subtest) |

## What it does NOT fix

- **No re-arm.** Any other way a poller dies (OOM kill, reboot, `kill`) still strands the queue until the next enqueue. Wants a detector ("PENDING nudge older than N min, session live, no poller").
- Pollers already running keep their pipes until they exit; they are fixed as they respawn.
- `oracle-wa` showed 5 PENDING: all fenced to older session ids (`ga-fbtmlbs`, `ga-wzmd9ll`, not the live `ga-pmc6wln`), attempts null. They are never claimed by the live session and sit until their 24 h TTL. A separate question (should a fenced item move to the successor session?).
- `.gc/nudges/pollers/` holds 32,453 files (17,098 `.lock`, 14,985 `.pid`, 370 `.log`), never pruned.
- Only one pane was examined for H1. Whether the 120-line busy scan (`paneContainsBusyIndicator`, spinner regex) can false-positive on other panes is untested.
- Aside for the Mayor: `ga-j96y0n-nudge-dead-ttl.patch` no longer applies to this base because it is already in it (4 marker lines in `8f1be0e2b`); it was never renamed `.APLICADO-…`.

## Until the window

`gc session nudge <session> --delivery immediate "…"` bypasses the queue. To drain a stranded queue, run the poller yourself with stderr on a **file** (tested in the foreground for 25 s, then killed):
`gc nudge poll --city "$GC_CITY_PATH" --session <tmux session name> <agent> 2>/path/to/log`

## Apply / verify

```bash
git -C <engine-src> apply --check "$GC_CITY_PATH/docs/pending-engine-window/ga-55jx16q-nudge-poller-sigpipe.patch"   # clean on 8f1be0e2b
"$GC_CITY_PATH/scripts/mbp-run.sh" --exec --go --push go.mod --push go.sum --push internal --push cmd --push third_party \
  --push examples --push test --push schemas --push schemas_embed.go --push docs \
  -- sh -c 'cd in && go vet ./cmd/gc/ && go test ./cmd/gc -run "Nudge|Poll" -count=1'
```

After the swap (the CLI picks it up at once; the supervisor at the nightly reboot), on an idle crew:
1. `gc session nudge <crew> --delivery queue "ping"`, wait 10 s: `ps -axo pid,command | grep 'nudge poll'` shows that session's poller, `lsof -a -p <pid> -d 1,2` shows `REG …/nudges/pollers/<stem>.log` (before the patch: `PIPE`), and `gc nudge status <crew>` shows PENDING 0.
2. `<stem>.log` exists and has no `broken pipe`.

The repro harness builds its own pipes, so it keeps showing the old death after the patch; it documents the cause, it is not the post-patch check.
