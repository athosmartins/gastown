# ga-9t9acg.7: the dog pool probe and the assigned-work queries pick by the Ordem unica

Patch: `docs/pending-engine-window/ga-9t9acg.7-work-order-pool-probe.patch` (parent programme `ga-9t9acg`).
Author: dog `gastown.dog-6`, 2026-10-07. **Not compiled, not swapped** (bead rule: patch-only, no `go build`).

## What it changes

`internal/config/config.go` (module `github.com/gastownhall/gascity`): the routed pool probe (tier 1, tier 2 migration,
tier 3 ephemeral) and the four assigned-work leaf queries (in_progress / ready, durable / ephemeral) hand their survivors
to `packs/town-deltas/assets/scripts/work-order.sh` (`ga-9t9acg.1`, gate:passed) through a shell function `wo_pick`,
which runs `work_order_sort --age reclaim`: **priority > type (feature first) > age**, with the reclaim anti-starvation
clock (`updated_at` only for a bead carrying `pilot:reclaim-count:N`, N>=1).

Before: tier 1 was `sort_by(.updated_at // .created_at)` over a 20-bead window; tier 2/3 and the assigned queries took
bd's own order over `--limit=20`. A P0 feature newer than a P0 bug lost to the bug; a P0 feature that was the 25th bead
was never seen.

