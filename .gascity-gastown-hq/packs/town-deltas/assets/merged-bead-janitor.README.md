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
