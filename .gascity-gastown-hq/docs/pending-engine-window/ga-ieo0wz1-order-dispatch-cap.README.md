# ga-ieo0wz1 — `[orders] max_dispatches_per_tick`: make the per-tick order dispatch cap configurable

## Contents

• State · Why (the measured root cause) · What the patch does
• Decisions worth challenging · Choosing the value (NOT decided here) · Tests and what they prove
• Applying in the window · Verifying after the window · Rolling back · What is NOT covered / NOT tested

Patch: `ga-ieo0wz1-order-dispatch-cap.patch` (7 files: 2 production edits, 3 generated-doc edits, 2 new test files). NOT applied.
No build, no `go test`, no `genschema`, no binary swap, no supervisor kickstart was done to produce it.
The engine window stays Mayor-coordinated. Base: `consolidated/engine-window-20261016` (`de525d882`, the live `engwin-1016`).
`git apply --check` is clean on that base, and the patch stacks in **both orders** with every pending patch that touches the same
files (`ga-2hd02v-hybrid-remote-exec`, `ga-473mkh-next-action-park-filter`, `ga-9t9acg.7-work-order-pool-probe`,
`ga-ljoz23-step1a-no-auto-dispatch`, `ga-voj3cw-sling-wrapper-live-filter`; checked on a scratch copy, not in a repo).

## Why (the measured root cause)

