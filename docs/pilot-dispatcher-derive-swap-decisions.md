# pilot-dispatcher.sh → bead_state.derive(): the four decisions

Design-only deliverable for `ga-5ot99` (successor of `ga-4oc2k`, itself the
continuation of `ga-7qsxr`'s steps 1-2). **No production code changes.** This
document closes the four decisions ga-5ot99 requires, maps each to what
changes at the call site, and orders the implementation into dog-sized
slices for whoever picks up `ga-4oc2k` next.

Source grounding: full read of `scripts/bead_state.py` (426 lines, current
as of this writing) and the liveness/branch cluster of
`packs/town-deltas/assets/pilot-dispatcher.sh`
(`_session_is_live`/`_session_is_live_builder`/`_session_is_active_owner`/
`_sling_is_live`/`_beadid_live_crew_owner`/`_target_has_real_branch`/
`_beadid_has_branch`/`_beadid_has_crew_branch`/`_beadid_branch_signal`,
lines ~3244-3930), plus call-site greps across the full 7526-line file.
Not a re-read of the whole file — `ga-4oc2k`'s own catalog (7 findings from
6 parallel full-file reads) is the source of truth for anything not
re-verified here, per its own "don't re-research what's already there."

## Scope note: 4 decisions vs. 7 findings

`ga-4oc2k` catalogued **seven** structural axes; `ga-5ot99` asks this
document to close **four** of them (liveness-multiplicity, idle-time,
branch-evidence, and the None/False invariant — the last is embedded inside
finding #1 in `ga-4oc2k` but is elevated to its own top-level decision here,
correctly — it's the one that turns a design bug into data loss). The other
three findings (#4 prose-only signals, #5 cross-bead queries, #6 dynamic
labels) aren't asked for as headline decisions, but they can't be silently
dropped — they determine which functions *don't* migrate, which the
acceptance criteria explicitly requires ("which functions disappear, which
remain, and why"). They're covered as boundary notes, not full decisions.
Finding #7 (no bash→python bridge exists) isn't one of the four either, but
`ga-4oc2k`'s own mandatory order puts it *before* any of the four — a slice
list that ignores it isn't orderable. Covered as a precondition.

---

## Decision 1 — Liveness is not one predicate: several named functions over one canonical primitive, not a mode parameter

**The three options on the table were:** (a) one function parameterized by
mode string, (b) several independently-named functions, (c) a policy
object.

**Chosen: closer to (b), but restructured.** Not "keep 5 independent
reimplementations as 5 named Python functions" — that just relocates the
duplication. Instead: **one canonical tri-state primitive** (`holder_is_alive`,
already exists, already correct) **extended to accept a richer per-session
record**, plus **2-3 small named composers** that layer additional signals
on top of it. Callers pick a composer by name, not by a mode string.

**Why not (a), a mode parameter:** the five bash predicates don't differ by
*strictness on the same axis* — they differ by which **roster** they
consult and which **side-signal** they fold in:

| function | roster consulted | extra signal folded in |
|---|---|---|
| `_session_is_live` | exact-match against `$_LIVE_SESSION_IDS` | none |
| `_session_is_live_builder` | same, + `$_ASLEEP_SESSION_IDS` | `-adhoc-` naming pattern → asleep = dead |
| `_session_is_active_owner` | **different roster**: `$_ACTIVE_OWNER_IDS`, pre-filtered by idle-minutes | idle-time threshold (180min default) |
| `_sling_is_live` | doesn't consult a session roster at all — reads a *sling bead's* `updated_at` | branch existence (shortcuts to "live" if a branch exists) |
| `_beadid_live_crew_owner` | reads the target bead's own `assignee`, then `_session_is_live` on it | pool-identity exclusion + its own separate phantom-staleness check (45min, a *different* threshold than owner-idle's 180min, and measuring a *different* clock: bead `updated_at` vs. session `last_active`) |

A single `mode` enum would have to encode "which roster" × "which side
signal" × "which threshold" as combinations — at that point the parameter
*is* a policy object wearing a string costume. `_sling_is_live` in
particular isn't a stricter/looser version of session-liveness at all; it's
a different question about a different entity (a sling bead, not a
session). Forcing it through the same function as a "mode" would be the
seam ga-4oc2k warned about: "if the consumer still needs its own logic on
top, the design failed" — a fake-generic mode parameter fails that test as
badly as 5 separate reimplementations do, just with extra indirection.

**Why not (c), a full policy object:** overkill for what's actually only
2-3 real shapes once idle-time and branch-evidence become their own
explicit optional inputs (see Decisions 2-3) instead of being smuggled
inside "liveness." Once those two are pulled out as separate parameters, the
remaining differences between the five functions collapse to: exact roster
match vs. active-owner-filtered match. That's not enough distinct axes to
justify an object; it's two named functions calling one shared primitive.

**Concretely, what ships:**
- `holder_is_alive(assignee, live_sessions)` stays the canonical tri-state
  primitive (True/False/None), but `live_sessions` gains an accepted richer
  shape: either the current `set[str]` (exact/prefix membership, unchanged
  behavior — `_session_is_live`'s equivalent) **or** a
  `dict[str, {state, idle_minutes}]` (enables active-owner semantics without
  a second function reimplementing the None-safety and coordinator-immunity
  logic that already lives in `holder_is_alive`). This mirrors the file's
  own existing `_SESSIONS_JSON` → `_SESSIONS_IDLE_JSON` shape (see Decision 2)
  — the caller already builds this richer record today; `derive()` just
  needs to accept it instead of forcing a flattened set.
- `is_active_owner(assignee, session_meta, idle_threshold_min=180)`: the one
  genuinely-distinct named composer, replacing `_session_is_active_owner`.
  Thin wrapper: resolves the session record, applies the idle+asleep check,
  falls back to `holder_is_alive`'s None-safety for "session not found in
  roster."
- `_session_is_live_builder`'s "-adhoc- + asleep = dead" rule is narrow
  enough (one naming-pattern special case) that it doesn't need its own
  named function — it becomes a one-line guard at the two call sites
  (3538, 4523) wrapping `holder_is_alive`, OR (better, if both call sites
  turn out to want it identically) a third tiny composer
  `is_live_builder(assignee, session_meta)`. Decide which at implementation
  time by reading what the two call sites actually need — don't
  pre-decide this one, it's genuinely a coin flip with no data-loss risk
  either way.
- `_sling_is_live` and `_beadid_live_crew_owner` are **not** liveness
  predicates in this model at all — see Decision 3 and the boundary note
  below. They stay in bash, calling the new primitives for the *session*
  half of their logic and keeping their own I/O (bd show, git) for the rest.

**The test that validates this decision:** after the swap, does
`pilot-dispatcher.sh` still carry its own liveness *logic* (not just a
function call)? With this design: no — every remaining bash function that
touches liveness becomes a thin call into `bead_state`, plus I/O it was
always going to need to do anyway (fetching the session roster, fetching a
bead's assignee). The judgment calls (idle threshold, None-safety,
coordinator immunity) live in exactly one place.

---

## Decision 2 — Idle-time: caller computes it (already does, today), derive() accepts it as pre-computed per-session data

**Where idle enters:** as an optional, richer `live_sessions` input (see
Decision 1), not as a new top-level `derive()` parameter and not as
something `bead_state.py` computes itself.

**Who provides the clock:** the caller — exactly as it already does. This
isn't a new design; it's naming what `pilot-dispatcher.sh` already built.
Lines 3282-3297 compute `_SESSIONS_IDLE_JSON` once per sweep: a python3 pass
over the session roster that adds an `idle_minutes` field per session,
explicitly handling the Go zero-time sentinel (`"0001-01-01T00:00:00Z"` →
`idle_minutes = None`, meaning "asleep/unparseable", not "just started" —
getting this backwards was bug ga-46wq5). `bead_state.py` doesn't need a
clock parameter for this at all; it needs to accept the *already-computed*
per-session `idle_minutes` (or `None`) as part of the session record
described in Decision 1, and apply the existing `now`-style None-safety
convention to it.

**The exact rule to port, verified against the source (not inferred):**
`_ACTIVE_OWNER_IDS` filters with
`select((.idle_minutes == null) or (.idle_minutes < $thresh))` — unknown
idle-time is **included** as active. The comment at line 3330 states the
reason explicitly: "most unknowns are fresh -adhoc- pool workers that never
populated last_active at all, and mass-reclaiming their beads was never
what ga-46wq5 asked for." This is a second, independent instance of the
same None-safety principle Decision 4 requires — `idle_minutes: None` must
resolve the same direction as `alive: None` (toward "don't reclaim"), and
`is_active_owner`'s implementation must preserve it explicitly, not by
accident of a truthy/falsy Python comparison (`None < 180` raises in
Python 3 — this has to be a written `is None` branch, it cannot fall out of
the operator).

**Threshold:** stays caller-supplied with the same default, exactly like
`PILOT_ASSIGNEE_IDLE_MINUTES` (env-overridable, default 180) — `derive()`
already has this exact convention for `now`. `is_active_owner`'s
`idle_threshold_min` parameter defaults to 180 for parity, but the caller
remains the source of truth; don't hardcode it a second time inside
`bead_state.py`.

---

## Decision 3 — Branch/git evidence: stays outside the pure core, enters `derive()` as a pre-resolved optional parameter (same shape as `merged`/`gate_active`)

**Decision:** branch evidence does not get a git-calling function inside
`bead_state.py`. `derive()` already has an established, working pattern for
exactly this shape of problem — a signal that requires I/O, that the
*caller* is better positioned to resolve, and whose resolution should
override the label-only heuristic when supplied. `merged: bool | None` and
`gate_active: bool | None` are both already this pattern, and the docstring
(lines 293-303) already states the rule to extend: "quando o chamador
RESOLVE, o veredito dele GANHA do label" (when the caller resolves it, its
verdict wins over the label). Branch evidence becomes a third parameter of
the same shape: `has_active_branch: bool | None = None`.

**How the error behaves — and this is the one place this document
disagrees with copying bash 1:1:** `_target_has_real_branch` fails
**closed** under uncertainty ("Any uncertainty → return 1 (assert NO
branch)... so this only ever ADDS a keep-signal, never forces a release" —
comment at line 3358). That's the *opposite* direction from
`holder_is_alive`'s "uncertain → None, never collapse to a destructive
verdict." These are not in tension — they're both correct, because they
authorize different things. `_target_has_real_branch` is never, on its own,
the signal that reclaims a bead; it only ever adds protection on top of a
liveness verdict that's already been computed conservatively. A safe
default under uncertainty is whichever direction doesn't authorize the
destructive action — for a pure add-on-protection signal, "assume false"
*is* the safe direction, same as "assume None" is the safe direction for a
signal that gates reclaim directly. **Decision 4 formalizes this
distinction** so it doesn't get flattened into "everything must be
tri-state" during implementation — that would be over-generalizing a
principle past where it applies.

