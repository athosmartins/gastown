## Contents

- What it fixes
- Who copies the labels (proof)
- Which file goes where
- The policy
- What was verified, and what was not
- How to land it
- The sweep tool (cleans what was already born wrong)

## What it fixes

`bd create --parent <p>` copies the parent's labels onto the new child. A slice of a closed parent was born
`gate:passed` / `story:done` and the Pilot skipped it as finished, in silence (wa-93uf5c.4/.5, wa-zmxywv.30.1,
wa-xmpoab.2.1, ga-2hd02v.3.x, ga-p7hymz.1); a slice of a parked parent was born parked. The fix makes the child
inherit only classification labels (area:*, lane:*, node:*, framework:*, origem:*, ...) and never the parent's
cycle/state labels (gate:*, gate-*, story:done/gate/in-flight/epic-split, delivery:*, pilot:*, exec:manual,
next-action:*, blocked*, ...). A label the caller names with `--labels` is never filtered.

## Who copies the labels (proof)

It is `bd` itself, not a janitor, hook or reconciler: `bd create --help` lists `--no-inherit-labels`
("Don't inherit labels from parent issue"), the store has no `.beads/hooks`, and the copy happens in four places
of the bd source (all fixed here): `cmd/bd/create.go` `mergeCreateLabels` (also used by `create --form`, `q` and
the `--dry-run` previews), `internal/storage/domain/issue.go` (`InheritedLabels`) and
`internal/storage/issueops/execution.go` `ExecuteCreate` (the proxied/API route).

**Why this kept happening although ga-2svou8 (07/10) already wrote a filter:** that patch was landed in the ENGINE
tree (`consolidated/engine-window-20261023`, linked into `gc`) but the `bd` binary agents actually run for
`bd create --parent` is built from a different repo (`/Users/athos/gt/beads`) and never got it. Measured 31/10:
`strings <gc> | grep -c IsInheritableLabel` = 2, `strings <bd> | grep -c IsInheritableLabel` = 0 (live `bd 1.1.0`,
source `861fd98b9`). Merged is not live.

## Which file goes where

| File | Base | Use |
|---|---|---|
| `ga-y5z6hzh-bd-create-parent-no-inherit-cycle-labels.bd-repo.diff` | bd source `861fd98b9` (live `bd 1.1.0`); also applies clean to `15101aa76` (1.3.0 candidate) and `403e27c6d` (bd `main`); paths relative to `/Users/athos/gt/beads` | rebuild the `bd` binary. THIS is the one that stops the bug |
| `ga-y5z6hzh-bd-create-parent-no-inherit-cycle-labels.patch` | `third_party/beads/` of `consolidated/engine-window-20261023` (live `gc-1.1.1-engwin1023`), INCREMENTAL on top of ga-2svou8 (extends its lists, adds tests; the call sites are already there) | engine window, so `gc`'s vendored copy matches |

Both pass `git apply --check` on the bases above (temporary index, no checkout). The `.patch` supersedes
`ga-2svou8-bd-create-parent-no-inherit-state-labels.patch`; do not apply both (ga-2svou8 is already in the engine tree).

## The policy

Single source: `internal/types/label_inherit.go` (`IsInheritableLabel`, `FilterInheritableLabels`), literal
case-sensitive prefixes, not substrings (`gates:review`, `mygate:x`, a bare `pilot` stay inherited).

- Never inherited, by prefix: `gate:` `gate-` `pilot:` `pool:` `lifecycle:` `delivery:` `next-action:` `blocked:`
  `blocked-` `audit:` `auto-refino:` `refino:` `impacto:`.
- Never inherited, exact: `exec:manual` `needs-human` `needs-human-decision` `ctx:thin` `scope:needs-review`.
- `story:` is blocked as a NAMESPACE; only `story:approved`, `story:unrefined`, `story:needs-refino`,
  `story:needs-device` are inherited. A story state added later is therefore not inherited until someone lists
  it (a child missing a label is a one-line fix; a child carrying a stale state label vanishes from the Pilot).
- Deliberately still inherited: `exec:auto`, `ctx:ready`, `story:approved` (arming labels the Mayor's slicing
  recipe relies on), `needs:*`, `waiting-on:*`, `followup:nonblocking`, `priority:pinned`, `on-device`,
  `phone-proxy`. Decide separately if `needs:engine-window` should stop propagating to slices.
- Consequence to know: `pilot:*` is no longer inherited, so a child of a HELD parent is born unheld. A hold on a
  slice must be set explicitly (the town already creates beads with `pilot:no-auto-dispatch`, which is not
  inheritance).

