# ga-9t9acg.7: the dog pool probe and the assigned-work queries pick by the Ordem unica

Patch: `docs/pending-engine-window/ga-9t9acg.7-work-order-pool-probe.patch` (parent programme `ga-9t9acg`).
Author: dog `gastown.dog-6`, 2026-10-07; gate-fix rounds 1 and 2 by `gastown.dog-3`, 2026-10-07/08. **Not built, not installed, not swapped** (bead rule: patch-only); `go vet` and the targeted `go test` were run in a scratch worktree of the base (see "What was verified").

## What it changes

`internal/config/config.go` (module `github.com/gastownhall/gascity`): the routed pool probe (tier 1, tier 2 migration,
tier 3 ephemeral) and the four assigned-work leaf queries (in_progress / ready, durable / ephemeral) hand their survivors
to `packs/town-deltas/assets/scripts/work-order.sh` (`ga-9t9acg.1`, gate:passed) through a shell function `wo_pick`,
which runs `work_order_sort --age reclaim`: **priority > type (feature first) > age**, where the `reclaim` age is
`created_at`, except `updated_at` for a bead carrying `pilot:reclaim-count:N` (N>=1). What that keeps and what it
changes is in the Decision table (row "Age = `reclaim`"): read it before the swap.

Before: tier 1 was `sort_by(.updated_at // .created_at)` over a 20-bead window; tier 2/3 and the assigned queries took
bd's own order over `--limit=20`. A P0 feature newer than a P0 bug lost to the bug; a P0 feature that was the 25th bead
was never seen.

