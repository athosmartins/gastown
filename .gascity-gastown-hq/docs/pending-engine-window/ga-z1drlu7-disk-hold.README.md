# ga-z1drlu7: the disk floor reaches the engine's default pool query (claude-headless leak)

## Contents

• What it changes · What was verified, and what was not · Apply in the next engine window
• After the swap · What this does NOT fix · Why the engine and not a config patch

Patch: `docs/pending-engine-window/ga-z1drlu7-disk-hold.patch` (bead `ga-z1drlu7`, P1; follow-up of `ga-vln2py`).
Author: dog `gastown.dog-1`, 2026-11-09. **Not built, not installed, not swapped** (patch-only, Mayor-coordinated window).
Go ran on the MBP (`mbp-run.sh --exec --go`), never on the mini.

## What it changes

Free disk under the new-work floor (5 GB, `disk-headroom-lib.sh`) must stop the pool from handing out, or counting as demand, a NEW STORY.
That was only true for `scripts/pool-probe.sh` (dog) and the Pilot. `<rig>/claude-headless` is not a city agent: the engine synthesizes it per
rig from `[providers.claude-headless]`, so it runs the engine's DEFAULT `work_query` and `scale_check`, which had no hold. Measured 09/11
(`ga-z1drlu7` comments): 3 sessions for `wa-sm96hz.2` between 12:35 and 15:14 with the mini at 1.3-4.7 GB free; only the agent's own restraint
(`bd defer`) stopped the damage, and the snooze expiry started the next session.

`internal/config/config.go` (module `github.com/gastownhall/gascity`):