The label lists were taken from the live hq store (distinct labels by family) and the Pilot's pool-probe
exclusion list, not guessed. The sweep tool (slice 2) carries a copy of the same lists and its selftest compares them
with the Go file inside the `.bd-repo.diff`, so they cannot drift.

## What was verified, and what was not

- Verified: both diffs apply clean to the bases above; `gofmt -e -l` clean on every touched file; no identifier
  collision in package `types` / `cmd/bd`; the expected output of every new test was hand-traced against the policy.
- **NOT run: `go test` / `go vet`.** The MBP preflight refused (rc 98, `swap 8790..9022 MB >= 8192 MB`, stable for
  over 30 min while `Modo: LIVRE`) and the mini is below the 13 GB Go disk floor, so by doctrine nothing was run
  on the mini. Run, from the bd worktree (`/Users/athos/gt/.gc-worktrees/bd-ga-y5z6hzh`, diff staged, not
  committed):
  `"$GC_CITY_PATH/scripts/mbp-run.sh" --exec --go --push go.mod --push go.sum --push internal --push cmd --push issueops --push backend -- sh -c 'cd in && go test ./internal/types/ -run "InheritableLabel" -count=1 && go test ./cmd/bd/ -run "MergeCreateLabels" -count=1'`
  and, for the real create route, `BEADS_TEST_EMBEDDED_DOLT=1 go test ./backend/... -run CreateInheritsParentLabels`
  (needs the CGO env from the ga-vjlwso recipe; cold build is long). RED/GREEN to prove: make
  `IsInheritableLabel` return `true` (= the old copy-everything behaviour) and expect `TestIsInheritableLabel`,
  `TestMergeCreateLabelsDoesNotInheritCycleLabels` and the conformance contract to FAIL.
- The sweep tool (slice 2, bead ga-y5z6hzh.1, see its section) IS tested: its selftest runs its real SQL on a throwaway Dolt
  database (62 checks: strip rules, every report-only class, the 14-day/closed/parent-label exclusions, idempotency,
  `--max`, a label removed by someone else first, and every read failure landing inert) plus a mutant battery whose
  result is in the bead comment.
- Do NOT commit in `/Users/athos/gt/beads` on the mini until ga-opj0hnt lands: `.githooks/pre-commit` runs
  `go run golangci-lint@v2.10.1` (cold download + build); it took the mini from 7.3 to 5.0 GB free in four
  minutes on 31/10 (reclaimed with `go clean -modcache` + `safe-clean` of the go-build cache). The bd diff is
  therefore left STAGED, not committed, in the worktree `/Users/athos/gt/.gc-worktrees/bd-ga-y5z6hzh`.

## How to land it

1. Build/swap is the Mayor's window (no build or swap was done here). Apply the `.bd-repo.diff` to the bd source
   and build `bd`; apply the `.patch` to the engine tree for the next `gc` build.
2. Prove it is LIVE, on the artifact: `strings $(readlink -f $(which bd)) | grep -c IsInheritableLabel` must be
   >= 1; then create a throwaway child under a parent that carries `gate:passed` and confirm the child has no
   `gate:*`/`story:done`.
3. Until then, re-run the sweep below; it is idempotent.

## The sweep tool (cleans what was already born wrong)

`scripts/child-cycle-labels-sweep.py` (selftest `scripts/child-cycle-labels-sweep.selftest.sh`), shipped as slice 2
(bead ga-y5z6hzh.1) to keep each gate submission under the size cap; its selftest compares the policy lists with the
Go file inside the `.bd-repo.diff` of THIS slice, so it is submitted after this one merges. The one-time sweep itself
was already run on 31/10 (13 labels on 4 children, list and proof in the ga-y5z6hzh comments). Dry-run by
default. It strips ONLY labels that claim completion (gate:passed, story:done, gate-approved:*, delivery:tested,
...) from OPEN children created in the last `--days` (14) that: share the label with their parent, were born with
it (event log: added once within 10 s of creation, never removed) and were never seen by the gate (no
`source-bead:<child>` marker). Everything else it finds is only reported: removing a hold or park label
(`exec:manual`, `pilot:*`, `next-action:*`) releases work, which is not the inert direction.
A store it cannot read is reported UNREADABLE with exit 2; it is never read as "nothing to clean". Before each
removal it re-checks the label is still there (a bead can be cleaned by hand between the dry-run and `--apply`),
and after it re-reads the store to confirm; a `bd` write that exits 0 without persisting is reported FAILED.
Its reads are small indexed queries (the first draft joined `labels` four ways and timed out on the live hq store).

    python3 scripts/child-cycle-labels-sweep.py                # dry-run, every rig
    python3 scripts/child-cycle-labels-sweep.py --apply --max 25
