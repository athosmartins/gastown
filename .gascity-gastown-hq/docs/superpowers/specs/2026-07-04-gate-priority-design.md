# Gate Priority (Increment 2) — Design Spec

> Status: **DRAFT — awaiting Athos's approval before implementation.**
> Adversarial-reviewed (4 lenses, 2026-07-03). Control model chosen by Athos:
> **⚡ Priorizar + setas ↑/↓ entre as priorizadas** (fine control, safe version).

**Goal:** Let Athos (via the kanban) or an agent (via `bd`) steer the ORDER in
which queued gate markers are reviewed — a "priority queue" for the gate —
without preemption and without the total-order-drag risks the review flagged.

**Non-goals (explicitly deferred to a possible Increment 3):** killing/​preempting
an in-flight review; full drag-and-drop total ordering of the whole queue;
reordering items that are already *in review*.

---

## 1. Context / what already shipped

- **Increment 1 (DONE, live):** the gate sidebar rows ("Em revisão" / "Na fila")
  are now clickable → open the source bead's drawer. Commits `d59bb958` +
  `e8aef29e` (XSS-hardened). This spec is the SEPARATE follow-on.
- **Today's queue order** (`quality-gate-dispatcher.sh` ~L1496–1568) is a 3-tier
  jq sort over `gate-status:queued` markers only:
  1. healthy + aged (>30min wait) → oldest-first (anti-starvation)
  2. healthy + fresh → newest-first (Athos's deliberate policy)
  3. rebase-failed → last (anti-head-of-line-block; this tier exists because a
     broken branch "travou a fila inteira" TWICE = real ~49min outages)
- `created_at` is IMMUTABLE via labels → there is **no** way to re-rank a marker
  today. That missing hook is exactly what this spec adds.
- Concurrency is dynamic and SEPARATE from order (Dolt/quota headroom → 0/1/2
  runs). Reordering never preempts a running review nor adds capacity — it only
  changes **who wins the next free slot**.

---

## 2. Core mechanism — `gate.pinned_rank`

A new integer marker metadata field, written **atomically** with
`bd --set-metadata` (NOT labels — labels have a remove-then-add gap that the
`gate.submitted_by` field already avoids, dispatcher ~L1651).

- **Absent** (default) → marker is unpinned → falls through to the existing
  3-tier natural order.
- **Present** (integer, lower = higher priority) → marker is "pinned" → sorts in
  a new **tier 0** ABOVE the healthy tiers, ordered by `pinned_rank` ascending.

### The new 4-tier sort (dispatcher jq, replacing L1563–1567)

```
tier0: pinned  AND (NOT rebase-fail)   → sort_by(pinned_rank) asc
tier1: healthy AND aged  AND (NOT pinned) → oldest-first
tier2: healthy AND fresh AND (NOT pinned) → newest-first
tier3: rebase-fail (pinned OR not)        → last, newest-first
```

Read `pinned_rank` from `.metadata["gate.pinned_rank"]`.
**VERIFY during implementation:** that `bd list --json` includes `.metadata` on
markers (the dispatcher currently only reads `.labels`/`.created_at`). If not,
the marker query must be widened or a per-marker `bd show` used for the pinned set.

---

## 3. Invariant guards (CRITICAL — from adversarial lens A)

These are non-negotiable; without them the feature re-introduces the ~49min
outage class:

1. **Rebase-fail ALWAYS sinks.** A pinned marker that also carries
   `gate:rebase-attempt:N` stays in tier 3. Pinning NEVER rescues a broken
   branch to the front. (Guard: `pinned AND (has_rebase_fail | not)` in tier 0.)
2. **Cleared on re-queue.** Every path that re-queues a rebase-failed marker
   (dispatcher ~L2529 and ~L2584, the `gate:rebase-attempt:N→N+1` swaps) must
   also clear `gate.pinned_rank` via `--set-metadata` (set to empty/absent).
   Otherwise a pinned-then-broken marker would keep its rank through retries.
3. **New arrivals are unranked** → natural tier (below pinned). No auto-numbering;
   a freshly-submitted marker never silently jumps a pinned one.
4. **Atomic writes.** All rank mutations use `bd --set-metadata` (single
   overwrite). No label add/remove sequences for rank.
5. **Fresh read each sweep.** The dispatcher reads `pinned_rank` at marker-list
   time every sweep → a human reorder takes effect on the next sweep (≤~2min).
   This 1-sweep lag is acceptable for a manual action (documented in the UI).

---

## 4. Rank arithmetic (⚡ + ↑/↓)

Small pinned set (typically 0–4 items). Integer ranks, gap-based:

- **⚡ Priorizar (pin):** `pinned_rank = (min existing pinned_rank) − 1`, or `0`
  if no marker is pinned yet → new pin lands at the TOP.
- **⚡ again (unpin):** clear `gate.pinned_rank` (marker returns to natural order).
- **↑ (subir):** swap `pinned_rank` with the pinned neighbor immediately above.
- **↓ (descer):** swap with the pinned neighbor immediately below.
- Arrows are **disabled** at the ends (top item's ↑, bottom item's ↓).

Swaps keep the integer space bounded and need no renumbering. Two writes per
swap (both neighbors); acceptable (2 items, atomic each).

---

## 5. UI (kanban) — from lenses B & C

**Split the gate column into two clearly-different sections:**

- **"⟳ Em revisão"** — READ-ONLY status. NO ⚡, NO arrows. Reordering an
  in-review marker is a no-op (it has left the queue; the dispatcher only selects
  among `queued`). Showing controls here would be a UX lie. Keep the clickable
  row (Increment 1) → drawer only.
- **"⏳ Na fila"** — the genuinely reorderable queue. Each card shows:
  - `⚡` toggle (pin/unpin)
  - `↑ ↓` arrows (visible only when pinned; disabled at ends)
  - a small position badge for pinned items (`1º`, `2º`, …)
  - the existing drawer-on-click (Increment 1) preserved

**Refresh interaction:** the board auto-refreshes every 30s. Because the control
is discrete clicks (NOT a continuous drag), the conflict is mild: apply an
optimistic update to the clicked card, POST the mutation, and let the next
refresh reconcile from the persisted `pinned_rank`. No drag-lock machinery
needed (that was the drag-only problem).

---

## 6. Write path + security

- **New panel endpoint:** `POST /api/marker/<id>/rank` with body
  `{action: "pin"|"unpin"|"up"|"down"}`. Reuses the existing `_bd_write` helper
  → `bd --set-metadata gate.pinned_rank …` on the marker's store.
- **Marker-id allowlist:** reuse the `_safe_click_sid` allowlist (from the XSS
  fix) to validate `<id>` before it reaches any shell/`bd` call.
- **Auth debt (PRE-EXISTING, flag):** the panel's write routes
  (`/api/bead/*/approve|block|kill|…`) currently have **no auth** (only
  `/api/status` checks a token). This new route inherits that. Recommend a
  follow-up to add an `X-Panel-Token` gate to ALL write routes; at minimum the
  daemon binds `127.0.0.1` (the public `painel.urblink.com.br` proxy is the
  exposure). This is a separate hardening item, not blocking, but must be
  named so it isn't silently accepted.

---

## 7. Agent path ("pedir a um agente") — free

Once tier 0 exists, an agent prioritizes with zero new UI:
`bd -C <store> --set-metadata <marker-id> gate.pinned_rank <n>` (or a thin
`gc gate priorize <bead>` wrapper). The dispatcher reads it next sweep. This
covers Athos's "ou pedindo a um agente" with no extra surface.

---

## 8. Data flow

```
Athos clicks ⚡/↑/↓          agent runs bd --set-metadata
        │                              │
        ▼                              ▼
POST /api/marker/<id>/rank   ── writes ──►  marker.metadata["gate.pinned_rank"]
        │ (optimistic UI)                        │  (Dolt, atomic)
        ▼                                        ▼
  next 30s refresh  ◄── reads pinned_rank ──  dispatcher sweep (~2min)
                                                 │ 4-tier sort selects pinned first
                                                 ▼  (rebase-fail still sinks)
                                            next review slot
```

## 9. Error handling / edge cases

- Marker claimed/merged/closed mid-interaction → rank write no-ops on a
  closed marker; UI reconciles on next refresh (card gone).
- Concurrent human + agent on the same marker → last-writer-wins on the metadata
  (acceptable; tiny set, no corruption — single atomic field).
- Non-integer / corrupt `pinned_rank` → jq `try … catch` treats as unpinned
  (fail-safe to natural order), mirroring the existing `is_aged` guard.
- Dolt hot at sweep → headroom gate still governs; pinned marker waits for a
  slot exactly like any other (correct — priority must not bypass headroom).

## 10. Testing

- **Dispatcher selftest** (extend the `SELFTEST-EXTRACT marker-select` block):
  pinned goes before healthy; **pinned+rebase-fail still sinks to tier 3**;
  unpinned keeps current 3-tier order; corrupt rank → unpinned; ordering within
  pinned set by `pinned_rank`.
- **Re-queue clears rank** selftest: a rebase-fail re-queue drops
  `gate.pinned_rank`.
- **Panel tests:** endpoint pin/unpin/up/down mutate correctly; ⚡/arrows render
  ONLY on `na fila` cards, never on `em revisão`; id allowlist rejects a bad
  marker id; optimistic-render shape.

## 11. Rollout

1. Dispatcher: metadata read + 4-tier sort + re-queue clear + selftests (HQ repo,
   `packs/town-deltas/assets/quality-gate-dispatcher.sh` — committed = live).
2. Panel: endpoint + `⚡`/`↑`/`↓` UI + split section + tests (WA rig; deploys via
   painel-prod-deploy-sync).
3. (Optional, separate) auth on panel write routes.

Each layer is independently shippable and testable; layer 1 (dispatcher + agent
path) delivers value even before the kanban UI lands.

## 12. Open risks (accepted)

- 1-sweep (~2min) lag between click and effect — inherent, documented in UI.
- Pinned-set starvation of normal work is bounded because pinning is manual/rare
  and the anti-starvation aging still applies WITHIN the unpinned tiers.
- Auth debt on write routes (§6) — pre-existing, flagged, follow-up.
