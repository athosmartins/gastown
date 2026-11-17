## Contents

- What it fixes
- Design
- Apply order and base
- Tests (A/B on the MBP)
- After the window: acceptance check
- Not covered / follow-ups

## What it fixes

Bead ga-ica007 (found while fixing ga-lxm9se). The dog's Step 1a/1b/1c texts are
`sh -c` strings rendered by the engine (`internal/config/config.go`). Every
stage is `bd ... --json 2>/dev/null | jq ... 2>/dev/null`, so a `bd` that fails
or an answer `jq` refuses (ONE raw 0x08 byte inside a string makes jq 1.8
reject the whole document) comes out as `[]`, exit 0, nothing on stderr: "could
not read" and "queue is empty" are the same answer, and a worker that reads
`[]` as "no work" drains while a bead waits.

The city already versions the same probes as scripts that keep the three states
apart (answer / `[]` / could not read = `[]` + a line on stderr + exit 3):
`packs/town-deltas/assets/scripts/pool-probe-assigned.sh <1a|1b>` and
`pool-probe.sh <target>`. This patch makes the rendered text call them.

## Design

- `cityAssignedProbeDelegationScript(step)` prefixes the assigned-in-progress
  (1a) and assigned-ready (1b) queries; `cityPoolProbeDelegationScript()`
  prefixes the routed-pool query (1c, `$1` = target); `cityWorkQueryDelegationScript()`
  prefixes the full work query (1a, then 1b, then 1c, first answer wins).
- Each prefix looks the scripts up the way `wo_pick` looks up `work-order.sh`:
  `$GC_CITY_PATH`, else `$GC_CITY`, plus `packs/town-deltas/assets/scripts`.
  When both are readable it `exec`s the script, so stdout, stderr and the exit
  status pass through untouched. When they are not (no city, older checkout) it
  falls through to the OLD text, so the engine keeps working on any tree.
- Full query: a tier that could not be read is remembered, not forgotten. If no
  later tier finds a bead, the query ends with the script's non-zero status
  (stdout `[]`), so the caller sees an error and not "no work". 1a/1b run only
  when a session identity exists, as in the old text. The origin gate is
  `poolDemandOriginGateScriptExiting`, the old gate with a chosen exit status.
- Three cases keep the old text (`workQueryCityDelegation`): the legacy
  control-dispatcher branch (two targets, the scripts take one);
  `includeEphemeralReady` (bd 1.0.5 ready semantics drops the ephemeral tier the
  scripts carry); and EVERY agent except the city-scope `dog`
  (`cityProbeDelegationAgent = "dog"`, `Dir == ""`).
- Why dog-only: `gc config show` has no agent with a custom `work_query`, so
  without the gate the delegation would reach every agent on the standard branch (crews, gate
  reviewers, polecats, wa/ps workers). `pool-probe.sh` carries the dog pool's own
  filters (gate focus mode, disk hold, delivered-awaiting-gate drop) and both
  scripts are selftested against the dog's texts only. Widening it is a
  follow-up, pool by pool, after a measure. `dog-remote` is NOT covered.

Files: `internal/config/config.go` (+100/-4), new
`internal/config/city_probe_delegation_test.go` (360 lines). No change in `cmd/gc`.

## Apply order and base

- Base: engine HEAD `672f6f735c` (engine window 2026-11-14). `git apply --cached
  --check` against a temp index of that tree: clean.
- `ga-9t9acg.7-work-order-pool-probe.patch` (same shell text) does NOT apply to
  that HEAD in either direction (`work_order_pick_test.go` already exists and
  the `config.go` hunk at line 3673 no longer matches), so it was not stacked
  here. Whoever runs the window should look at that patch first: if it is
  superseded, rename it; if it is still wanted, rebase it on top of this one.
- No build or swap was done. The window applies the patch, builds, swaps, and
  restarts.

## Tests (A/B on the MBP)

Run on the MBP (go1.26.5), 17/11, via `mbp-run.sh --exec --go`:

- `gofmt -l internal/config`: empty. `go vet ./internal/config/`: clean.
- Full `./internal/config/` with patch (`engdocs/` pushed): ok, 168 s.
- With patch, `-run CityProbeDelegation`: ok, 29 PASS lines (subtests included).
  `TestCityProbeDelegation_OnlyTheDogDelegates` pins that wa-worker, ps-worker,
  claude, gate-reviewer, dog-remote, mayor, rig-scoped polecat/refinery and a
  rig-scoped "dog" keep the old text.
- A/B, `config.go` reverted to HEAD and the new test kept: 22 FAIL lines
  (assigned 1a/1b, pool 1c, full query, bd 1.0.5, only-the-dog), so the tests
  catch the bug.
- `./internal/graphroute/`: ok. `./cmd/gc/ -run 'WorkQuery|Prime|Hook|Convoy|Dispatch|TemplateResolve|BuildDesiredState|Pool'`: ok.

## After the window: acceptance check

Render a dog's prompt (or call `a.EffectiveWorkQuery`) and confirm the three
steps start with the `ga_root=` lookup. Then inject a bead description with a
raw 0x08 byte in a scratch DB and run each step from a dog session: the answer
must be `[]` plus `pool-probe…: could not read` on stderr and a non-zero exit
for 1a, 1b and 1c, never a silent `[]`.

## Not covered / follow-ups

- Every other agent (`dog-remote`, wa-worker, ps-worker, crews, reviewers,
  polecats...) still renders the old `2>/dev/null` text and keeps the blind
  spot. Each pool needs its own script or a measured widening of the gate.
- Delegation depends on the city scripts being readable at run time. A city
  without them runs the old text, with the old blind spot.
