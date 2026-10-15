# merged-bead-janitor (ga-tijv5)

## Contents

• Why beads get stuck (the three shapes) · How it decides (three OR-signals)
• Pending-crew-branch veto (wa-1jk89) — one signal can't vouch for a sibling branch
• Guards (zero false-positive is the paramount constraint)
• Durable prevention — commit convention (fixes the sibling root cause)
• Joint/split beads — the stale-comment guard (ga-2zp4h)
• Gate-passed stories wait for delivery (ga-botvu2) · Operating

Closes beads that are stuck `in_progress` ("em voo" on the Kanban) even though
their code is already merged to `origin/main`. Runs as a launchd sweep
(`merged-bead-janitor.plist`, every 15 min, `RunAtLoad`).

## Why beads get stuck (the three shapes)

1. **Sibling-under-parent** — several sub-task beads are worked on ONE shared
   branch and committed under the **parent** id (`feat(wa-ab6z)`). The gate only
   closes the source-bead **named** in the marker, so the un-named siblings never
   close (e.g. `wa-t6pa`, `wa-r4zr`).
2. **Errored-then-merged** — the branch lands via a `superseded`/`error` marker
   path instead of a clean `passed`, so the source-bead close step never fires
   (e.g. `wa-27jn` merged @`04f6c76f`, marker errored; its HQ holder `ga-u70a8`
   stayed `in_progress`).
3. **Cross-store mirror** — a rig-store bead whose artifact is HQ-local lands in
   the **HQ** repo under a mirror bead (e.g. `wa-1or2` ↔ `ga-piycl`,
   `feat(refino): … Mirrors WA bead wa-1or2`, merged in HQ `origin/main`
   @`9bdd48df3`). The wa repo shows no merge; the HQ repo does.

## How it decides (three OR-signals)

For each `in_progress` bead, **any** of:
- **(A) commit** — the bead id appears (token-bounded) in an `origin/main`
  commit message of the bead's own rig repo **or** the HQ repo (mirror).
- **(B) marker** — a **closed** gate marker (`source-bead:<id>`) carries
  `gate-status:passed` or `gate-status:superseded` (the gate's own authoritative
  "merge landed" terminal states; `gate-status:failed` is **not** merged).
- **(C) branch** — the bead's branch (from a marker `branch:<…>` label, or the
  `crew/*/<id>` convention) is an ancestor of `origin/main`.

→ close the bead + drop `story:in-flight` + comment the evidence + `notify`.

## Pending-crew-branch veto (wa-1jk89) — one signal can't vouch for a sibling branch

A bead can have **more than one** `crew/*/<id>[-<suffix>]` branch — e.g. a
follow-up `-fix` branch pushed after the primary branch already merged/gated.
Whichever signal fires above only proves **one thing** merged; it says nothing
about a sibling branch for the *same bead* still sitting unmerged. Measured
live: `wa-a7e98` closed on signal (B) (a terminal gate marker) while
`crew/batista/wa-a7e98-fix` — 2 commits fixing a since-stale `CLAUDE.md` guard
section — stayed unmerged, orphaning the fix behind a closed bead.

Before any close actually happens, the janitor now enumerates **every**
`crew/*/<id>[-<suffix>]` branch on the remote and requires **all** of them to
be ancestors of `origin/<default>`. If any is pending, the close is vetoed —
the bead stays open and a comment names the pending branch(es) instead.
A bead with **zero** crew branches (delivered purely by commit/marker
evidence) is never blocked by this — it's an all-or-nothing gate over
*discovered* branches, not a requirement that one exist.

## Guards (zero false-positive is the paramount constraint)

- **Epics are never auto-closed** (they are parents).
- A bead with **any OPEN gate marker** (queued/ready/dispatching/needs-rebase/
  error/deferred) is actively in the gate → **never closed**. This also keeps an
  errored-but-not-yet-merged bead.
- A bead labeled **`delivery:partial`** (ga-f54ui) is never closed — the gate's
  own heuristic already judged its body enumerates multiple deliverables of
  which only one diff was reviewed; a merge signal here proves nothing about
  the rest of the scope.
- A bead labeled **`delivery:pending-restart`** (ga-l7n3v) is never closed —
  quality-gate-dispatcher.sh's BUG/TASK path stamps this when a merged fix's
  daemon-liveness verification failed or is still pending; the gate MARKER
  closes as `gate-status:passed` before that hold decision runs, so the
  open-marker guard above cannot protect it — this is a dedicated guard for
  exactly that gap (same shape as the `delivery:partial` guard, one cycle later).
- A signal (A) commit whose **only** touched files live under
  `docs/pending-engine-window/` never closes **alone** (ga-fbycg) —
  that convention **stages** an engine-rebuild `.patch` file for a later
  build+swap window; it does not apply the fix. Confirmed false-closes twice
  (`ga-soxi9`, `ga-9n9z7`): the bead's only trace in `origin/main` was the
  patch-staging commit. Signals (B)/(C) are unaffected — a real gate marker or
  merged branch for the same bead still closes it normally.