`jsonl-export` is a `cooldown` order with `interval = "15m"` and runs every ~73 min. Nothing is wrong with the order: the engine's
order dispatcher starts at most `defaultMaxOrderDispatchesPerTick = 4` orders per controller tick (`cmd/gc/order_dispatch.go`,
`spendDispatchBudget` + the rotating cursor `nextDispatchStart`; from upstream #2801, 2026-05-31), the constant is not
configurable, and this city runs `patrol_interval = "120s"` (`city.toml`; the code default is 30 s).
Measured on 24 h of `gc order history` (1675 dispatches, 0 unreadable lines):

* dispatches arrive in bursts of 4 (418 bursts, median size 4, max 5); median gap between bursts 168 s; throughput 1.16/min;
* 63 `cooldown` (order, rig) instances ask for 14.7 dispatches/min if punctual (21 instances with interval ≤ 5 min ask for 13.5;
  five 30 s instances — `gate-sweep` ×4 and `dolt-health` — ask for 10/min alone); capacity is ≤ 2/min nominal: saturation 7×–13×;
* consequence, for ALL orders and not just ours: the real median gap between two dispatches of the same instance is 2130 s
  (35.5 min; p90 4043 s) across the 44 always-due instances, whatever their configured interval (30 s … 30 min).

The cap is therefore the throttle, and the interval a `cooldown` order declares is only a lower bound that cannot be met.

## What the patch does

* `internal/config/config.go`: `OrdersConfig` gets `MaxDispatchesPerTick int` (`toml:"max_dispatches_per_tick,omitempty"`,
  `jsonschema:"default=4"`), documented in the field comment (which feeds the generated schema/docs).
* `cmd/gc/order_dispatch.go`: new `orderDispatchBudget(cfg)` — the configured value when it is a positive integer, otherwise
  `defaultMaxOrderDispatchesPerTick` (4). `buildOrderDispatcherFromOrderSet` (the only production constructor) uses it instead of the
  bare constant. Nothing else in the dispatcher changes: `spendDispatchBudget`, the cursor and the fairness are untouched.
* `docs/schema/city-schema.json`, `docs/schema/city-schema.txt`, `docs/reference/config.md`: the new key, written by hand in the
  generator's format (see "NOT tested").
* Two new test files (below). `[orders]` merging across `include`s needs no change: `compose.go` replaces the whole section when
  the fragment defines `[orders]` (`fragMeta.IsDefined("orders")`).

With the key unset the behaviour is **bit-for-bit today's**: 4 per tick.

## Decisions worth challenging

1. **0, negative and unset all mean "the default (4)", never "unlimited".** The dispatcher treats `maxDispatchesPerTick <= 0` as
   "no cap" internally (existing tests rely on it). A typo such as `= 0` or `= -1` in `city.toml` must not remove the only brake on a
   fork-bomb-shaped loop, so the config cannot reach that branch. If you want a real "unlimited" knob it should be a separate,
   explicit key.
2. **Plain `int`, not `*int`.** Unlike `max_restarts` (where 0 is meaningful), 0 here carries no information, so "unset" and
   "0" need not be told apart.
3. **No upper bound and no warning on absurd values.** A huge value is "unlimited in practice" and is the operator's call; the
   burst risk is spelled out below. Adding a `validate_*` warning is easy but would be new policy.
4. **The default lives in two places** (the Go constant and `jsonschema:"default=4"` + the comment). A cmd/gc test pins the
   constant to 4 and tells whoever changes it to update the docs and run `genschema`.
5. **Helper in `cmd/gc`, not an accessor on `OrdersConfig`.** The "<= 0 → default" rule belongs next to the constant it falls back to.

## Choosing the value (NOT decided here)

The patch only adds the knob. The value must be measured in the window, and **it cannot be picked in isolation from the five 30 s
instances**:

* Per tick (≈ 168 s ≈ 2.8 min) the 63 instances ask for ≈ 41 dispatches; a cap of 4 serves one in ten. The five 30 s instances
  are 10 of the 14.7/min. If they were relaxed to 5 min the demand would fall to ≈ 5.7/min ≈ 16 per tick.
* So a cap near 16 would serve the demand **once** the 30 s instances are relaxed; with them as configured, no sane cap serves them
  all on time, and a big cap makes the engine finally do what the config says: `gate-sweep` ×4 and `dolt-health` every 30 s. The
  host was at load 50–60 during the partial exports this bead is about. More dispatches per tick is more concurrent children per
  tick (thundering herd after a quiet period), which can push `jsonl-export` back into partial exports.
* Suggested sequence for the window (Mayor's call): ship the knob with the key UNSET (no change) → set 8 → watch load, the
  per-instance real gap and `jsonl-export` for one hour → 12 → 16, stopping at the first sign of load growth. Decide the 30 s
  instances in the same session.
* Config-only alternative that needs no engine change: lower `patrol_interval` (capacity scales with 1/interval). It moves the
  whole controller tick (reconcile, health), not just orders, so it has a bigger blast radius; whoever owns `patrol_interval`
  decides.

## Tests and what they prove

Not run (no Go validation by workers). Written to fail on the old code:

* `internal/config/orders_dispatch_budget_test.go`
  * `TestOrdersMaxDispatchesPerTickParses`: unset → 0, explicit → value, 0 and negative are kept as written.
  * `TestOrdersMaxDispatchesPerTickIsAKnownKey`: `CheckUndecodedKeys` does not call the new key a typo.
  * `TestLoadWithIncludes_OrdersMaxDispatchesPerTickOverride`: the fragment's `[orders]` wins over the base file's.
* `cmd/gc/order_dispatch_budget_test.go`
  * `TestOrderDispatchBudget`: nil cfg, unset, 0 and −3 → 4 (never unlimited); 1 and 12 pass through; pins the constant to 4.
  * `TestBuildOrderDispatcherUsesConfiguredBudget`: the production constructor puts the configured value in
    `maxDispatchesPerTick` (9 → 9, unset → 4).
  * `TestOrderDispatchConfiguredBudgetChangesOrdersPerTick`: with 8 due orders, one tick starts 4 by default and 6 with the key
    set to 6 (same shape as `TestOrderDispatchRespectsMaxDispatchesPerTick`).
* Existing tests that assign `m.maxDispatchesPerTick` directly are unaffected (the field is unchanged).

## Applying in the window

```
git apply --check docs/pending-engine-window/ga-ieo0wz1-order-dispatch-cap.patch && git apply docs/pending-engine-window/ga-ieo0wz1-order-dispatch-cap.patch
gofmt -l internal/config cmd/gc                      # must print nothing (it printed nothing on the scratch copies)
go run ./cmd/genschema && git status --short docs/    # TestSchemaFreshness: the generator must reproduce what the patch wrote by hand
go test ./internal/config/ ./cmd/gc/ -run 'MaxDispatchesPerTick|OrderDispatchBudget|ConfiguredBudget|OrderDispatch'
go vet ./internal/config/ ./cmd/gc/ && go test ./test/docsync/
```

If `genschema` changes any of the three doc files, keep the generator's output (the patch's hand-written rows are a best effort).
Then build/swap per the usual window procedure. The patch changes nothing until `[orders] max_dispatches_per_tick` is set.

## Verifying after the window

1. With the key unset: `gc order history` rate and burst size are as before (4 per burst).
2. Set the key (e.g. 8) and reload. `cmd_reload_test.go` builds the dispatcher with `buildOrderDispatcherFromOrderSet`, which suggests
   a reload rebuilds it with the new value; confirm that a reload (not a restart) is enough by looking at the burst size.
3. Measure the per-instance real gap with the same recipe as the bead's first comment: save `gc order list` and `gc order history`
   and compute the median gap between consecutive dispatches of each instance. Target: the 44 always-due instances move from a 35 min
   median toward their configured intervals; `jsonl-export` toward 15 min.
4. Watch the host load and the `exported=N/8` / `partial=` / `deferred=` subjects of new `jsonl-export` commits.
5. The bead's acceptance (3): `latest.json` younger than 4500 s for 24 h in a row (`jsonl-hourly-offsite.sh --status`), and the
   new table-age alarm (`--table-age`) green.

## Rolling back

Remove the key from `city.toml` and reload: the default (4) is exactly the old behaviour, no binary rollback needed. To drop the code,
`git apply -R` the patch.

## What is NOT covered / NOT tested

* Nothing was compiled or run. `gofmt -l` is clean on the edited and new Go files (scratch copies); `git apply --check` is clean on the base.
* The three generated docs were edited by hand to the generator's format (copied from the neighbouring `max_timeout` / `max_restarts`
  entries). `TestSchemaFreshness` is the judge; run `go run ./cmd/genschema` in the window.
* The load effect of a bigger cap is **unmeasured**. It is the main risk and the reason the value is not chosen here.
* Open and unexplained: the observed tick period is ≈ 168 s, not 120 s. It does not change the conclusion (every burst is full, i.e. 4)
  but it means the capacity estimate (1.16/min measured vs 2/min nominal) has a part nobody has accounted for.
* Does not touch the second layer of the same bead (the exporter's low-disk throttle, ga-j2f5v5, owner decides) nor the third (the
  exporter's table read order); the table-age alarm (`jsonl-table-age` order) covers the RPO exposure meanwhile.