| Decision | Why |
|---|---|
| `--limit 0` on every fetch, never `--limit=N` before ordering | filter-then-slice (ga-g7yt): bd treats 0 as unlimited. The molecule-live-step `bd list --parent … --limit 1` is an existence check, not an ordering query, and stays. |
| The lib runs in a child `bash -c '. "$1" && work_order_sort --age reclaim' wo "$lib"`, never sourced into the query's `sh` | Reproduced: a POSIX-mode `sh` EXITS when `.` cannot open its file (the query would die, empty output), and dash dies with `Bad substitution` on the lib's bash-only error paths. |
| Lib absent / unreadable / "cannot tell": `work-order WARN: wo_pick: …` on stderr, then the SAME survivors through the PREVIOUS order (LRU for tier 1, bd's for the rest) | Never empty output: empty means "no bead" to the dog. The lib's own stderr is never sent to `/dev/null`. |
| Lib lookup: `$WORK_ORDER_LIB`, else `$GC_CITY_PATH`, else `$GC_CITY` (+ `packs/town-deltas/assets/scripts/work-order.sh`); first one set wins, no cascade | Dog sessions export `GC_CITY_PATH` and `GC_CITY` (checked in this session's env). |
| `poolDemandLabelFilterJQ`, `assignedTierExclusionFilterJQ`, `moleculeLiveStepFilterShell` unchanged | The vetoes do not move; only the order after them does. |
| Control-dispatcher `emit_ready` (`cmd/gc/dispatch_runtime.go`, `--limit=%d`) NOT touched | Out of scope: it is not the dog probe. `cmd/gc/cmd_convoy_dispatch_test.go` still pins `--limit=20` for it, correctly. |

Files in the patch: `internal/config/config.go`, `internal/config/config_test.go` (every `--limit=20` string pin and
fake-bd case pattern became `--limit 0`; a comment on `…UsesOldestBeforePriority`, whose name predates this patch),
`cmd/gc/cmd_hook_test.go` (four `--limit 0` pins), and the NEW `internal/config/work_order_pick_test.go`.

## What was verified, and what was not

Run (scratch worktrees of `consolidated/engine-window-20260926` @ `ae3833456`):

- `git apply --check` of the final patch file on a pristine 0926 tree: **rc=0**; a real apply is byte-identical (`cmp`) to the author tree.
- `gofmt -l` on the four files: clean.
- Generated shell run through a fake `bd` on fixtures, old baseline vs patched, under `sh` **and** `/bin/dash`:
  `harness/out-sh.txt` and `harness/out-dash.txt` (33 checks each, 0 FAIL, `ALL PASS`). Covered: P0 feature (newer) vs P0
  bug (older); 25 beads with the only P0 feature 25th; reclaimed x2; lib absent; lib erroring six ways (cannot-tell,
  syntax error, exit-at-source, empty lib, no function, unreadable); idle poll `[]`; garbage from bd; all three tiers and
  all four assigned queries; the full default `work_query`.
- A Python mirror of `work_order_pick_test.go`'s tables (`gotest_sim.py`): **OLD code 20/104 checks pass, NEW 118/118**
  (`sim-sh.txt`, `sim-dash.txt`), with a mutation control (mutants: window of 20 before ordering, no ordering, age = created_at only, age = updated_at only, WARN swallowed).
- Same simulator against the REAL `work-order.sh` (`sim-real-lib.txt`): NEW 115/118. The 3 misses are the
  "age = updated_at only" mutant, which the real lib's `--age field` semantics happens not to distinguish; the Go test
  mutates the stand-in lib only, so this does not affect the engine.
- The lib's own selftest (`bash packs/town-deltas/assets/scripts/work-order.selftest.sh`, city root, TMPDIR in scratch):
  `RESULT: PASS (342 passed, 0 skipped)`, exit 0 (`harness/selftest.out`). It tests the lib, not this patch.

**Not run:** `go build`, `go vet`, `go test`. The Go (including the new test file) is gofmt-clean but was **not
type-checked and the Go tests were not executed**. The shell strings were validated by extracting the new raw literals
from `config.go` (`gen.py`), not by running the Go that renders them; `gotest_sim.py` mirrors the Go test tables by
hand. Treat a failure in the pre-swap commands below as a defect of this patch and hand the bead back.

## Apply in the next engine window

Base the window on `consolidated/engine-window-20260926` or later (Mayor's 2026-09-21 ruling: the `consolidated/*`
lineage, NOT `origin/main`). Informational apply-checks of this exact file: 0926 rc=0; 0919 fails only in
`internal/config/config_test.go` near line 2089 (context that ga-473mkh / ga-ljoz23 introduced; both are already in
0926); stale `origin/main` @ `08d7ef788` fails in `config.go` and `config_test.go`. No overlap with the pending
`ga-wtzrho`, `ga-0y849e`, `ga-1g2if1` patches.

```sh
cd <engine worktree on the window branch>      # e.g. /Users/athos/gt/.local-patches/_src-hookfix (a worktree of it)
P=/Users/athos/gt/.gascity-gastown-hq/docs/pending-engine-window/ga-9t9acg.7-work-order-pool-probe.patch
git apply --check "$P" && git apply "$P"       # the leading `# …` header lines are ignored by git apply
git add internal/config/config.go internal/config/config_test.go internal/config/work_order_pick_test.go cmd/gc/cmd_hook_test.go
git diff --cached                              # read it (not --stat): 4 files
gofmt -l internal/config cmd/gc/cmd_hook_test.go
go vet ./cmd/gc ./internal/config
go test ./internal/config ./cmd/gc -run 'WorkOrder|EffectiveWorkQuery|EffectiveAssigned|PoolDemand|CmdHook'
```

The config tests run the shell with a hermetic env (PATH plus the test's own map), so `GC_CITY_PATH` / `WORK_ORDER_LIB`
come from the test, never from the host. When the window lands, rename the patch to
`ga-9t9acg.7-work-order-pool-probe.patch.APLICADO-<date>` like the others.

## `strings` dry-run on the NEW binary (before the swap)

Go stores string data without NULs, so `strings` prints very long lines: count OCCURRENCES with `grep -o`, not lines.

```sh
strings -a <new-gc> > new.strings
for p in '--limit=20' '--limit 0' 'wo_pick() {' 'work_order_sort --age reclaim' 'work-order WARN: wo_pick' \
         'WORK_ORDER_LIB' 'sort_by(.updated_at // .created_at // "")' '--sort oldest --limit=20' \
         '--sort oldest --limit 0' 'pilot:text-veto'; do
  printf '%-52s %s\n' "$p" "$(grep -o -F -e "$p" new.strings | wc -l | tr -d ' ')"
done
```

| Marker | live `gc-1.1.1-engwin0919` (measured) | NEW binary (predicted from the source, not measured) |
|---|---|---|
| `--limit=20` | 6 | **0** (the six `config.go` literals are gone; the control-dispatcher builds `--limit=%d` with Sprintf) |
| `--sort oldest --limit=20` | 1 | **0** |
| `--sort oldest --limit 0` | 0 | **>= 1** |
| `--limit 0` | 1 | more than 1 |
| `wo_pick() {` | 0 | **>= 1** |
| `work_order_sort --age reclaim` | 0 | **>= 1** |
| `work-order WARN: wo_pick` | 0 | **>= 1** |
| `WORK_ORDER_LIB` | 0 | **>= 1** |
| `sort_by(.updated_at // .created_at // "")` | 1 | **>= 1** (kept as the tier-1 fallback) |
| `pilot:text-veto` | 1 | **>= 1** (vetoes unchanged: must not drop) |

A `--limit=20` that survives, or a missing `wo_pick() {`, means the patch did not land in the binary. Do not swap.

## After the swap

1. In the 0919 print, `--limit=20` sits on exactly 7 lines of `gc prime gastown.dog` (lines 48, 124, 127, 130, 245, 246,
   249: the Step 1a / 1b / 1c commands, each printed twice, plus the numbered step 3). After the swap
   `gc prime gastown.dog | grep -c -e '--limit=20'` should print **0** and `grep -c 'wo_pick() {'` the same **7**
   (each command defines `wo_pick` once, ahead of its first use). The line count follows the prompt template, so
   compare against the pre-swap print rather than the literal 7 if the template changed.
2. From a dog session, run Step 1c (the routed pool command printed by `gc prime gastown.dog`) with real `bd`. It must
   print one JSON array of at most one bead; stderr must **not** show `work-order WARN: wo_pick: work-order.sh not
   readable`. That WARN means the probe is silently on the old order: check `GC_CITY_PATH` / `GC_CITY` /
   `WORK_ORDER_LIB` in the query's env.
3. `bash packs/town-deltas/assets/scripts/work-order.selftest.sh` from the city root (needs bash, jq, python3): exit 0.

## Same commit as the swap (repo changes this patch cannot carry)

- `packs/town-deltas/assets/scripts/work-order.registry.tsv`: delete the `ext` rows 57 and 58 (R7, R8, owner
  `ga-9t9acg.7`) in the commit that records the swap, not before: until then the live engine still has those idioms.
- **Watchdog coupling (registry row 55, UNASSIGNED).** `scripts/pool-autoscale-watchdog.py` `_ready_candidates`
  mirrors the engine's 20-bead probe window (`PROBE_CANDIDATE_LIMIT = 20`, `--sort oldest --limit=20` near line 378) and
  emits `[PROBE-WINDOW-FULL]` (near line 466). After the swap the engine sees the whole population and orders it by the
  rule, so the watchdog's window both misjudges "nothing claimable" and mis-orders. It must change together with this
  patch (row 55 says so): drop the window, order by `work_order_sort`, remove the `PROBE-WINDOW-FULL` signal.
  Doing it BEFORE the swap would desynchronise it from the live engine, so it was not touched here. No bead tracks it
  yet; it is reported on `ga-9t9acg.7` for the Mayor to assign.

## Costs

The lib call is a child `bash` + `jq`: about 41-80 ms against 6-9 ms for the old `jq` per 25 beads, paid only when a
tier has survivors (an idle poll prints `[]` without calling the lib).

## Re-running the harness

`ga-9t9acg.7-work-order-pool-probe.harness/` holds `gen.py` (builds old and patched commands; the patched fragments are
read out of `config.go`), `run.py` (13 scenarios against a fake `bd`), `gotest_sim.py` (the Go test's shell logic), the
baseline (`baseline-dog-commands-engwin0919.txt`: the three `sh -c` lines of Steps 1a / 1b / 1c exactly as the live 0919
binary printed them with `gc prime gastown.dog`; `gen.py` picks them by shape, not by line number), and the recorded
outputs (`out-*.txt`, `sim-*.txt`, `selftest.out`). They need only python3, jq and bash/dash; they do not build anything.

```sh
H=docs/pending-engine-window/ga-9t9acg.7-work-order-pool-probe.harness
G=<patched internal/config/config.go>   T=<patched internal/config/work_order_pick_test.go>
python3 -I $H/run.py $H/baseline-dog-commands-engwin0919.txt $G "$GC_CITY_PATH" sh          # or /bin/dash
python3 -I $H/gotest_sim.py $H/baseline-dog-commands-engwin0919.txt $G $T sh
GC_WORK_ORDER_LIB_REAL=$GC_CITY_PATH/packs/town-deltas/assets/scripts/work-order.sh \
  python3 -I $H/gotest_sim.py $H/baseline-dog-commands-engwin0919.txt $G $T sh              # real lib: 115/118, see above
```

The baseline is the 0919 print; 0926 differs only in the label-filter jq, which this patch does not touch.
