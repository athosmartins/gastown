# merged-bead-janitor (ga-tijv5)

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