| Change | Why |
|---|---|
| New `diskHoldFunctionScript()` defines the shell function `disk_hold` (stdin: JSON array, stdout: the array the pool may hand out) | One definition, used by both sides below |
| `routedReadyTierCommand` (tier 1 of the default `work_query`, and of `EffectiveRoutedPoolQuery`) pipes the survivors through `disk_hold` BEFORE `wo_pick` | The offer side: `gc hook` runs this query (and, by dog-remote-2's reading of the public engine source, not re-measured, so does the ~90 s nudge path) |
| `poolDemandCountShell` (default `scale_check`) runs the same `disk_hold` over `ready_json` | The demand side: without it the controller keeps starting sessions for a bead the query then refuses to hand out (a spawn loop, paid in tokens and session beads) |
| `poolDemandFirstRowFunctionScript` and `poolDemandCountShell` emit the function definition themselves | No new caller obligation: every script that uses the tier already has the function |

Three states, read from the lib in a CHILD bash (`. lib && disk_headroom_state`; same reasons as `wo_pick`: a POSIX sh exits when `.` cannot open its file):

| State | What `disk_hold` does |
|---|---|
| `ok` | passes the array through untouched |
| `low` | drops the NEW STORIES with `DISK_HOLD_NEW_STORIES_JQ`, read from the lib (the one definition, shared with `pool-probe.sh`): a story type with none of `gc.kind` / `gc.step_ref` / `gc.pool_demand`. Formula work and shapes the lib does not recognise still flow |
| anything else (lib unreadable, child failed, banner printed while sourced, df unreadable, `unknown`) | passes the array through untouched (FAIL OPEN, same decision as `pool-probe.sh`) with `disk-hold WARN` on stderr and a line in `.gc/logs/disk-hold.log` |
| `low` but the hold text is empty or jq cannot apply it | prints `[]` (INERT): offers nothing, counts nothing, WARN + log line. Never "go ahead", never a crash |

Not held, on purpose: assigned work (crash recovery, pre-assigned beads: it is not new work); tiers 2 and 3 of the pool probe (`gc.run_target`
migration rows are `gc.kind=workflow`; ephemeral wisps are the city's own formula work), exactly as in `pool-probe.sh`. A routed wisp with no
formula mark at all would flow there too; the measured dog shape (17/10, 1684 beads) has none.

The lib is found at `$DISK_HEADROOM_LIB`, else `$GC_CITY_PATH` (then `$GC_CITY`) + `packs/town-deltas/assets/scripts/disk-headroom-lib.sh`
(same lookup as `wo_pick`). Seams for tests: `DISK_FREE_OVERRIDE_MB`, `DISK_HOLD_LOG`. Kill switch: the lib's own `DISK_HEADROOM_ENABLED=0`.

Files: `internal/config/config.go`, NEW `internal/config/disk_hold_test.go`. No other file; no existing test changed.

## What was verified, and what was not

Run on the MBP (`mbp-run.sh --exec --go`), scratch worktree of `consolidated/engine-window-20261023` (the lineage of the live binary,
`gc-1.1.1-engwin1023`):

- `git apply --check` of the patch on a pristine 1023 tree (temp index): rc=0; `--reverse --check` on the author tree: rc=0.
  No overlap with the only truly pending `config.go` patch (`ga-ieo0wz1`): applies alone and after this one.
  (The other `.patch` files naming `config.go` are already in 1023; they fail `--check` alone on 1023 for that reason, before and after.)
- `gofmt -l`: clean. `go vet ./cmd/gc ./internal/config`: rc=0.
- `TestDiskHold*` (new): every state at the three sites (work query tier 1, routed pool query, count form) with 13 scenarios each:
  low holds a story and counts 0; low lets formula work through; ok / exactly-at-floor (5120) / kill switch offer and count it; unreadable
  reading, lib absent, banner while sourced, lib that exits: fail-open with WARN; low with an empty or non-jq hold text: `[]` with WARN;
  assigned work never held (4 sites) and the assigned-only queries do not even carry the stage; `disk_hold` defined once and before its use;
  the log is written when it acts and not when the disk is ok, an unwritable log dir does not change the answer.
- **RED on the pre-patch `config.go`** (same new test file): 39 FAIL (every low-disk, fail-open WARN, inert, defined-before-use, log and
  mutation row) and 18 PASS (rows whose answer does not change without the patch: ok, exactly at the floor, kill switch, formula work, assigned work).
  With the patch: all PASS.
- Mutation control (`TestDiskHoldMutationControl`): 5 mutants x 3 sites (low passes through, unknown fails closed, unusable hold falls through,
  hold drops formula work, stage removed); each is caught by the scenario that pins it, and the scenario passes on the real query.
- The generated function, extracted from `config.go` and run under `sh` AND `dash` against the REAL `disk-headroom-lib.sh`
  (`DISK_FREE_OVERRIDE_MB` = 2000, 5119, 5120, 9000, unreadable): 5119 holds, 5120 passes, unreadable passes with one WARN, identical in both shells.
- Regression (MBP, 1286 s wall, background priority): `go test ./internal/config -run 'DiskHold|WorkOrder|EffectiveWorkQuery|EffectiveAssigned|PoolDemand|RoutedPoolWorkQuery|ScaleCheck'`:
  `ok`, 82 top-level tests and 382 subtests PASS, 0 FAIL; `go test ./cmd/gc -run CmdHook`: `ok`. That run was on the tree before the last
  wording pass (comments, the log text and one extra log line in the inert arm); the final tree was re-run for
  `DiskHold|ScaleCheck|EffectiveWorkQuery`: `ok`, `TestDiskHold*` 71 PASS (15 of them the mutation control), 0 FAIL, vet clean.
- `TestEffectiveScaleCheckUsesReadyOnly` still holds: the count form carries no `2>/dev/null` (the function only uses `>&2` and `>> log`).

NOT done, by the rule: `go build` of `gc`, install, swap, bounce. NOT measured: the live binary's behavior with the patch (that is the "After
the swap" checklist), and a real `gc hook` of a claude-headless session on a low disk.

## Apply in the next engine window

Base: `consolidated/engine-window-20261023` or later.

```sh
cd <engine worktree on the window branch>
P=/Users/athos/gt/.gascity-gastown-hq/docs/pending-engine-window/ga-z1drlu7-disk-hold.patch
git apply --check "$P" && git apply "$P"
git add internal/config/config.go internal/config/disk_hold_test.go
git diff --cached                       # read it (not --stat): 2 files
gofmt -l internal/config
# Go on the MBP, not the mini (ga-edkfip):
"$GC_CITY_PATH/scripts/mbp-run.sh" --exec --go --push go.mod --push go.sum --push internal --push cmd --push third_party --push examples --push test --push schemas --push schemas_embed.go --push docs \
  -- sh -c 'cd in && go vet ./cmd/gc ./internal/config && go test ./internal/config -run "DiskHold|WorkOrder|EffectiveWorkQuery|PoolDemand|ScaleCheck"'
```

Optional: `GC_DISK_HEADROOM_LIB_REAL=<path to disk-headroom-lib.sh>` makes `TestDiskHoldAgainstTheRealLib` run the scenarios against the real lib.

## After the swap

1. `strings $(readlink -f $(which gc)) | grep -c 'disk_hold()'` >= 1 on the NEW binary BEFORE the swap.
2. After the swap, rerun the `DiskHold` tests on the swapped source tree (they drive the generated commands, not strings). The real effect
   shows in the log: with the mini under 5 GB, `.gc/logs/disk-hold.log` gets `hold applied: new stories held back` lines when a session of a
   rig `claude-headless` polls with a story routed to it, and that session is offered `[]`.
3. Watch `.gc/logs/disk-hold.log` for a day: `fail-open` lines mean the lib was unreadable by the engine (wrong `GC_CITY_PATH` in that
   session's env), which is the only way the hold silently does nothing.
4. Controller side: with the mini under 5 GB and a story routed to a claude-headless, no session is started for it (`gc session list`).

## What this does NOT fix

- Until the swap the leak stays open; the interim brake is the agent's own restraint (`bd defer`), as measured.
- A session that is ALREADY running keeps its work; the hold stops the next OFFER, not a live builder (same limit as `pool-probe.sh`).
- The `hold` ignores the fix class (`gate:needs-fix`, `impacto:dano-ao-vivo`) on a low disk, like the pool probe: the Mayor decides whether a fix runs.
- `scripts/pool-probe.sh` is not touched; it keeps its own log (`pool-probe.log`).

## Why the engine and not a config patch

`work_query` is not a field of `[[patches.agent]]` (only `scale_check` is), so a patch could close the demand side at best; and whether the
live binary applies a patch to an implicit (synthesized) agent was not established (`home-scan-guard-activate.sh` saw "not found in merged
config" in September). Replacing it by an explicit agent changes prompt/idle/sling semantics. The engine predicate is the one place both sides
(offer and demand) come from, which is the acceptance criterion as written.