Concretely: `_target_has_real_branch`/`_beadid_has_branch`/
`_beadid_has_crew_branch`/`_beadid_branch_signal` all stay in bash exactly
as they are (they're I/O — `git for-each-ref`, `git ls-remote`, bounded 8s).
The caller resolves `has_active_branch` from whichever of these fits the
call site (see call-site table below) and passes the bool through. No new
Python function is needed for this decision; `derive()` just needs the new
optional parameter and a place to consult it (likely reinforcing rule 7
"executing" — a bead with a confirmed active branch is *never* a stranded
candidate regardless of `alive`, mirroring the existing `_sling_is_live`
shortcut at line 3386 that already treats branch-existence as sufficient
proof of life on its own).

---

## Decision 4 — The third state (most important): every new optional signal is `bool | None`, `None` is the default, and every consumption site tests `is False`/`is True` explicitly, never truthiness

**The invariant, stated precisely:** in `derive()` today, "alive is None
never becomes dead" is not a comment — it's enforced at exactly two call
sites, verified directly in the source:

- Rule 5 (`gate_failed`, line 358): `offer("devolver_pro_pool", alive is
  False, ...)`. Not `not alive`. `alive is False` is `False` when
  `alive is None` — so the pool-return action stays *unavailable* under
  uncertainty. The `reasons` dict even names the two cases separately: "está
  VIVO e trabalhando" (True) vs. "vivacidade NÃO foi consultada" (None) —
  same unavailable outcome, different stated reason, so a human reading the
  panel can tell "confirmed alive" from "didn't check" apart, even though
  both block the same action.
- Rule 7 (`executing`/`stranded`, line 376): `if alive is not False: return
  "executing"`. Both `True` and `None` take this branch; only a *proven*
  `False` reaches `stranded`, the one state whose `actions` include
  `liberar_para_pool` — the actually-destructive one.

**How this document requires it to extend, mechanically — every new
optional parameter added by Decisions 1-3 must be tested the same way:**

1. `idle_minutes: int | None` — `is_active_owner` must branch on
   `idle_minutes is None` explicitly (see Decision 2's note on why this
   can't be a bare comparison), resolving `None` toward "still active,"
   matching the already-shipped bash precedent at line 3321, not toward
   "unknown, more evidence needed."
2. `has_active_branch: bool | None` — must be tested as `is True` at
   whatever rule consumes it (never a bare `if has_active_branch:`, which
   is correct for `True` and incorrect-but-silently-so for `None`, since
   `None` is falsy in Python — the exact class of bug this whole decision
   exists to prevent).
3. A **regression test that isn't a unit test of the logic, but of the
   *omission* itself:** for every optional `derive()` parameter (`merged`,
   `now`, `gate_active`, and whatever Decisions 1-3 add), assert that
   calling `derive(bead)` with the parameter *omitted entirely* produces
   byte-identical output to calling it with the parameter passed as
   explicit `None`. This is cheap to write, catches the specific failure
   mode ga-5ot99 names ("a swap that turns None into False turns a live
   session into a recycled one"), and it's the one test in this list that
   would have caught a regression *before* it reached a call site, not
   after.

**Why this is "most important" (agreeing with ga-5ot99's own framing, with
the concrete cost attached):** every other decision in this document is
about code shape — duplication, organization, where I/O lives. This one is
about what happens when the swap is *wrong*. A shape mistake costs a
refactor. A polarity mistake here (`None` silently reads as `False`) is
indistinguishable, from inside a single sweep, from a correct "confirmed
dead" verdict — it authorizes `liberar_para_pool` on live work. There is no
runtime signal that catches this at the moment it happens; it's only
visible later, as lost work someone has to notice and diagnose. That
asymmetry (cheap-and-visible vs. expensive-and-silent) is why this gets a
mechanical rule (test 3 above) instead of "please be careful."

---

## Precondition: the bash→python bridge (finding #7) has to be decided before slice 1, not during it

Not one of the four decisions, but `ga-4oc2k`'s own mandatory order puts
this first, and the slice list below can't be ordered without picking one.
Three options were on the table, not yet evaluated against real data:

- (a) `python3 -c "from bead_state import derive; ..."` per candidate —
  simplest, but N subprocess spawns per sweep; unmeasured against the
  existing per-candidate git/Dolt call cost.
- (b) one batched Python call per sweep (whole candidate array at once) —
  fewer subprocess spawns, more plumbing (array in, array out via JSON).
- (c) export vocabulary constants as JSON, keep the *logic* in bash — solves
  the "single source of vocabulary" problem cheaply but not the logic
  duplication this whole document is about; would ship none of Decisions
  1-4's benefit.

**Recommendation, not a full decision (out of this bead's scope but needed
to unblock slice 1):** (a) for the first slice specifically. `dispatch_one`
already makes multiple git/Dolt calls per candidate (confirmed: `bd show`
inside `_beadid_live_crew_owner`, `git for-each-ref` inside
`_target_has_real_branch`, both per-candidate, both already in the hot
path) — one more subprocess spawn is very unlikely to be the dominant cost,
but this is an assertion to *measure* in slice 1, not assume. If slice 1's
measurement shows subprocess overhead actually matters, fall back to (b)
before continuing to slice 2. Don't build (b) up front on spec.

## Boundary notes: what stays out of `derive()`, and why (findings #4-6)

Required by the acceptance criteria ("which functions disappear, which
remain, and why") even though these three aren't headline decisions:

- **Finding #4, prose-only signals** (engine-rebuild regex, DECISAO/DECISION
  title prefix, the Athos-exclusivity phrase, the 🚨 marker, "design-first"):
  stay in bash, permanently, by design — not a migration gap to close
  later. `ga-4oc2k` already documents why: these exist specifically
  *because* the equivalent label sometimes gets stripped by auto-refino's
  `--description` rewrite (ga-fnnyy) — they're a second line of defense
  that only works *because* it's independent of the label-driven model.
  Folding them into `derive()` would delete the property that makes them
  useful. `derive()` gains no parameter for this; the functions that scan
  for these patterns are not swap candidates.
- **Finding #5, cross-bead queries** (`_filter_unblocked` → `bd blocked`;
  `_filter_explicit_deps` → `bd show` per dependency; `_filter_built` →
  cross-referencing `type:quality-gate-marker` satellite beads):
  `derive(bead, ...)` is scoped to one bead by contract. These stay in
  bash. The caller resolves the cross-bead fact *before* calling `derive()`
  and passes the result in as one more parameter — the exact pattern
  already used for `live_sessions`/`merged`, not a new one. No expansion of
  `derive()`'s signature to accept a bead graph.
- **Finding #6, dynamic/comparison labels** (`pilot:held-until:<epoch>`,
  `pilot:reclaim-count:<N>`, `gate:fix-attempt:<N>`): partially already
  handled — `_labels_after_expired_hold` (bead_state.py:156) already
  compares `pilot:held-until:<epoch>` against `now`. `reclaim-count` and
  `fix-attempt` are not yet modeled and are explicitly **not** part of this
  swap's scope; they're set-membership-incompatible in the same way, but
  neither was named in ga-5ot99's four decisions, and inventing their
  comparison semantics here would be exactly the "force a design to justify
  it" ga-5ot99 warns against. Flag as a follow-up, don't decide it now.

---

## Call-site implications

Verified by grep across the full file (not from the ga-4oc2k catalog alone
— line numbers below are current, not carried over):

| bash function | call sites (line) | disappears? | replaced by |
|---|---|---|---|
| `_session_is_live` | 3426, 3538*, 4523* (*via `_session_is_live_builder`) | mostly, keep as thin wrapper if any caller wants exact-match only | `holder_is_alive(assignee, live_sessions)` |
| `_session_is_live_builder` | 3538, 4523 | yes, or collapses to a 1-line guard | `holder_is_alive` + adhoc/asleep check inline, or `is_live_builder` composer (decide at impl time, see Decision 1) |
| `_session_is_active_owner` | 4357, 6846 (2 sites) | yes | `is_active_owner(assignee, session_meta, idle_threshold_min)` |
| `_sling_is_live` | 3086, 4514, 5900 (3 sites) | **no** — not a liveness predicate on a session, stays in bash. Its session-liveness *sub-check* (none currently — it only checks branch + bead recency) is unaffected by this swap. | unchanged |
| `_beadid_live_crew_owner` | 4533, 6350, 6442 (3 sites) | **no**, but shrinks — the `_session_is_live "$_asg"` line inside it (3426) becomes a call to `holder_is_alive`; the phantom-staleness+branch logic (finding specific to this function, not shared with anything else) stays local | partially: liveness sub-check only |
| `_target_has_real_branch` | called from `_sling_is_live` (3386) | no | unchanged (resolves `has_active_branch` for Decision 3 callers) |
| `_beadid_has_branch` | 4541, 4551 (2 sites) | no | unchanged |
| `_beadid_has_crew_branch` | 3461 (inside `_beadid_live_crew_owner`) | no | unchanged |
| `_beadid_branch_signal` | 2714, 4221 (2 sites) | no | unchanged |
| `dispatch_one`'s inline liveness reimplementation | inside 5433-7277 (per ga-4oc2k catalog; not re-verified line-by-line here) | yes — this is the third independent reimplementation of the same "None never dead" principle ga-4oc2k found; the whole point of this swap | `holder_is_alive` / `is_active_owner`, called directly instead of reimplemented |

**Net effect:** none of the 9 named functions are deleted outright — 8 of 9
keep doing real, non-duplicated I/O or bash-only work (branch checks,
prose-signal scanning, cross-bead queries) that was never candidate for
`derive()` in the first place. Only the *liveness logic embedded inside*
`_session_is_live_builder`, `_session_is_active_owner`, the liveness
sub-check inside `_beadid_live_crew_owner`, and `dispatch_one`'s inline
copy collapse into calls to `bead_state.py`. This is a smaller surgical
footprint than "swap the file" suggests, and it's why the slice list below
is short.

---

## Implementation slices (for `ga-4oc2k`, in order)

Each is sized to fit a dog session (~25min budget) and ends with a
measurement, per the acceptance criteria. None of these are executed by
this bead — they're the plan `ga-4oc2k` (or its own successor slices)
should follow.

1. **Bridge + measure.** Wire the option-(a) subprocess bridge
   (`python3 -c "from bead_state import derive; ..."`) into exactly one,
   already-isolated call site: `_filter_exec_manual` (already flagged in
   `ga-4oc2k` as "the cleanest candidate — delegates to
   `manual_assigned`/`manual_unrouted`, which `derive()` already has").
   **Measure:** wall-clock of one full dispatcher sweep, before/after, plus
   confirm `pilot-dispatcher.selftest.sh`'s existing cases for this function
   still pass unchanged. This is the slice that answers whether option (b)
   (batched) is actually needed before anyone builds it.
2. **Extend `bead_state.py`: idle-aware session records (Decision 1+2).**
   Add the richer `live_sessions` shape and `is_active_owner`. Pure Python,
   no bash changes yet. **Measure:** the new omitted-parameter regression
   test (Decision 4, item 3) passes; existing 21 `test_bead_state.py` cases
   unaffected; new cases cover `idle_minutes=None` → active (the ga-46wq5
   regression case) and the Go zero-time sentinel path.
3. **Extend `bead_state.py`: `has_active_branch` parameter (Decision 3).**
   Add the parameter and wire it into rule 7. Pure Python. **Measure:** same
   omitted-parameter regression test extended to this parameter; confirm a
   bead with `alive=False` but `has_active_branch=True` resolves
   `executing`, not `stranded` (the case `_sling_is_live`'s branch-shortcut
   already protects in bash today — this slice is porting an existing
   protection, not adding a new one).
4. **Swap `_session_is_active_owner`'s two call sites (4357, 6846).**
   Replace with `is_active_owner`, caller now builds and passes the session
   record (mechanical port of the existing `_SESSIONS_IDLE_JSON` computation
   into the bridge call). **Measure:** run
   `pilot-dispatcher.assignee-liveness.selftest.sh` and
   `pilot-dispatcher.session-liveness.selftest.sh` before and after —
   extract-the-real-function technique the file already uses for this kind
   of comparison (per `ga-4oc2k`'s own instruction: reuse it, don't
   reimplement the comparison).
5. **Swap `_session_is_live_builder`'s two call sites (3538, 4523) and the
   liveness sub-check inside `_beadid_live_crew_owner` (3426).** Same
   measurement discipline as slice 4.
6. **Swap `dispatch_one`'s inline reimplementation.** Highest-risk slice —
   `dispatch_one` is the 1844-line function with 60+ cited bead-ID fixes,
   and the file's own scar tissue (the double-dispatch class, ga-3lsy1/
   ga-9uwbw) lives here. Do this last, after slices 1-5 have already proven
   the bridge and the two composers work correctly elsewhere in the same
   file. **Measure:** full `pilot-dispatcher.selftest.sh` (698 cases) before
   and after, plus a live-data comparison via the same technique ga-7qsxr
   used (`panel_state_divergence.py` repointed at the worktree) — zero
   divergence is the bar, not "tests pass."

After each slice: run the full existing selftest suite (the 9 files named
in `ga-4oc2k`, not just the ones touched) — it's the safety net, and the
instruction from `ga-4oc2k` stands: add to it, don't replace it.

## Is the swap worth it?

Yes, but not as a single cutover — the acceptance criteria allows "the
swap doesn't compensate" as a valid outcome, and this document's conclusion
is deliberately not that. The concrete case for "worth it": `dispatch_one`
today reimplements "alive is None never becomes dead" a third time,
independently, inside one already-1844-line function — that's an active
duplication risk in the file most under active development (60+ cited
fixes), not a theoretical one. Slices 1-3 are low-risk, additive-only
Python changes that ship value (a real regression test for the exact bug
class ga-5ot99 is worried about) before any bash call site changes at all.
Slices 4-6 are where the payoff and the risk both live, sequenced from
least to most consequential file region.