- No signal → **keep**. A stale **unmerged** branch contributes nothing.

## Durable prevention — commit convention (fixes the sibling root cause)

Signal (A) only catches a sibling if its **own** bead id appears in a commit
message. The sibling-under-parent shape exists precisely because workers commit
everything under the parent id. To make the gate (and this janitor) self-healing:

> **When a branch carries work for more than one bead, every completed bead id
> MUST be referenced in a commit message** — either one commit per bead
> (`feat(wa-t6pa): …`) or a trailer block on the final commit:
>
> ```
> feat(wa-ab6z): dashboard data layer
>
> Closes: wa-t6pa, wa-r4zr, wa-iavz
> ```

`gate-done`/crew workers should emit these references. With them, signal (A)
closes each sibling within one janitor cycle with no human action and no
parent-child cascade guessing. Until the convention is universal, the janitor
falls back to signals (B)/(C) and, for pure no-signal siblings, **keeps** the
bead (advisory only) rather than risk a false close.

## Joint/split beads — the stale-comment guard (ga-2zp4h)

Signal (A) only proves *a commit scoped to this bead id landed in `origin/main`* —
not that *this bead's own remaining work is done*. A bead split into two owners'
halves can still have the sibling's delivery commit scoped to the shared
**parent** id (`wa-d3136`: mila's half was delivered and gated under her own
split-off sibling bead `wa-eda28`, but her commit's subject still read
`chore(wa-d3136): …`) — signal (A) fires "correctly" on the parent, yet the
parent's own remaining half (thies's) was never built.

Fix: if any bead **comment postdates** the commit signal (A) matched, signal (A)
is suppressed **for that bead alone** — the janitor defers to signals (B)/(C),
which are bead-specific and unaffected. This doesn't prove the bead is
unfinished; it means a single old commit shouldn't be trusted alone once the
bead's own story has visibly continued since (reassignment, scope narrowing, a
follow-up comment).

## Gate-passed stories wait for delivery (ga-botvu2)

The story sweep (ga-gosfs) closes `story:approved` stories whose code is in `origin/main`. A story the
gate just PASSED is exactly that — `story:approved` + `gate:passed`, merged, waiting for `story-delivery`
to deploy and prod-test it — so the sweep used to close it as `story:done` before the deploy ever ran.

Now a story carrying `gate:passed` is left alone for a **grace** counted from its last update
(`updated_at`). The outcome has four states (`story_gate_passed_grace_state`):

| state | meaning | the sweep |
|---|---|---|
| `none` | no `gate:passed` — never queued for delivery | closes on merge evidence, as before |
| `waiting` | `gate:passed`, younger than the grace | keeps it (`keep:gate-passed-awaiting-delivery-grace`) |
| `elapsed` | `gate:passed`, older than the grace | closes it as a **backstop** |
| `unknown` | `gate:passed` but the age can't be computed (`updated_at` empty/unparseable, clock skew, bad grace setting) | keeps it (`keep:gate-passed-grace-unreadable`) — never read as "old enough" |

A **backstop** close is not a delivery: the story gets the label `delivery:janitor-backstop` (added before the
close, so it survives a failed close), `story:done` as before (the painel and other consumers route on it),
and a close reason and comment that say **deploy and prod-test were NOT verified**. Anything labelled
`delivery:janitor-backstop` should be checked by hand.

The default grace is **1800 s** (`JANITOR_STORY_DELIVERY_GRACE_SECONDS` overrides it; the janitor runs every
900 s, so the effective wait is 1800–2700 s). Not the 600 s first proposed: `story-delivery` handles stories
one at a time and a single pass takes 6.5–10 min when it deploys — measured on its log (319 passes) p50 32 s,
p90 466 s, p95 609 s, p99 931 s, max 1546 s. A 600 s grace would still close a story whose own pass is
mid-flight, or one queued behind another. A non-numeric setting does not drop the wait: it holds every
gate-passed story and the log says `state=unknown`.

The other half is the hand-off itself: a story handed off without `gate:passed` is invisible to `story-delivery`
(and, by the table above, closed on sight). The dispatcher's three hand-off writes and the guard's
`gap2_apply_pass_verdict` used to write the label with `|| true`; they now call `gate_passed_confirm`
(`quality-gate-guard.sh`), which reads the label back, rewrites it once, and — if it is still missing —
comments on the bead with the hand fix. Proven by `gate-passed-confirm.selftest.sh`.

## Operating

```bash
# safe preview (no mutation), all rigs:
JANITOR_DRY_RUN=1 JANITOR_LOG_STDOUT=1 bash merged-bead-janitor.sh --dry-run
# one rig:
JANITOR_RIGS=wa bash merged-bead-janitor.sh --dry-run
# self-test (no Dolt/network):
bash merged-bead-janitor.selftest.sh
```

Log: `.gc/logs/merged-bead-janitor.log`. Install: load the plist via launchd.
