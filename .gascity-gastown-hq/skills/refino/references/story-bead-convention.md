# Story Bead Convention

This document is the **canonical contract** between the Refino skill (writer),
the Kanban (reader), and the Pilot (dispatcher). Any tool that creates, reads,
or routes story beads MUST follow this convention.

---

## Bead Type

All story beads use type `feature`.

```bash
bd create "Título da história" --type feature
```

---

## Label Convention

### Lifecycle state label (mandatory, exactly one)

| Label | Meaning |
|-------|---------|
| `story:unrefined` | Story stub — title only, not yet through Refino |
| `story:refinement-in-progress` | Refino session started but not approved |
| `story:approved` | All 8 fields filled, Athos explicitly approved |
| `story:in-flight` | Dispatched to a worker, work underway |
| `story:done` | Work complete, accepted |
| `story:cancelled` | Story cancelled (add note with reason) |

Only ONE lifecycle label per bead at any time. Prefer `--set-labels` for
transitions — it atomically replaces the lifecycle label regardless of which
lifecycle label the bead currently holds:

```bash
# Safe atomic transition (preferred — works from any lifecycle state)
bd -C "$GC_CITY_PATH" update <id> --set-labels story:approved

# If the bead also carries qualifier labels (story:blocked, etc.) that must
# be preserved, include them alongside the new lifecycle label:
bd -C "$GC_CITY_PATH" update <id> --set-labels story:approved,story:blocked
```

### Optional qualifier labels

| Label | When to use |
|-------|------------|
| `story:epic-split` | Applied to the parent bead when story was split into sub-stories |
| `story:blocked` | Story is blocked by an external dependency |

---

## Metadata Keys

All 8 Refino fields are stored as structured metadata on the bead.
Set with `--set-metadata key=value` (one call per key, or batch via JSON).

| Metadata key | Field | Type |
|---|---|---|
| `story.resumo` | Field 1 — headline | string |
| `story.o_que_e` | Field 2 — what + why | string (multiline ok) |
| `story.estrela_guia` | Field 3 — north-star metric | string — or the skip sentinel (see below) in simplificado |
| `story.equilibrios` | Field 4 — balancing metrics | string (semicolon-separated list) — or the skip sentinel in simplificado |
| `story.dashboard` | Field 5 — post-ship signals | string (semicolon-separated list) — or the skip sentinel in simplificado |
| `story.criterios` | Field 6 — acceptance criteria | string (newline-separated list) |
| `story.dependencias` | Field 7a — dependencies | string |
| `story.fora_de_escopo` | Field 7b — out of scope | string |
| `story.size_check` | Field 8 — epic/story check result | `"story"` or `"epic"` |
| `story.refino_mode` | Refino mode used | `"simplificado"`, or **absent** = completo (default) |
| `story.aprovado_por` | Approval actor | `"athos"` |
| `story.aprovado_em` | Approval timestamp (ISO 8601) | string |

### Refino mode + the skip sentinel

