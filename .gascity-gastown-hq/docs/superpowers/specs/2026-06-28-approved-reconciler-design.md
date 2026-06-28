# Approved-State Reconciler — "aprovado" = "vai ser construído agora"

**Date:** 2026-06-28
**Goal:** Make "story:approved beads exist but 0 in execution, silently, for hours" **structurally impossible** — the recurring symptom Athos has reported 20+ times. A truly unstoppable pipeline never accumulates approved-but-idle work: every approved bead is either flowing toward build, or it is routed out of "approved" into its true state and the operator is told.

**Origin:** 2026-06-27/28. The dev pipeline sat idle all night with 18 `story:approved` beads. Honest classification: **0 were buildable by a headless code worker.** 10 needed a physical phone (on-device WhatsApp warming), 4 needed human judgment, 1 was externally blocked, 3 were post-build/reserved. The painel counted all 18 as "approved," so the operator correctly saw a contradiction ("approved + nothing building") and concluded the system was broken. **It was: the approval gate approves work the code-pipeline cannot execute, and nothing ejects it.** Domain expert (Oracle, who ran on-device all night) confirmed the root and the fix.

## 1. The core guarantee

**For every `story:approved` bead, within a bounded time, exactly one of these is true:**
1. it is **in-flight or dispatched** (the machine is building it), OR
2. it has been **routed out of `story:approved`** into its true state (`story:needs-device` / `story:needs-human` / `story:blocked`) and the operator was notified, OR
3. it is **assumed-buildable but NOT flowing** → the reconciler **ALARMS** (buildable work is starving — a real dispatch failure to investigate).

Result: `story:approved` only ever contains work the machine will build now. "Approved + 0 execution, silently" cannot happen — case 3 guarantees a human is told.

## 2. The decisive insight (Oracle)

An on-device "feat(warming)" bead is **two things mixed**:
- **(A) BUILD the driver** — Python, flag-gated, mockable → a code worker CAN and SHOULD build it (proven: `lib/claro_recharge.py` was built this session).
- **(B) RUN it on a live phone** — screencap verification, tuning, ban/irreversible steps (real money, real WA account) → needs a reserved phone + **human checkpoint**. Not code-gate.

So on-device beads are **not un-buildable** — their code half is buildable. The right move is **route/split, not eject**: the code half goes to the pipeline; the run half goes to a **device-ops queue** surfaced on the frota dashboard (`frota.urblink.com.br/aquecimento`, already exists). On-device execution is "imparável in driver-construction (code), semi-autonomous with checkpoints in execution (device)."

## 3. Scope — v1 (this spec) vs v2 (follow-on)

**v1 — the forcing-function (this spec):** a reconciler daemon that classifies every `story:approved` bead by **explicit signal** and either routes it out or guarantees-flow-or-alarms. This alone kills the silent-idle symptom. **SAFE DEFAULT: a bead is assumed buildable unless it has an EXPLICIT non-buildable signal** — we never hide real work by guessing; an un-signalled un-buildable bead stays approved and ALARMS (case 3), prompting a human to add the right signal. Erring toward alarm, never toward hiding.

**v2 — the code/run SPLIT (separate spec, deferred):** decomposing a mixed on-device bead into a code sub-bead (→ pipeline) + a run sub-bead (→ device-ops queue) requires understanding the bead's content → a refino-stage agent, not a pure reconciler. Plus the device-ops queue surfaced on the frota dashboard. Deferred because it is agent/refino work and must not block the v1 guarantee.

## 4. v1 design — the reconciler daemon

**Cadence:** every ~10 min (launchd), like the other lifecycle daemons. Detect-and-route + alarm; integrates `flow-authority.json`; registered in DPW with a heartbeat; emits to the human-touch ledger. Env kill-switch (`APPROVED_RECONCILER_ENABLED`, default-on) + `DRY_RUN`.

**Per `story:approved` open bead across HQ/WA/PS stores** (multi-store, HQ root = `.gascity-gastown-hq` — the bd-root gotcha):

