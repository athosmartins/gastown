# ga-4ytmas — a process snapshot that cannot be read is UNKNOWN, not "runtime-missing"

Patch: `ga-4ytmas-proc-snapshot-unknown.patch` (3 files, all under `internal/runtime/tmux/`).
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it.
The engine window stays Mayor-coordinated.

## The incident (10/10, oracle-wa, ~14:06–14:40)

`supervisor.log`: `tmux state cache: refresh failed in 3.0s: fetching Darwin process ...
snapshot: signal: killed` about every 3 s (213 lines on 10/10, 2261 in the log). Under
load (load average 50-70) the Darwin `ps` calls did not finish inside the fixed 3 s
`fetchTimeout` and were killed.

At `4f4837703` (live binary `gc-1.1.1-engwin0919`) one failed `ps` made `FetchState` fail
for the WHOLE snapshot, even though `tmux list-panes` had answered. `refresh()` kept the
last-known-good state for `defaultStaleTTL` (30 s), then published an EMPTY snapshot, so
`IsRunning` / `ProcessAlive` read false for every session => `runtime-missing` / orphan
for sessions that were alive. "Error" was read as "empty".

## What the patch does

* `FetchState` no longer fails when only the process table is unreadable: it returns the
  `list-panes` sessions with `ProcessesUnknown=true` (pane liveness is still proven by
  tmux itself). A failing `ps` is not respawned every refresh: 5 s, 10 s, 20 s ... capped
  at 2 min backoff, logged as `process snapshot unavailable (...); serving pane liveness
  only, retrying in <d>`.
* `processAlive` answers "alive" when the process table was not read and no pane matched
  (unknown is not dead).
* The fetch budget is adaptive: 3 s, 6 s, 12 s, 20 s (cap) while refreshes keep failing or
  keep coming back degraded; it halves after each full success.
* `Uncertain()` is now true whenever the last refresh failed and the last-known-good is
  older than `staleTTL` (it used to cover only "never succeeded"). Callers that already
  back off on `LivenessUncertain` (`sessionLivenessUncertain`, `cmd/gc`) now back off in
  exactly the window where the old code published an empty snapshot.

## Tests (`state_cache_unknown_test.go`, 12 tests; fake `ps` that `kill -9`s itself)

On the unpatched base 5 of the first 6 FAIL by assertion
(`first read: agent-1 is in tmux list-panes but IsRunning=false because ps was killed`,
`FetchState #1 returned an error although tmux list-panes succeeded`,
`fetch budget did not grow under repeated failure: first=2.99s fourth=2.99s`,
`Uncertain=false although last-known-good aged out ...`). All pass with the patch.

```
git apply --check  ga-4ytmas-proc-snapshot-unknown.patch        # clean on 4f4837703,
                                                                 # consolidated/engine-window-20260919, -20260926,
                                                                 # -20261011, -20261011-cp, and the stack HEAD c0d0f9b14
cd internal/runtime/tmux && go vet  $(ls *.go | grep -v -e '^interaction_test.go$' -e '_windows.go$')
cd internal/runtime/tmux && go test -count=1 -run 'StateCache|FetchTimeout|ProcessRetry|ProcessSnapshot|ProcessAlive' \
                              $(ls *.go | grep -v -e '^interaction_test.go$' -e '_windows.go$')
```

## Known test-suite noise (all verified, none caused by the patch)

* `TestGetKeyBinding_*`, `TestIsGTBinding_DetectsGasTownBindings`,
  `TestSetBindings_PreserveFallbackOnRepeatedCalls` fail identically on the unpatched base
  (tmux key-binding environment).
* `TestHasDescendantWithNames` can hit the 8 min test timeout when real `ps` is slow under
  load.
* `TestDoStartSession_TreatsDeadlineAfterReadyAsSuccessWhenSessionAlive` is a 1 ms
  context-deadline race that flakes under load; that path does not touch the state cache.
* `TestProviderObserveLivenessKeepsZombieShellVisible` (real tmux + real `ps`) can see
  `Alive=true` when the real `ps` is killed under heavy load: that is the intended new
  behaviour (process table unreadable => unknown => not reported dead). It passes whenever
  `ps` answers.

## After the window

Recurrence check: `/usr/bin/grep -c 'refresh failed' ~/.gc/supervisor.log` should stop
growing during load spikes, `process snapshot unavailable` lines may appear instead (that is
the degraded-but-honest mode), and no `runtime-missing` for a session whose tmux pane is up.