The `/refino` skill runs in two modes (see the skill's "Mode Selection"):

- **Completo** — all 8 fields. `story.refino_mode` is **not set**; absence of the
  key means completo. Every existing/legacy bead falls here.
- **Simplificado** — only F1, F2, F6, F7, F8 are filled. The bead carries
  `story.refino_mode=simplificado`, and the three cut fields
  (`story.estrela_guia`, `story.equilibrios`, `story.dashboard`) are written
  with the literal **skip sentinel**:

  ```
  — pulado no refino simplificado
  ```

**Treat the sentinel as absent.** Any consumer reading `story.estrela_guia`,
`story.equilibrios`, or `story.dashboard` MUST treat a value equal to the skip
sentinel as "no content" — not as a real metric/signal. In particular, the
`--has-metadata-key story.estrela_guia` query (below) will return simplificado
beads as having the key set even though the value is the sentinel; filter the
sentinel out when you need beads with a *real* north-star metric. The sentinel is
intentional (it distinguishes "skipped" from "forgotten") and must never be
silently rendered as data.

---

## Write-back Commands

All `bd` write-back commands MUST use `bd -C "$GC_CITY_PATH"` to target the
correct city database explicitly. Never rely on CWD auto-discovery.

### Creating a new story bead

```bash
# 1. Create the bead with title, type, and lifecycle label
#    --priority is set interactively — see Priority Convention below
ID=$(bd -C "$GC_CITY_PATH" create "Título da história" --type feature --silent \
  --label story:approved \
  --priority "$PRIORITY")

# 2. Set the description (Field 2 — o que é + por que importa)
bd -C "$GC_CITY_PATH" update "$ID" \
  --description "O que é + por que importa (Field 2 content)"

# 3. Set acceptance criteria as the structured acceptance field
bd -C "$GC_CITY_PATH" update "$ID" \
  --acceptance "- Critério 1\n- Critério 2\n- Critério 3"

# 4. Set all Refino metadata fields
bd -C "$GC_CITY_PATH" update "$ID" \
  --set-metadata "story.resumo=Headline em uma frase" \
  --set-metadata "story.o_que_e=O que é + por que importa (full)" \
  --set-metadata "story.estrela_guia=Métrica estrela-guia" \
  --set-metadata "story.equilibrios=Equilíbrio 1; Equilíbrio 2" \
  --set-metadata "story.dashboard=Sinal 1; Sinal 2" \
  --set-metadata "story.criterios=Critério 1\nCritério 2" \
  --set-metadata "story.dependencias=Nenhuma" \
  --set-metadata "story.fora_de_escopo=Exclusão explícita 1" \
  --set-metadata "story.size_check=story" \
  --set-metadata "story.aprovado_por=athos" \
  --set-metadata "story.aprovado_em=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Story bead created: $ID"
```

### Updating an existing bead (e.g. re-refined after changes)

```bash
# Atomically replace the lifecycle label regardless of current state.
# --set-labels replaces ALL existing labels, so carry over any qualifier
# labels (story:blocked, etc.) that must be preserved.
bd -C "$GC_CITY_PATH" update "$ID" \
  --set-labels story:approved

# Update metadata fields (only the changed ones)
bd -C "$GC_CITY_PATH" update "$ID" \
  --set-metadata "story.estrela_guia=Nova métrica atualizada" \
  --set-metadata "story.aprovado_em=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

### Saving partial progress (session interrupted)

```bash
# If Refino session is interrupted before approval:
# --set-labels atomically replaces the lifecycle label (handles both
# story:unrefined and any previously set story:refinement-in-progress).
bd -C "$GC_CITY_PATH" update "$ID" \
  --set-labels story:refinement-in-progress \
  --append-notes "Refino interrompido após Campo 4. Retomar em: Campo 5 — Dashboard."
```

---

## Priority Convention

After Athos approves the story, the agent asks a single priority question
(in Portuguese, product language) and maps the answer to `--priority`:

```
Qual a prioridade — Normal / Alta / Baixa?
```

| Athos answer | --priority flag |
|---|---|
| Alta | 1 |
| Normal | 2 (default if unclear) |
| Baixa | 3 |

P0 is reserved for production blockers and should not be set via Refino.
P4 (someday/maybe) can be set if Athos explicitly says "por enquanto não" or
equivalent.

| Priority | When |
|----------|------|
| P0 | Blocker — nothing else matters |
| P1 | Alta — entregar esse ciclo |
| P2 | Normal (padrão para histórias recém-refinadas) |
| P3 | Baixa — backlog, quando conveniente |
| P4 | Someday/maybe |

---

## Reading / Querying Story Beads

All `bd` read commands should also use `bd -C "$GC_CITY_PATH"` for consistency
and safety, though auto-discovery is safe for reads.

### List all approved stories

```bash
bd -C "$GC_CITY_PATH" list --label story:approved --type feature
```

### List stories eligible for dispatch (pilot query)

Approved stories that are not yet in-flight or done:

```bash
bd -C "$GC_CITY_PATH" list --label story:approved --type feature \
  --exclude-label story:in-flight \
  --exclude-label story:done
```

### List all unrefined stubs

```bash
bd -C "$GC_CITY_PATH" list --label story:unrefined --type feature
```

### List stories in any lifecycle state

```bash
bd -C "$GC_CITY_PATH" list --label-pattern "story:*" --type feature
```

### Show full story with all metadata

```bash
bd -C "$GC_CITY_PATH" show <id> --long
```

### Filter by metadata field (e.g., find stories with estrela-guia set)

```bash
bd -C "$GC_CITY_PATH" list --has-metadata-key story.estrela_guia
```

---

## Epic Split Convention

When Refino determines a story is too big:

1. Change the parent bead to `type=epic` and label `story:epic-split`.
2. Create child stubs for each sub-story with:
   - type `feature`
   - label `story:unrefined`
   - `--parent <epic-id>`
   - title only (Fields 1-8 left blank until each sub-story is refined)

```bash
# Convert parent to epic.
# --set-labels atomically replaces the lifecycle label with story:epic-split.
bd -C "$GC_CITY_PATH" update "$PARENT_ID" --type epic --set-labels story:epic-split

# Create child stubs.
# --no-inherit-labels ensures each child carries ONLY story:unrefined
# (without silently inheriting story:epic-split from the parent).
CHILD1=$(bd -C "$GC_CITY_PATH" create "Sub-história 1: título" --type feature \
  --parent "$PARENT_ID" --label story:unrefined --no-inherit-labels --silent)
CHILD2=$(bd -C "$GC_CITY_PATH" create "Sub-história 2: título" --type feature \
  --parent "$PARENT_ID" --label story:unrefined --no-inherit-labels --silent)

echo "Epic: $PARENT_ID | Children: $CHILD1, $CHILD2"
```

---

## Contract Notes (for Kanban and Pilot builders)

- **Label for Kanban filtering:** `story:approved` is the "ready for backlog"
  state. The Kanban should use `bd list --label story:approved --type feature`
  as its primary query.
- **Label for dispatch eligibility:** The Pilot should only dispatch beads with
  `story:approved` label AND without `story:in-flight` or `story:done`. Use the
  exact query: `bd list --label story:approved --type feature --exclude-label story:in-flight --exclude-label story:done`.
- **Metadata completeness:** Before dispatch, the Pilot should verify that
  `story.criterios` and `story.resumo` are set (minimum viable fields for a
  worker to start). Use `bd show <id> --json` to inspect. Both fields are filled
  in **both** refino modes, so simplificado beads pass this check and are fully
  dispatchable.
- **Simplificado beads:** A bead with `story.refino_mode=simplificado` is a
  normal `story:approved`, dispatchable story. Its `story.estrela_guia`,
  `story.equilibrios` and `story.dashboard` carry the skip sentinel (`— pulado
  no refino simplificado`) — treat those as absent, never as real
  metrics/signals (see "Refino mode + the skip sentinel").
- **Acceptance criteria field:** The `--acceptance` field on the bead is the
  canonical acceptance criteria (same as `story.criterios`). Workers can read
  it directly via `bd show <id>`.
- **No new database:** All story beads live in the city's `.beads/` database.
  No separate store needed.