1. **Explicit non-buildable signal → route out** (remove `story:approved`, add true-state label, comment with audit trail, emit):
   - **needs-device:** label `story:needs-device`, OR title/AC matches an on-device pattern (`on-device`, `warming`/`aquecimento` of a chip, `UIAutomator`, `screencap`, `tela do`, `celular`, `DPR foreground`). → `story:needs-device`. (Flag for v2 split.)
   - **needs-human:** label `gate:needs-human*` or `story:needs-human`. → `story:needs-human`.
   - **blocked:** label `blocked`/`story:blocked`, OR explicit external-dependency wording (`bloqueado por`, `quando o datastore`, `aguardando <serviço>`). → `story:blocked`.
   - **post-build:** `gate:passed` present → it already built; remove `story:approved` (delivery owns it).
2. **No explicit signal → assumed code-buildable → guarantee flow or alarm:**
   - If in-flight (`story:in-flight` / assignee is a live builder) or dispatched within `FLOW_GRACE_MIN` → OK.
   - Else if approved-age > `STARVE_MIN` AND pilot daemon alive AND a builder pool has capacity AND bead not `pilot:held-until` → **ALARM** (`gc mail send mayor` + notify): "buildable bead `<id>` starving: story:approved `<age>`min, not dispatched, pilot alive, capacity free — dispatch path is failing." Per-bead cooldown.
   - `mayor`-assigned approved beads are a known reserved category → do not alarm; emit a low-priority ledger note only (so they are visible but not noise).

**Bounds (data/ops-derived, env-tunable):**
- `STARVE_MIN` = 20 (a genuinely-buildable bead should dispatch within ~2 pilot sweeps + margin; the pilot sweeps every 5 min).
- `FLOW_GRACE_MIN` = 10 (recently-dispatched is "flowing").
- Per-bead route + alarm cooldowns (~30 min) to avoid churn/spam.

**HARD SAFETY RAILS:**
- **Never route out a bead lacking an EXPLICIT signal** (the assumed-buildable default protects real work — misclassifying buildable work as needs-device would HIDE it, the one outcome worse than the status quo).
- **Reversible:** routing only changes labels (+ audit comment); a mis-route is one `label add story:approved` away from undone. `DRY_RUN` logs intended actions without mutating.
- **Multi-store fail-open:** a per-store query error skips that store, never crashes the cycle.
- **Idempotent:** re-running on an already-routed bead is a no-op.

## 5. Why this is the actual "imparável" fix (not the 20 prior answers)

Every prior answer was "the beads are correctly parked" — defending the symptom. This makes the symptom **impossible by construction**: approved work is always flowing, or it is honestly re-stated and the operator is told, or a real dispatch failure alarms. The painel stops lying; the operator always sees the truth (buildable-and-flowing vs the honest true-state queues). The pipeline IS unstoppable for the work it can do, and it can no longer pretend to have approved work it is silently ignoring.

## 6. Out of scope (explicit)
- The v2 code/run SPLIT + the device-ops queue on the frota dashboard (separate spec; agent/refino work).
- Building any on-device executor (Oracle: viable but semi-autonomous + human-checkpointed; a product decision, separate track).
- Re-tuning the painel UI (the reconciler makes the *data* honest; the painel reflects it).
- The Pilot's own dispatch logic (the reconciler ALARMS on a dispatch failure; fixing a specific failure is separate).

## 7. v1 acceptance
- Backtest against 2026-06-28: the 10 on-device + 4 needs-human + 1 blocked would each be routed out by their explicit signal; the 2 remaining (mayor/held) stay; net "approved" = buildable-or-held only.
- A synthetic genuinely-buildable approved bead left undispatched past `STARVE_MIN` with the pilot alive → ALARM fires (case 3).
- A bead with no explicit signal is NEVER routed out (safety).
- Hermetic `--selftest` covering each route + the starve-alarm + the no-signal-safety + multi-store fail-open + idempotency + DRY_RUN.