| Decision | Why |
|---|---|
| `--limit 0` on every fetch, never `--limit=N` before ordering | filter-then-slice (ga-g7yt): bd treats 0 as unlimited. The molecule-live-step `bd list --parent … --limit 1` is an existence check, not an ordering query, and stays. |
| The lib runs in a child `bash -c '. "$1" && work_order_sort --age reclaim' wo "$lib"`, never sourced into the query's `sh` | Reproduced: a POSIX-mode `sh` EXITS when `.` cannot open its file (the query would die, empty output), and dash dies with `Bad substitution` on the lib's bash-only error paths. |
| The lib's answer is used only when `work_order_sort` exited 0 AND its stdout is exactly ONE JSON document, an array, as long as the input (`workOrderPickTrustsLib`: `[ "$wo_rc" -eq 0 ] && jq -es --argjson n "$wo_n" 'length == 1 and (.[0] \| type == "array" and length == $n)'`). Anything else (lib absent / unreadable / exit ≠ 0 / any other stdout) is "cannot tell": `work-order WARN: wo_pick: …` on stderr, then the SAME survivors through the PREVIOUS order (LRU for tier 1, bd's for the rest) | The check is on what the NEXT stage acts on (`jq '.[0:1]'` takes the head of an array), not on "stdout is non-empty". Gate-fix 2: a non-empty stdout that is not the array (a banner `echo`ed while `work-order.sh` is sourced, a `BASH_ENV` file that prints, non-JSON before `exit 2`, a valid-JSON banner, two documents, an empty or shorter array) used to be trusted and `jq` turned it into `[]`: "no work" while beads exist. Now whatever the lib prints or returns, it cannot turn a non-empty JSON input into an empty answer. (Residual, pre-existing: if the INPUT is not JSON, bd printing garbage, the fallback prints nothing, as the query did before; the WARN is still written.) The lib's own stderr is never sent to `/dev/null`. |
| Lib lookup: `$WORK_ORDER_LIB`, else `$GC_CITY_PATH`, else `$GC_CITY` (+ `packs/town-deltas/assets/scripts/work-order.sh`); first one set wins, no cascade | Dog sessions export `GC_CITY_PATH` and `GC_CITY` (checked in this session's env). |
| `poolDemandLabelFilterJQ`, `assignedTierExclusionFilterJQ`, `moleculeLiveStepFilterShell` unchanged | The vetoes do not move; only the order after them does. |
| Control-dispatcher `emit_ready` (`cmd/gc/dispatch_runtime.go`, `--limit=%d`) NOT touched | Out of scope: it is not the dog probe. `cmd/gc/cmd_convoy_dispatch_test.go` still pins `--limit=20` for it, correctly. The registry has no row for it (0 matches for `emit_ready` / `dispatch_runtime`), so the lint will not remind anyone: the same window-before-order class stays there until someone files it. |
| Age = `reclaim` (`created_at`; `updated_at` only with `pilot:reclaim-count:N`, N>=1) | It is the age the bead asked for (R7, R8). Three consequences, each checked against `work-order.sh` and `scripts/inflight-reclaim-guard.py`: **(a)** the ga-w4k2z LRU (a bead that keeps being reclaimed does not re-take the head) now holds only for beads that carry `pilot:reclaim-count`; **(b)** `updated_at` alone no longer demotes a bead, where the old tier 1 demoted any bead whose `updated_at` had moved. That is what avoids the ga-oc6knj regression (a bead the Pilot had just dispatched had its `updated_at` bumped and went to the back); **(c)** `pilot:starvation-count` is NOT read: `do_reclaim` stamps it INSTEAD of `pilot:reclaim-count` for a bead no worker ever claimed (audit-only, nothing reads it), so such a bead keeps its place on `created_at`. Live at 2026-10-07T08:29Z (`bd ready --unassigned --limit 0`, read-only): 19 ready beads routed to `gastown.dog`, 2 with `reclaim-count`, 1 with `starvation-count`; city-wide 366 / 2 / 4. Not established as harmful (a starved bead near the head may even be right); it is a decision, pinned by the test row "starvation-count alone is not a reclaim". The retained `...RoutedQueueFallbackSkipsRecentlyReclaimedHead` pins only the FALLBACK order, and says so in its env. |
| Order is applied per tier / per store, not over their union | The first tier that yields a bead wins: a P2 in tier 1 beats a P0 feature in tier 2 or 3, and a durable assigned bead beats an ephemeral one. `work-order.sh`'s header says to UNION the stores before ordering. This patch keeps the engine's tier structure and orders inside each tier. Not changed here: a follow-up if the rule must hold across tiers. |
| The fallback WARN is on stderr, and the engine's hook runner drops stderr on success | `shellWorkQueryWithEnv` (`cmd/gc/cmd_hook.go`, read at the base) keeps stderr in a buffer that is surfaced only when the command exits non-zero. A dog session that runs the printed command in Bash sees the WARN; on the `gc hook` / serve / wake paths an unreadable lib reverts to the previous order with NO trace. This patch does not change that. "After the swap" check 2 covers the dog's Step 1c; a durable counter, or a watchdog check that the lib path the engine derives is readable AND answers, is the follow-up bead `ga-9t9acg.15` (do it before the swap). |
| The lib is executed from the shared working tree (`$GC_CITY_PATH/packs/town-deltas/assets/scripts/`) | An uncommitted edit by another agent changes dispatch order with no integrity check (a broken edit at least trips the WARN and the fallback). Same exposure as every script the city runs from that tree. |

Files in the patch: `internal/config/config.go`, `internal/config/config_test.go` (every `--limit=20` string pin and
fake-bd case pattern became `--limit 0`; a comment on `…UsesOldestBeforePriority`, whose name predates this patch;
`runShellWithFakeBd` now points `WORK_ORDER_LIB` at a file that does not exist unless the test names its own lib, so
every test that goes through it pins the FALLBACK order on purpose and not by the accident of an empty env; and
`…SkipsRecentlyReclaimedHead` became `…FallbackSkipsRecentlyReclaimedHead`, with that stated in its name, comment and env),
`cmd/gc/cmd_hook_test.go` (four `--limit 0` pins), and the NEW `internal/config/work_order_pick_test.go`.
No other engine test executes the work query: `cmd/gc/cmd_convoy_dispatch_test.go` hands it to `runWorkflowServeFollow`
with `workflowServeList` stubbed, and the three `poolDemandLabelFilterJQ` tests run only the jq filter.

## What was verified, and what was not

Run (scratch worktrees of `consolidated/engine-window-20260926` @ `ae3833456`):

- `git apply --check` of the final patch file on a pristine 0926 tree: **rc=0**; a real apply is byte-identical (`cmp`) to the author tree.
- `gofmt -l` on the four files: clean.
- Generated shell run through a fake `bd` on fixtures, old baseline vs patched, under `sh` **and** `/bin/dash`:
  `harness/out-sh.txt` and `harness/out-dash.txt` (44 checks each, 0 FAIL, `ALL PASS`). Covered: P0 feature (newer) vs P0
  bug (older); 25 beads with the only P0 feature 25th; reclaimed x2; lib absent; the lib failing or answering with
  something the next stage cannot act on, in 13 ways (cannot-tell exit 2, syntax error, exit at source, empty lib, no
  function, banner printed while sourced, non-JSON + exit 2, a JSON banner + the array, two arrays, an empty array, a
  shorter array, the right array + exit 1, unreadable), each against the routed tier-1 command (the Go table runs the same rows at all ten sites), plus a `BASH_ENV` banner
  against the REAL lib and a banner on the assigned-ready tier; idle poll `[]`; garbage from bd; all three tiers and
  all four assigned queries; the full default `work_query`. Check 7 (`bd` prints garbage) pins a PRE-EXISTING
  error==empty collapse at the unchanged `bd ... 2>/dev/null | jq ... 2>/dev/null` stages: same answer as before, on
  purpose; this patch did not introduce it and does not fix it.
- `harness/mutants-sh.txt`: 9 mutants of the patched command (`run.py` with `MUTATE=<name>`: age = created_at only,
  window of 20, no sort, the lib sourced into `sh`, no fallback, WARN swallowed, and the three gate-fix-2 ones: trust
  any non-empty stdout, ignore the lib's exit status, ignore the length), each makes at least 1 check FAIL
  (1, 4, 24, 18, 17, 1, 9, 1, 2 of 44). So every new row can fail.
- A Python mirror of `work_order_pick_test.go`'s tables (`gotest_sim.py`): **OLD code 28/204 checks pass, NEW 230/230**
  (`sim-sh.txt`, `sim-dash.txt`), with a mutation control of 9 mutants (window of 20 before ordering, no ordering, age =
  created_at only, age = updated_at only, WARN swallowed, and the four gate-fix-2 ones: lib trusted on non-empty stdout,
  exit status ignored, length not compared, more than one document accepted).
- Same simulator against the REAL `work-order.sh` (`sim-real-lib.txt`): NEW 227/230. The 3 misses are the
  "age = updated_at only" mutant. The stand-in lib defines `--age field` as `updated_at`; the REAL lib's `field` reads a
  caller-injected `_wo_age` (see its header), so under that mutant every bead is age-unreadable and the head falls to the
  id tiebreak, which happens to match the expected head in those scenarios. So only the stand-in run proves that mutation
  control; the Go test mutates the stand-in lib only, so this does not affect the engine.
- The lib's own selftest (`bash packs/town-deltas/assets/scripts/work-order.selftest.sh`, city root, TMPDIR in scratch):
  `RESULT: PASS (342 passed, 0 skipped)`, exit 0 (`harness/selftest.out`). It tests the lib, not this patch.

**Go, run by gate-fix round 2** (in the scratch worktree of the base with the final patch applied; the run is real, the
build products were not installed):

- `go vet ./cmd/gc ./internal/config`: rc=0.
- `go test ./internal/config -count=1 -timeout 45m -v -run 'WorkOrder|EffectiveWorkQuery|EffectiveAssigned|PoolDemand|RoutedPoolWorkQuery'`:
  `ok`, 66 top-level tests and 314 subtests PASS, 0 FAIL (1151 s: the machine was saturated; `TestWorkOrderPickFallsBackWhenLibErrors`
  alone took 502 s for its 12 rows x 10 sites). The first attempt died on Go's default `-timeout 10m` ("test timed out"), not on a
  failure: 60 top-level and 115 subtests had passed by then.
- `go test ./cmd/gc -run CmdHook`: `ok`.
- RED on the pre-fix code (round-1 `wo_pick`, which trusts any non-empty stdout; same tree, 393 s): `TestWorkOrderPickFallsBackWhenLibErrors`
  FAILs for six of the new rows (two arrays, right array + exit 1, non-JSON + exit 2, non-JSON + exit 0, empty array, a banner that is
  valid JSON), at every site the log captured (the capture was cut at 80 lines, so the banner-while-sourced and `BASH_ENV` rows are
  not shown failing there; the shell harness mutant `trust-nonempty` in `mutants-sh.txt` makes 9 checks FAIL, those rows among them).
- `TestWorkOrderPickMutationControl` now also mutates the trust check four ways (round-1 non-empty check, exit status
  ignored, length not compared, more than one document accepted); each mutant makes its control fail.
- Free disk was 6.4-9.4 GiB during these runs, under the 8 GB guard for part of them; the go-build cache (~1.2 GB) is shared and was not cleared.

Still **not** done, by the bead rule (patch-only): `go build` of the `gc` binary, install, swap, bounce, supervisor kickstart.
The shell strings are also validated by extracting the new raw literals from `config.go` (`gen.py`) and running them, and
`gotest_sim.py` mirrors the Go test tables by hand; those two are independent of the Go run above, which executes the Go that
renders the strings. Treat a failure in the pre-swap commands below as a defect of this patch and hand the bead back.

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

- `packs/town-deltas/assets/scripts/work-order.registry.tsv`: delete the two `ext` rows for
  `engine:internal/config/config.go` whose owner is `ga-9t9acg.7` (R7 and R8) in the commit that records the swap, not
  before: until then the live engine still has those idioms. **Select them by content, never by line number**: the row
  numbers move with every merge that touches the registry (they had already moved by one between this patch's first
  draft and the branch the gate reviewed, and a `sed '57,58d'` on the old numbers deletes R8 and ANOTHER slice's R12 row).

  ```sh
  R=packs/town-deltas/assets/scripts/work-order.registry.tsv
  awk -F'\t' '$1=="ext" && $2=="engine:internal/config/config.go" && $4=="ga-9t9acg.7"' "$R" | cut -c1-90   # exactly 2 rows: R7, R8
  awk -F'\t' '!($1=="ext" && $2=="engine:internal/config/config.go" && $4=="ga-9t9acg.7")' "$R" > "$R.new" && mv "$R.new" "$R"
  git diff -- "$R"      # read it: only those two lines removed; the R12 / R12b rows (painel_visibilidade.py) stay
  ```

  Checked against the registry at the reviewed branch: the first command prints 2 rows; the second leaves 94 of 96
  rows and both `painel_visibilidade.py` rows.
- **Watchdog coupling (the registry's `consumer` row for `scripts/pool-autoscale-watchdog.py`, owner UNASSIGNED).**
  `_ready_candidates` there mirrors the engine's 20-bead probe window (the constant `PROBE_CANDIDATE_LIMIT = 20` and the
  `"--sort", "oldest", f"--limit={PROBE_CANDIDATE_LIMIT}"` call) and emits `[PROBE-WINDOW-FULL]`. After the swap the engine
  sees the whole population and orders it by the rule, so the watchdog's window both misjudges "nothing claimable" and
  mis-orders. It must change together with this patch (that registry row says so): drop the window, order by
  `work_order_sort`, remove the `PROBE-WINDOW-FULL` signal.
  Doing it BEFORE the swap would desynchronise it from the live engine, so it was not touched here. No bead tracks it
  yet; it is reported on `ga-9t9acg.7` for the Mayor to assign.

## Costs

The lib call is a child `bash` + `jq`: about 41-80 ms against 6-9 ms for the old `jq` per 25 beads, paid only when a
tier has survivors (an idle poll prints `[]` without calling the lib).

The whole-population fetch also removes the 20-bead cap that bounded `moleculeLiveStepFilterShell`'s sequential
`bd list --parent <molecule_id> --limit 1` probes (one per candidate that carries a `molecule_id`). Measured
2026-10-07T08:29Z, read-only: 19 ready beads routed to `gastown.dog`, 0 carrying a `molecule_id` (366 / 0 city-wide), so no
probe runs today. The engine bounds the whole work query by `hookWorkQueryTimeout = 30 * time.Second` (`cmd/gc/cmd_hook.go`,
read at the base); the gate review reported ~0.7-1.3 s per probe (not re-measured here), i.e. a timeout, a visible and
transient error, once tens of candidates carry a `molecule_id`. Re-measure with a real session after the swap.

## Re-running the harness

`ga-9t9acg.7-work-order-pool-probe.harness/` holds `gen.py` (builds old and patched commands; the patched fragments are
read out of `config.go`), `run.py` (13 sections against a fake `bd`, 44 checks; `MUTATE=<name>` applies one mutation, recorded in `mutants-sh.txt`), `gotest_sim.py` (the Go test's shell logic), the
baseline (`baseline-dog-commands-engwin0919.txt`: the three `sh -c` lines of Steps 1a / 1b / 1c exactly as the live 0919
binary printed them with `gc prime gastown.dog`; `gen.py` picks them by shape, not by line number), and the recorded
outputs (`out-*.txt`, `sim-*.txt`, `mutants-sh.txt`, `selftest.out`). They need only python3, jq and bash/dash; they do not build anything.

```sh
export PYTHONDONTWRITEBYTECODE=1                # keeps a __pycache__ out of the harness folder
H=docs/pending-engine-window/ga-9t9acg.7-work-order-pool-probe.harness
G=<patched internal/config/config.go>   T=<patched internal/config/work_order_pick_test.go>
python3 -I $H/run.py $H/baseline-dog-commands-engwin0919.txt $G "$GC_CITY_PATH" sh          # or /bin/dash
python3 -I $H/gotest_sim.py $H/baseline-dog-commands-engwin0919.txt $G $T sh
GC_WORK_ORDER_LIB_REAL=$GC_CITY_PATH/packs/town-deltas/assets/scripts/work-order.sh \
  python3 -I $H/gotest_sim.py $H/baseline-dog-commands-engwin0919.txt $G $T sh              # real lib: 227/230, see above
```

The baseline is the 0919 print; 0926 differs only in the label-filter jq, which this patch does not touch.
